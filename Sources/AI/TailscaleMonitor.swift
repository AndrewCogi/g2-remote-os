import Darwin
import Foundation
import Network

/// Detects whether Tailscale VPN is currently active on the iPhone with zero special entitlements.
/// Uses `NWPathMonitor` for instant reactive updates when toggling the Tailscale app ON/OFF,
/// combined with inspecting `utun*` interfaces for an IPv4 address in Tailscale's 100.64.0.0/10 CGNAT range.
public final class TailscaleMonitor: ObservableObject {
    @Published public private(set) var isTailscaleConnected: Bool = false
    @Published public private(set) var tailscaleIPv4: String?

    public var onStatusChanged: ((Bool, String?) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.g2remote.os.tailscale.monitor", qos: .utility)
    private var started = false

    public init() {
        let (connected, ip) = Self.detectTailscaleInterface()
        self.isTailscaleConnected = connected
        self.tailscaleIPv4 = ip
    }

    deinit {
        monitor.cancel()
    }

    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.refresh()
        }
        monitor.start(queue: queue)
        refresh()
    }

    public func refresh() {
        let (connected, ip) = Self.detectTailscaleInterface()
        DispatchQueue.main.async {
            let changed = (self.isTailscaleConnected != connected) || (self.tailscaleIPv4 != ip)
            self.isTailscaleConnected = connected
            self.tailscaleIPv4 = ip
            if changed {
                self.onStatusChanged?(connected, ip)
            }
        }
    }

    /// Scans active POSIX network interfaces (`getifaddrs`) for a `utun*` interface
    /// carrying a Tailscale CGNAT IPv4 address (`100.64.0.0` – `100.127.255.255`).
    public static func detectTailscaleInterface() -> (Bool, String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return (false, nil)
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0

            if isUp && isRunning,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET)
            {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("utun") {
                    let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let ipBigEndian = UInt32(bigEndian: sin.sin_addr.s_addr)
                    let o1 = (ipBigEndian >> 24) & 0xFF
                    let o2 = (ipBigEndian >> 16) & 0xFF
                    let o3 = (ipBigEndian >> 8) & 0xFF
                    let o4 = ipBigEndian & 0xFF
                    // Tailscale assigns 100.64.0.0/10 (100.64.x.x .. 100.127.x.x)
                    if o1 == 100 && (64...127).contains(o2) {
                        return (true, "\(o1).\(o2).\(o3).\(o4)")
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return (false, nil)
    }
}
