import Darwin
import Foundation

// MARK: - Onkyo eISCP control
//
// Onkyo AVRs expose their real front-panel mute state through the native ISCP
// `AMT` command. Some models also advertise UPnP RenderingControl, but their
// SetMute implementation can behave like minimum volume rather than AVR mute.

enum OnkyoISCP {
    private static let port: UInt16 = 60128
    private static let timeoutSeconds: Int32 = 2

    /// Returns the receiver's resulting mute state, or nil when native control
    /// is unavailable so the caller can fall back to DLNA.
    static func toggleMute(host: String) -> Bool? {
        guard let reply = transact(host: host, command: "AMTQSTN"),
              let current = muteState(in: reply) else {
            NSLog("VolumeKey: Onkyo eISCP mute query failed @ \(host); using DLNA fallback")
            return nil
        }

        let target = !current
        let command = target ? "AMT01" : "AMT00"
        guard transact(host: host, command: command) != nil else {
            NSLog("VolumeKey: Onkyo eISCP \(command) failed @ \(host); using DLNA fallback")
            return nil
        }
        NSLog("VolumeKey: Onkyo eISCP mute=\(target) @ \(host)")
        return target
    }

    private static func muteState(in reply: String) -> Bool? {
        if reply.contains("!1AMT01") { return true }
        if reply.contains("!1AMT00") { return false }
        return nil
    }

    private static func transact(host: String, command: String) -> String? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        let originalFlags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, originalFlags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result < 0 {
            guard errno == EINPROGRESS else { return nil }
            var descriptor = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, timeoutSeconds * 1_000) > 0 else { return nil }
            var socketError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0,
                  socketError == 0 else { return nil }
        }

        _ = fcntl(sock, F_SETFL, originalFlags)
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let payload = Data(("!1" + command + "\r\n").utf8)
        var packet = Data("ISCP".utf8)
        appendBigEndian(16, to: &packet)
        appendBigEndian(UInt32(payload.count), to: &packet)
        packet.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        packet.append(payload)
        guard sendAll(packet, on: sock) else { return nil }

        guard let header = receiveExactly(16, from: sock),
              header.prefix(4) == Data("ISCP".utf8) else { return nil }
        let bytes = [UInt8](header)
        let payloadSize = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16)
            | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])
        guard payloadSize > 0, payloadSize <= 4_096,
              let response = receiveExactly(Int(payloadSize), from: sock) else { return nil }
        return String(data: response, encoding: .utf8)
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func sendAll(_ data: Data, on socket: Int32) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            while sent < data.count {
                let count = Darwin.send(socket, base.advanced(by: sent), data.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    private static func receiveExactly(_ count: Int, from socket: Int32) -> Data? {
        var data = Data(count: count)
        var received = 0
        let success = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            while received < count {
                let amount = Darwin.recv(socket, base.advanced(by: received), count - received, 0)
                if amount <= 0 { return false }
                received += amount
            }
            return true
        }
        return success ? data : nil
    }
}
