import CoreAudio
import Foundation

// MARK: - Microphone mute (⌥ + mute key)
//
// Mutes the Mac's DEFAULT INPUT device at the CoreAudio level, so every app
// (Zoom, Discord, browsers…) receives silence. Devices without a hardware
// mute control fall back to input volume 0 (previous level is restored on
// unmute). If the default input changes while muted (e.g. AirPods connect),
// the mute is re-applied to the new device.

final class MicMuteController {
    private(set) var muted = false
    private var savedVolume: Float32?

    private var defaultInputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        // Follow the default input: keep the muted state sticky across device changes.
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr,
            DispatchQueue.main) { [weak self] _, _ in
                guard let self = self, self.muted, let dev = self.defaultInput() else { return }
                self.savedVolume = nil
                _ = self.apply(mute: true, to: dev)
                NSLog("VolumeKey: default input changed while muted — re-muted '\(self.inputName() ?? "?")'")
        }
    }

    /// Toggles mute on the default input. Returns (nowMuted, deviceName), or nil on failure.
    func toggle() -> (Bool, String)? {
        guard let dev = defaultInput() else { return nil }
        let name = inputName() ?? "Microphone"
        guard apply(mute: !muted, to: dev) else {
            NSLog("VolumeKey: mic mute failed for '\(name)' — no mute or volume control")
            return nil
        }
        muted = !muted
        NSLog("VolumeKey: mic '\(name)' \(muted ? "MUTED" : "live")")
        return (muted, name)
    }

    private func defaultInput() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultInputAddr
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    func inputName() -> String? {
        guard let dev = defaultInput() else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &cfName) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let name = cfName else { return nil }
        return name as String
    }

    private func apply(mute: Bool, to dev: AudioObjectID) -> Bool {
        // Preferred: the device's real mute control (main element, then channel 1).
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(dev, &addr),
                  AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = mute ? 1 : 0
            if AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                return true
            }
        }
        // Fallback: drive input volume to 0 and restore it on unmute.
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(dev, &addr),
                  AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            if mute {
                var current: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &current) == noErr {
                    savedVolume = current
                }
                var zero: Float32 = 0
                if AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                              UInt32(MemoryLayout<Float32>.size), &zero) == noErr {
                    return true
                }
            } else {
                var restore: Float32 = savedVolume ?? 0.75
                savedVolume = nil
                if AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                              UInt32(MemoryLayout<Float32>.size), &restore) == noErr {
                    return true
                }
            }
        }
        return false
    }
}
