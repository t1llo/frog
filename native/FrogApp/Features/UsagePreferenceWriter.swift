import Foundation
import FrogCore

/// Display-only changes are written off the UI thread, in order. Full configuration
/// operations drain this lane first so an older provider choice cannot overwrite them.
final class UsagePreferenceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "frog.usage-preferences", qos: .utility)
    private let store: ConfigurationStore
    private var saved: UsageDisplayPreferences?
    struct Failure { let error: Error; let saved: UsageDisplayPreferences? }
    private var failure: Error?
    private let lock = NSLock()
    private var pending: (Configuration, @Sendable (Error, UsageDisplayPreferences?) -> Void)?
    private var scheduled = false

    init(store: ConfigurationStore, initial: Configuration) {
        self.store = store; saved = initial.preferences.toolkit?.usage
    }

    func save(_ configuration: Configuration, failed: @escaping @Sendable (Error, UsageDisplayPreferences?) -> Void) {
        lock.lock()
        pending = (configuration, failed)
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { scheduled = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                do { try store.save(next.0); saved = next.0.preferences.toolkit?.usage; failure = nil }
                catch { failure = error; next.1(error, saved) }
            }
        }
    }

    func drain() -> Failure? {
        queue.sync {
            defer { failure = nil }
            return failure.map { Failure(error: $0, saved: saved) }
        }
    }
    func didSave(_ configuration: Configuration) { queue.sync { saved = configuration.preferences.toolkit?.usage; failure = nil } }
}
