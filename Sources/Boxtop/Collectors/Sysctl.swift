import Darwin
import Foundation
import IOKit

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cChars: buffer)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; sysctl only fills `size` bytes.
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func value<T>(_ name: String, as _: T.Type) -> T? {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0 else { return nil }
        return pointer.pointee
    }
}

enum MachTime {
    /// Multiplier from mach absolute time units to nanoseconds.
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()
}

/// Small helpers around IOKit registry access.
enum IORegistry {
    static func property<T>(_ entry: io_registry_entry_t, _ key: String, as _: T.Type) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return value as? T
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    /// Calls `body` for each service matching `className`; objects are released afterwards.
    static func forEach(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    static func name(_ entry: io_registry_entry_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buffer.deallocate() }
        guard IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }
}

/// Hardware and driver values are untrusted: counters underflow, sensors return NaN or garbage.
/// Converting such a value straight to an integer type traps, so everything read from IOKit,
/// the SMC or drivers goes through these checks first.
extension Double {
    /// The value if it is finite and inside `range`, otherwise nil.
    func sane(_ range: ClosedRange<Double>) -> Double? {
        isFinite && range.contains(self) ? self : nil
    }
}

enum DriverValue {
    /// A byte count from a driver dictionary. Rejects negative values and unsigned counters that
    /// underflowed (e.g. Intel's inUseSysMemoryBytes reporting 2^64 - 41 MB).
    static func bytes(_ dict: [String: Any], _ key: String) -> UInt64? {
        guard let number = dict[key] as? NSNumber else { return nil }
        let value = number.int64Value
        guard value >= 0, value < 1 << 52 else { return nil }  // 4 PB is not a real GPU
        return UInt64(value)
    }

    /// A finite number from a driver dictionary within `range`.
    static func number(_ dict: [String: Any], _ key: String, in range: ClosedRange<Double>) -> Double? {
        (dict[key] as? NSNumber)?.doubleValue.sane(range)
    }
}

extension Data {
    /// Interprets IORegistry string-ish data blobs ("model", "cluster-type").
    var registryString: String? {
        let trimmed = prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8)
    }
}

extension String {
    /// Decodes a NUL-terminated C char buffer as UTF-8.
    init(cChars: [CChar]) {
        self = String(decoding: cChars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Converts fixed-size C char tuples (e.g. `name[64]`) into Swift strings.
func string<T>(fromCTuple tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base)
    }
}
