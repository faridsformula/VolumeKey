import Cocoa
import Foundation
import IOKit

// MARK: - DDC/CI volume for external displays (Apple Silicon)
//
// Speaks MCCS over the display cable's I2C channel — the same mechanism
// monitor OSD menus use. Covers computer monitors with speakers/headphone
// jacks (Dell, BenQ, ASUS, Gigabyte, LG monitors…). Discovery PROBES each
// external display with a VCP volume read and only surfaces displays that
// answer — TVs that don't implement DDC (LG OLEDs, most TVs) simply never
// appear and are handled by their network backends instead.
//
// Uses IOAVService (private IOKit API, the standard route on Apple Silicon —
// same one MonitorControl/m1ddc use). Intel Macs: DDC needs a different
// framebuffer path — not implemented; network backends still work there.

#if arch(arm64)

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ inputBuffer: UnsafeRawPointer, _ inputBufferSize: UInt32) -> IOReturn
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn

final class DDCDisplay: VolumeTarget {
    let uuid: String
    let name: String
    let ip = ""  // not networked
    let kindLabel = "Display"
    let supportsAbsoluteVolume = true
    private(set) var cachedVolume: Int?
    private var cachedMuted = false

    private let service: CFTypeRef
    private let maxVolume: Int
    // One serial queue for all I2C traffic — concurrent DDC transactions corrupt replies.
    private static let i2cQueue = DispatchQueue(label: "volumekey.ddc")

    private static let vcpVolume: UInt8 = 0x62
    private static let vcpMute: UInt8 = 0x8D  // 1 = mute, 2 = unmute

    init?(service: CFTypeRef, name: String, index: Int) {
        self.service = service
        self.name = name
        self.uuid = "ddc:\(name):\(index)"
        // Probe: a display without a readable volume control is not a target.
        guard let (current, max) = Self.readVCP(service, Self.vcpVolume) else { return nil }
        self.maxVolume = max > 0 ? max : 100
        self.cachedVolume = Int((Double(current) / Double(self.maxVolume) * 100).rounded())
    }

    // MARK: VolumeTarget

    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void) {
        let target = max(0, min(100, (cachedVolume ?? 50) + delta))
        cachedVolume = target
        setVolume(target)
        completion(target, cachedMuted)
    }

    func setVolume(_ volume: Int) {
        let pct = max(0, min(100, volume))
        cachedVolume = pct
        let raw = Int((Double(pct) / 100.0 * Double(maxVolume)).rounded())
        Self.i2cQueue.async { [service] in
            Self.writeVCP(service, Self.vcpVolume, UInt16(raw))
        }
    }

    func toggleMute(completion: @escaping (Int?, Bool) -> Void) {
        cachedMuted.toggle()
        let value: UInt16 = cachedMuted ? 1 : 2
        Self.i2cQueue.async { [service, cachedMuted, cachedVolume] in
            Self.writeVCP(service, Self.vcpMute, value)
            DispatchQueue.main.async { completion(cachedVolume, cachedMuted) }
        }
    }

    func refreshVolume(completion: ((Int?, Bool) -> Void)?) {
        Self.i2cQueue.async { [weak self, service] in
            let result = Self.readVCP(service, Self.vcpVolume)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let (current, max) = result, max > 0 {
                    self.cachedVolume = Int((Double(current) / Double(max) * 100).rounded())
                }
                completion?(self.cachedVolume, self.cachedMuted)
            }
        }
    }

    // MARK: MCCS packets (chip 0x37, host offset 0x51)

    @discardableResult
    private static func writeVCP(_ service: CFTypeRef, _ code: UInt8, _ value: UInt16) -> Bool {
        var data: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        data[5] = data[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        for attempt in 0..<3 {
            if IOAVServiceWriteI2C(service, 0x37, 0x51, data, 6) == KERN_SUCCESS { return true }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        return false
    }

    /// Returns (currentValue, maxValue) or nil if the display doesn't answer.
    static func readVCP(_ service: CFTypeRef, _ code: UInt8) -> (Int, Int)? {
        var req: [UInt8] = [0x82, 0x01, code, 0]
        req[3] = req[0..<3].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        for attempt in 0..<3 {
            guard IOAVServiceWriteI2C(service, 0x37, 0x51, req, 4) == KERN_SUCCESS else {
                usleep(UInt32(20_000 * (attempt + 1))); continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, 12) == KERN_SUCCESS else {
                usleep(UInt32(20_000 * (attempt + 1))); continue
            }
            // reply: [addr, len, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk]
            if reply[2] == 0x02, reply[3] == 0x00, reply[4] == code {
                let maxV = Int(reply[6]) << 8 | Int(reply[7])
                let curV = Int(reply[8]) << 8 | Int(reply[9])
                return (curV, maxV)
            }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        return nil
    }
}

// MARK: - Discovery: external DCP AV services ↔ external screens by order

enum DDCDiscovery {
    static func scan() -> [DDCDisplay] {
        var services: [CFTypeRef] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let location = IORegistryEntryCreateCFProperty(
                      entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String,
                  location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?
                      .takeRetainedValue() else { continue }
            services.append(av)
        }
        IOObjectRelease(iterator)

        // Name external AVServices by pairing with external NSScreens in order —
        // exact registry correlation isn't exposed; 1:1 order holds for the
        // common single/dual external-display setups.
        let externalScreens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) == 0 } ?? true
        }
        var found: [DDCDisplay] = []
        for (i, av) in services.enumerated() {
            let name = i < externalScreens.count ? externalScreens[i].localizedName : "External display \(i + 1)"
            if let d = DDCDisplay(service: av, name: name, index: i) {
                NSLog("VolumeKey: DDC display found: \(name) (volume \(d.cachedVolume ?? -1))")
                found.append(d)
            } else {
                NSLog("VolumeKey: display '\(name)' has no DDC volume — skipping")
            }
        }
        return found
    }
}

#else

// Intel Macs: DDC would need the IOFramebuffer path — network backends only.
enum DDCDiscovery {
    static func scan() -> [DDCDisplay] { [] }
}
final class DDCDisplay: VolumeTarget {
    let uuid = "", name = "", ip = "", kindLabel = "Display"
    let supportsAbsoluteVolume = true
    var cachedVolume: Int? { nil }
    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void) { completion(nil, false) }
    func toggleMute(completion: @escaping (Int?, Bool) -> Void) { completion(nil, false) }
    func setVolume(_ volume: Int) {}
    func refreshVolume(completion: ((Int?, Bool) -> Void)?) { completion?(nil, false) }
}

#endif
