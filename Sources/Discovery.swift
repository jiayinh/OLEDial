import Foundation
import Darwin

struct DiscoveredTV: Identifiable, Hashable {
    let ip: String
    let name: String
    var id: String { ip }
}

/// Finds LG webOS TVs on the local network with an SSDP M-SEARCH.
enum SSDPDiscovery {
    static func discover(timeout: TimeInterval = 3) async -> [DiscoveredTV] {
        await Task.detached(priority: .userInitiated) { search(timeout: timeout) }.value
    }

    private static func search(timeout: TimeInterval) -> [DiscoveredTV] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")

        let query = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            "ST: urn:lge-com:service:webos-second-screen:1\r\n\r\n"
        let bytes = Array(query.utf8)

        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: DiscoveredTV] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &len)
                }
            }
            guard n > 0 else { continue }

            var addr = from.sin_addr
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)

            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            guard text.lowercased().contains("webos-second-screen") else { continue }

            var name = "LG TV"
            for line in text.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("dlnadevicename.lge.com:") {
                    let raw = line.dropFirst("DLNADeviceName.lge.com:".count)
                        .trimmingCharacters(in: .whitespaces)
                    name = raw.removingPercentEncoding ?? raw
                }
            }
            found[ip] = DiscoveredTV(ip: ip, name: name)
        }
        return found.values.sorted { $0.ip < $1.ip }
    }
}
