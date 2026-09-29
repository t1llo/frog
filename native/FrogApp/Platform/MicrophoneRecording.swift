import AVFoundation
import CoreAudio
import FrogCore

@MainActor
protocol DictationRecording: AnyObject {
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws
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

    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        let input: AVCaptureDevice?
        if let device {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid: CFString?
            var size = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
            input = status == noErr ? uid.flatMap { AVCaptureDevice(uniqueID: $0 as String) } : nil
        } else { input = AVCaptureDevice.default(for: .audio) }
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
