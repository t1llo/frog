import CoreAudio
import Foundation

/// Core Audio's device list changes when a microphone or headset is connected or removed.
enum AudioDeviceChanges {
    private static let changed = Notification.Name("FrogAudioDeviceListChanged")
    /// One listener for the life of the app. Swift passes a new block for each call, so a block
    /// listener could not be matched for removal.
    private static let listening: Bool = {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            NotificationCenter.default.post(name: changed, object: nil)
        } == noErr
    }()

    /// Yields after each change of the list, until the iteration ends. A burst of changes waits as one.
    static func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard listening else { continuation.finish(); return }
            let observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: nil) { _ in continuation.yield() }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
        }
    }
}
