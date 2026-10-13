import Darwin
import Foundation
import IOKit

/// Mounted volumes and their I/O rates (btop `Mem::collect` / `collect_disk`, src/osx).
///
/// Differences from btop:
/// - Hidden system volumes (MNT_DONTBROWSE: VM, Preboot, Time Machine snapshots...) are
///   skipped unless `showHidden` is on, so the list matches Finder.
/// - APFS volumes in the same volume group are summed, so "/" includes the Data volume's I/O.
final class DiskCollector {
    private struct IOCounter { var read: UInt64; var write: UInt64 }
    private struct APFSVolume { var bsdName: String; var group: String?; var mountFrom: String?; var counter: IOCounter }

    private var previous: [String: IOCounter] = [:]
    private var volumeNames: [String: String] = [:]
    private var lastTime: Date?

    func collect(showHidden: Bool) -> [DiskSample] {
        let now = Date()
        let elapsed = lastTime.map { now.timeIntervalSince($0) } ?? 0
        lastTime = now

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }

        let volumes = Self.apfsVolumes()
        var disks: [DiskSample] = []
        var counters: [String: IOCounter] = [:]

        for i in 0..<Int(count) {
            var fs = mounts[i]
            let mountPoint = string(fromCTuple: fs.f_mntonname)
            let device = string(fromCTuple: fs.f_mntfromname)
            let fsType = string(fromCTuple: fs.f_fstypename)
            let flags = UInt32(fs.f_flags)

            if ["autofs", "devfs", "nullfs", "lifs"].contains(fsType) { continue }
            if !showHidden, mountPoint != "/", flags & UInt32(MNT_DONTBROWSE) != 0 { continue }

            let isLocal = flags & UInt32(MNT_LOCAL) != 0
            // Refresh local filesystems; network mounts keep MNT_NOWAIT's cached values so a
            // stalled server can never block sampling (btop does the same with async statvfs).
            if isLocal { _ = statfs(mountPoint, &fs) }

            let blockSize = UInt64(fs.f_bsize)
            func bytes(_ blocks: UInt64) -> UInt64 {
                let (value, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
                return overflow ? 0 : value
            }
            var disk = DiskSample(
                name: volumeName(mountPoint, local: flags & UInt32(MNT_LOCAL) != 0),
                mountPoint: mountPoint,
                device: device,
                fsType: fsType,
                isLocal: isLocal,
                total: bytes(UInt64(fs.f_blocks)),
                free: bytes(UInt64(fs.f_bavail))
            )

            if device.hasPrefix("/dev/"), let counter = Self.counter(for: device, volumes: volumes) {
                counters[mountPoint] = counter
                if let before = previous[mountPoint], elapsed > 0 {
                    disk.readRate = Double(counter.read &- before.read) / elapsed
                    disk.writeRate = Double(counter.write &- before.write) / elapsed
                    if counter.read < before.read || counter.write < before.write {
                        disk.readRate = 0; disk.writeRate = 0
                    }
                } else {
                    disk.readRate = 0
                    disk.writeRate = 0
                }
            }
            disks.append(disk)
        }
        previous = counters

        // "/" first, then the rest alphabetically (btop puts root first too).
        return disks.sorted { a, b in
            if a.mountPoint == "/" { return true }
            if b.mountPoint == "/" { return false }
            return a.mountPoint.localizedStandardCompare(b.mountPoint) == .orderedAscending
        }
    }

    /// Finder's name for the volume ("Macintosh HD"); network mounts use the mount folder name.
    private func volumeName(_ mountPoint: String, local: Bool) -> String {
        if let cached = volumeNames[mountPoint] { return cached }
        var name = mountPoint == "/" ? "Macintosh HD" : (mountPoint as NSString).lastPathComponent
        if local, let values = try? URL(fileURLWithPath: mountPoint).resourceValues(forKeys: [.volumeLocalizedNameKey]),
           let localized = values.volumeLocalizedName, !localized.isEmpty {
            name = localized
        }
        volumeNames[mountPoint] = name
        return name
    }

    private static func apfsVolumes() -> [APFSVolume] {
        var result: [APFSVolume] = []
        IORegistry.forEach(matching: "AppleAPFSVolume") { entry in
            guard let bsd = IORegistry.property(entry, "BSD Name", as: String.self),
                  let stats = IORegistry.property(entry, "Statistics", as: [String: Any].self) else { return }
            let read = (stats["Bytes read from block device"] as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes written to block device"] as? NSNumber)?.uint64Value ?? 0
            result.append(APFSVolume(
                bsdName: bsd,
                group: IORegistry.property(entry, "VolGroupUUID", as: String.self),
                mountFrom: IORegistry.property(entry, "VolGroupMntFromName", as: String.self),
                counter: IOCounter(read: read, write: write)
            ))
        }
        return result
    }

    private static func counter(for device: String, volumes: [APFSVolume]) -> IOCounter? {
        let bsd = String(device.dropFirst("/dev/".count))
        // Exact BSD name, the volume-group mount source (sealed "/" snapshot), or the snapshot's parent volume.
        let volume = volumes.first { $0.bsdName == bsd }
            ?? volumes.first { $0.mountFrom == device }
            ?? volumes.first { bsd.hasPrefix($0.bsdName + "s") }
        if let volume {
            guard let group = volume.group else { return volume.counter }
            return volumes.filter { $0.group == group }.reduce(IOCounter(read: 0, write: 0)) {
                IOCounter(read: $0.read &+ $1.counter.read, write: $0.write &+ $1.counter.write)
            }
        }
        return blockDriverCounter(bsdName: bsd)
    }

    /// Non-APFS media (HFS, FAT, ExFAT): walk up to the IOBlockStorageDriver's statistics.
    private static func blockDriverCounter(bsdName: String) -> IOCounter? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        for _ in 0..<8 {
            if let stats = IORegistry.property(entry, "Statistics", as: [String: Any].self),
               let read = stats["Bytes (Read)"] as? NSNumber,
               let write = stats["Bytes (Write)"] as? NSNumber {
                IOObjectRelease(entry)
                return IOCounter(read: read.uint64Value, write: write.uint64Value)
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }
}
