import WhisperKit

@MainActor
protocol DictationRecording: AnyObject {
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

@MainActor
final class MicrophoneRecording: DictationRecording {
    private let processor = AudioProcessor()
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        try processor.startRecordingLive(inputDeviceID: device, callback: samples)
    }
    func stop() { processor.stopRecording() }
}
