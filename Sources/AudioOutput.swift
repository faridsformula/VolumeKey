import CoreAudio
import Foundation

// MARK: - Default audio-output monitor
//
// Watches macOS's default output device. If that device has native volume
// control (AirPods, Bluetooth headphones, built-in speakers, USB DACs), the
// volume keys should stay with macOS. If it doesn't (HDMI/DisplayPort — e.g.
// the LG TV), VolumeKey hijacks them. Auto-switches the moment the default
// output changes (headphones connect/disconnect).

final class AudioOutputMonitor {
    private(set) var hasNativeVolume = false
    private(set) var outputName = "Unknown"
    /// Fired on the main queue whenever the default output device changes.
    var onChange: (() -> Void)?

    private var defaultOutputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        refresh()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr,
            DispatchQueue.main) { [weak self] _, _ in
                self?.refresh()
                self?.onChange?()
        }
    }

    func refresh() {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddr
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            hasNativeVolume = false
            outputName = "Unknown"
            return
        }
        outputName = Self.name(of: deviceID) ?? "Audio device"
        hasNativeVolume = Self.hasSettableVolume(deviceID)
        NSLog("VolumeKey: default output is '\(outputName)' nativeVolume=\(hasNativeVolume)")
    }

    private static func name(of dev: AudioObjectID) -> String? {
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

    private static func hasSettableVolume(_ dev: AudioObjectID) -> Bool {
        // Prefer the virtual main volume (what the system HUD drives), then
        // fall back to per-channel scalar volume (main element, channel 1).
        // 'vmvc' = virtual main volume (the control the system volume HUD drives);
        // the named constant lives in AudioToolbox, so use the FourCC directly.
        let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)
        let candidates: [(AudioObjectPropertySelector, UInt32)] = [
            (virtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
        ]
        for (selector, element) in candidates {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }
}
