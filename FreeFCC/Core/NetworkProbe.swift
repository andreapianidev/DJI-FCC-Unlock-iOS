// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Darwin
import Foundation

/// One network interface as the phone sees it.
struct InterfaceInfo: Sendable, Hashable {
    var name: String
    var address: String
    var netmask: String
    var isIPv4: Bool
    var isUp: Bool
    var isRunning: Bool
    var isLoopback: Bool
    var isPointToPoint: Bool

    var summary: String {
        var flags = [String]()
        if isUp { flags.append("up") }
        if isRunning { flags.append("running") }
        if isPointToPoint { flags.append("p2p") }
        let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ",")))"
        return "\(name) \(address)\(netmask.isEmpty ? "" : "/\(netmask)")\(suffix)"
    }

    /// True for the interfaces worth looking at: not loopback, not the
    /// well-known Wi-Fi and cellular names.
    var isCandidate: Bool {
        guard !isLoopback, isIPv4, isUp else { return false }
        let known = ["lo0", "en0", "pdp_ip0", "pdp_ip1", "pdp_ip2", "pdp_ip3", "utun"]
        return !known.contains { name == $0 || name.hasPrefix("utun") }
    }
}

/// Enumerates the phone's network interfaces.
///
/// The point is the diff. If the RC-N3 exposes itself over USB-C as a network
/// device rather than as an MFi accessory, which is how DJI reaches the smart
/// controllers, then plugging the cable in makes a new interface appear. That
/// is a different port to knock on, and one that needs no MFi programme
/// membership to use.
enum NetworkProbe {

    /// Port the DJI smart controllers listen on for the DUMPL command proxy.
    static let djiCommandPort: UInt16 = 40009

    static func interfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found = [InterfaceInfo]()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddr = current.pointee.ifa_addr else { continue }
            let family = sockaddr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            let address = presentation(of: sockaddr, family: family)
            let netmask = current.pointee.ifa_netmask.map { presentation(of: $0, family: family) } ?? ""

            found.append(
                InterfaceInfo(
                    name: name,
                    address: address,
                    netmask: netmask,
                    isIPv4: family == UInt8(AF_INET),
                    isUp: flags & IFF_UP != 0,
                    isRunning: flags & IFF_RUNNING != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0,
                    isPointToPoint: flags & IFF_POINTOPOINT != 0
                )
            )
        }
        return found
    }

    private static func presentation(of sockaddr: UnsafeMutablePointer<sockaddr>, family: UInt8) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = family == UInt8(AF_INET)
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(sockaddr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return ""
        }
        // Link-local IPv6 carries a %en5 scope suffix; keep it, it names the
        // interface the peer is on.
        return String(cString: host)
    }

    /// Peers worth trying on a freshly appeared interface: the usual gateway
    /// slot for a USB gadget subnet, plus the addresses DJI's own gadgets use.
    static func candidatePeers(for interface: InterfaceInfo) -> [String] {
        var peers = [String]()
        let octets = interface.address.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            peers.append("\(octets[0]).\(octets[1]).\(octets[2]).1")
            if octets[3] != 2 { peers.append("\(octets[0]).\(octets[1]).\(octets[2]).2") }
        }
        peers.append(contentsOf: ["192.168.2.1", "192.168.42.1", "192.168.10.1"])
        var seen = Set<String>()
        return peers.filter { $0 != interface.address && seen.insert($0).inserted }
    }

    /// Blocking TCP connect with a short timeout. Returns true if something
    /// accepted the connection.
    ///
    /// Runs on the engine queue, never on the main thread.
    static func canReach(host: String, port: UInt16, timeoutMs: Int = 400) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return false }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        // Non-blocking connect plus poll, so an unreachable peer costs the
        // timeout rather than the kernel's default minute and a half.
        let existing = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, existing | O_NONBLOCK)

        let started = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeoutMs)) > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}
