import AVFoundation
import FrogCore

/// An input the person can choose. `uid` is the device's persistent CoreAudio UID, which
/// `AVCaptureDevice` calls `uniqueID`. Unlike the numeric device ID that earlier versions saved,
/// it still names the same device after a reconnection or a restart.
struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }

    static var connected: [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { MicrophoneDevice(uid: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
protocol DictationRecording: AnyObject {
    /// `deviceUID` is a `MicrophoneDevice.uid`; nil opens the macOS default input.
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
    func finish() async
}

extension DictationRecording {
    func finish() async { stop() }
}

@MainActor
final class MicrophoneRecording: DictationRecording {
    // A single queue orders teardown before the next capture starts, even across recorder instances.
    private static let queue = DispatchQueue(label: "frog.microphone.capture", qos: .userInitiated)
    private var capture: MicrophoneCapture?

    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        let input: AVCaptureDevice?
        if let deviceUID { input = AVCaptureDevice(uniqueID: deviceUID) }
        else { input = AVCaptureDevice.default(for: .audio) }
        guard let input else { throw FrogError.message("The selected microphone is unavailable. Choose another microphone.") }
        let capture = try MicrophoneCapture(device: input, queue: Self.queue, receive: samples)
        self.capture = capture
        Self.queue.async { capture.start() }
    }
    func stop() {
        guard let capture else { return }
        self.capture = nil
        Self.queue.async { capture.stop() }
    }
    func finish() async {
        guard let capture else { return }
        self.capture = nil
        await withCheckedContinuation { continuation in
            Self.queue.async { capture.stop(); continuation.resume() }
        }
    }
    isolated deinit { stop() }
}

/// Input-only capture lets macOS handle Bluetooth format changes without an output audio engine
/// resetting the speaker's mute state. Session work and sample delivery stay on the capture queue.
private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let receive: @Sendable ([Float]) -> Void

    init(device: AVCaptureDevice, queue: DispatchQueue, receive: @escaping @Sendable ([Float]) -> Void) throws {
        self.receive = receive
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw FrogError.message("This microphone cannot record audio. Choose another microphone.")
        }
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                AVLinearPCMIsNonInterleaved: false]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.addInput(input); session.addOutput(output)
        session.commitConfiguration()
    }

    func start() { session.startRunning() }
    func stop() { output.setSampleBufferDelegate(nil, queue: nil); session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session.isRunning,
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 16000,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.size else { return }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        if status == kCMBlockBufferNoErr { receive(samples) }
    }
}
