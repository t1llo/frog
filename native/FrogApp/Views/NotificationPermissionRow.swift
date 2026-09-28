import AppKit
import SwiftUI
import UserNotifications

struct NotificationPermissionRow: View {
    var detail: String? = nil
    @State private var status: UNAuthorizationStatus?
    @State private var requesting = false
    @State private var issue: String?

    private var allowed: Bool { status == .authorized || status == .provisional }
    private var statusText: String {
        switch status {
        case .authorized: "Allowed"
        case .provisional: "Quiet delivery"
        case .denied: "Permission needed"
        case .notDetermined: "Not requested"
        default: "Checking…"
        }
    }
    var body: some View {
        CompactRow(title: "Notifications", detail: detail) {
            HStack(spacing: 10) {
                Label(statusText, systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(allowed ? FrogStyle.accent : .orange)
                Button(status == .notDetermined ? "Allow…" : "Manage…") {
                    if status == .notDetermined {
                        requesting = true; issue = nil
                        Task {
                            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                            catch { issue = error.localizedDescription }
                            await refresh(); requesting = false
                        }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }.disabled(status == nil || requesting)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
    }
    private func refresh() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
