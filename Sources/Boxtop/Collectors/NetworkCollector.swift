import CSysInfo
import Darwin
import Foundation
import SystemConfiguration

/// Interface addresses from `getifaddrs` and 64-bit byte counters from NET_RT_IFLIST2
/// (btop `Net::collect`, src/osx), with btop's speed / top / total bookkeeping.
final class NetworkCollector {
    private struct Counter {
        var lastRx: UInt64
        var lastTx: UInt64
        var baseRx: UInt64
        var baseTx: UInt64
        var rolloverRx: UInt64 = 0
        var rolloverTx: UInt64 = 0
        var topRx: Double = 0
        var topTx: Double = 0
    }

    private var counters: [String: Counter] = [:]
    private var lastTime: Date?
    private var buffer = [bt_ifstat](repeating: bt_ifstat(), count: 128)

    func collect() -> [NetInterfaceSample] {
        let now = Date()
        let elapsed = lastTime.map { now.timeIntervalSince($0) } ?? 0
        lastTime = now

        var interfaces: [String: NetInterfaceSample] = [:]
        var order: [String] = []

        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer {
            defer { freeifaddrs(ifaddrPointer) }
            for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let name = String(cString: ifa.pointee.ifa_name)
                let flags = Int32(ifa.pointee.ifa_flags)
                if interfaces[name] == nil {
                    order.append(name)
                    interfaces[name] = NetInterfaceSample(
                        name: name,
                        isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                        isLoopback: flags & IFF_LOOPBACK != 0
                    )
                }
                guard let addr = ifa.pointee.ifa_addr else { continue }
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET, interfaces[name]?.ipv4 == nil {
                    interfaces[name]?.ipv4 = Self.address(addr, family: family)
                } else if family == AF_INET6, interfaces[name]?.ipv6 == nil {
                    interfaces[name]?.ipv6 = Self.address(addr, family: family)
                }
            }
        }

        let count = Int(bt_net_counters(&buffer, Int32(buffer.count)))
        var seen = Set<String>()
        for stat in buffer.prefix(max(0, count)) {
            let name = string(fromCTuple: stat.name)
            guard var sample = interfaces[name] else { continue }
            seen.insert(name)

            var counter = counters[name] ?? Counter(lastRx: stat.ibytes, lastTx: stat.obytes,
                                                    baseRx: stat.ibytes, baseTx: stat.obytes)
            // btop's rollover handling: a counter that goes backwards wrapped or was reset.
            if stat.ibytes < counter.lastRx { counter.rolloverRx &+= counter.lastRx; counter.lastRx = 0 }
            if stat.obytes < counter.lastTx { counter.rolloverTx &+= counter.lastTx; counter.lastTx = 0 }

            if elapsed > 0 {
                sample.rxRate = Double(stat.ibytes - counter.lastRx) / elapsed
                sample.txRate = Double(stat.obytes - counter.lastTx) / elapsed
            }
            counter.topRx = max(counter.topRx, sample.rxRate)
            counter.topTx = max(counter.topTx, sample.txRate)
            sample.rxTop = counter.topRx
            sample.txTop = counter.topTx
            sample.rxTotal = (stat.ibytes &+ counter.rolloverRx) &- counter.baseRx
            sample.txTotal = (stat.obytes &+ counter.rolloverTx) &- counter.baseTx
            counter.lastRx = stat.ibytes
            counter.lastTx = stat.obytes
            counters[name] = counter
            interfaces[name] = sample
        }
        counters = counters.filter { seen.contains($0.key) }

        return order.compactMap { interfaces[$0] }
    }

    private let store = SCDynamicStoreCreate(nil, "Boxtop" as CFString, nil, nil)

    func primaryInterface() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    /// Resets "total" and "top" counters (btop's net reset key).
    func resetTotals() {
        for (name, counter) in counters {
            counters[name] = Counter(lastRx: counter.lastRx, lastTx: counter.lastTx,
                                     baseRx: counter.lastRx &+ counter.rolloverRx,
                                     baseTx: counter.lastTx &+ counter.rolloverTx,
                                     rolloverRx: counter.rolloverRx, rolloverTx: counter.rolloverTx)
        }
    }

    private static func address(_ addr: UnsafeMutablePointer<sockaddr>, family: Int32) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cChars: host)
    }
}
