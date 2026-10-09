import Foundation
import Network

/// Retry a failed automatic check once connectivity returns, instead of waiting a full interval.
@MainActor
final class UpdateConnectivityRecovery {
    typealias Monitor = (@escaping (Bool) -> Void) -> (() -> Void)
    private let monitor: Monitor
    private let retryDelay: UInt64
    private var stopMonitoring: (() -> Void)?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var waiting = false
    private var retrying = false

    init(retryDelay: UInt64 = 5_000_000_000, monitor: Monitor? = nil) {
        self.retryDelay = retryDelay
        self.monitor = monitor ?? { changed in
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { path in
                let connected = path.status == .satisfied
                Task { @MainActor in changed(connected) }
            }
            pathMonitor.start(queue: DispatchQueue(label: "updates.connectivity"))
            return { pathMonitor.cancel() }
        }
    }

    deinit {
        stopMonitoring?()
        retryTask?.cancel()
    }

    func updateCycleFinished(error: Error?, isAutomaticCheck: Bool, retry: @escaping () -> Bool) {
        let wasRetrying = retrying
        cancel()
        // One recovery attempt per scheduled check; a failing server must not create a retry loop.
        guard !wasRetrying, isAutomaticCheck, Self.isConnectionError(error) else { return }
        waiting = true
        let currentGeneration = generation
        stopMonitoring = monitor { [weak self] connected in
            guard let self, self.waiting, self.generation == currentGeneration else { return }
            self.retryTask?.cancel()
            self.retryTask = nil
            guard connected else { return }
            self.retryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // A usable route can appear before DNS/Wi-Fi has finished coming online.
                do { try await Task.sleep(nanoseconds: self.retryDelay) } catch { return }
                guard !Task.isCancelled, self.waiting, self.generation == currentGeneration else { return }
                self.waiting = false
                self.stopMonitoring?()
                self.stopMonitoring = nil
                self.retryTask = nil
                self.retrying = true
                if !retry() { self.retrying = false }
            }
        }
    }

    func cancel() {
        generation += 1
        waiting = false
        retrying = false
        stopMonitoring?()
        stopMonitoring = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private static func isConnectionError(_ error: Error?) -> Bool {
        var underlying = error as NSError?
        // Sparkle wraps URLSession errors in multiple feed/download errors.
        for _ in 0..<10 {
            guard let error = underlying else { return false }
            if error.domain == NSURLErrorDomain,
               [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed].contains(error.code) { return true }
            underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
