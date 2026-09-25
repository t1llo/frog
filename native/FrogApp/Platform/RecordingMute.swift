import CoreAudio
import Foundation
import FrogCore

/// Restores only the output device that this recording actually muted.
final class RecordingMute {
    private var device: AudioObjectID?
    func begin() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var output = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr else { throw FrogError.message("Cannot find the Mac audio output.") }
        address = Self.muteAddress
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &muted) == noErr else { throw FrogError.message("This audio output does not support muting. Disable mute while recording or choose another output.") }
        guard muted == 0 else { return }
        muted = 1
        guard AudioObjectSetPropertyData(output, &address, 0, nil, size, &muted) == noErr else { throw FrogError.message("The audio output could not be muted.") }
        device = output
    }
    func restore() {
        guard let device else { return }
        self.device = nil
        var address = Self.muteAddress
        var muted: UInt32 = 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
    }
    deinit { restore() }
    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
}
