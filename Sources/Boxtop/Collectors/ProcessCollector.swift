import CSysInfo
import Darwin
import Foundation

/// Process list from `KERN_PROC_ALL` + `proc_pidinfo(PROC_PIDTASKINFO)`, ported from btop's
/// `Proc::collect` (src/osx). Static details (name, path, arguments, user) are cached per pid
/// and only read when a process first appears, like btop's `no_cache` path.
final class ProcessCollector {
    private struct Cached {
        var name: String
        var path: String
        var command: String
        var user: String
        var uid: UInt32
        var startTime: Date
        var lastCPUTicks: UInt64
    }

    private var cache: [Int32: Cached] = [:]
    private var lastTime: UInt64 = 0
    private var users: [UInt32: String] = [:]
    private var argsBuffer = [CChar](repeating: 0, count: 8192)

    func collect() -> [ProcessSample] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        size += 32 * MemoryLayout<kinfo_proc>.stride
        var kprocs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &kprocs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride

        let now = mach_absolute_time()
        let elapsedNanos = lastTime == 0 ? 0 : Double(now - lastTime) * MachTime.nanosPerTick
        lastTime = now
        let wallNow = Date()

        var result: [ProcessSample] = []
        result.reserveCapacity(count)
        var alive = Set<Int32>()

        for kp in kprocs.prefix(count) {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            alive.insert(pid)

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            let ticks = hasTask ? task.pti_total_user + task.pti_total_system : 0

            // A cached entry with a different start time means the pid was reused.
            let start = kp.kp_proc.p_un.__p_starttime
            let startTime = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
            var cached = cache[pid].flatMap { $0.startTime == startTime ? $0 : nil } ?? makeCached(kp: kp, ticks: ticks)
            var cpuPerCore = 0.0
            if hasTask, elapsedNanos > 0, ticks >= cached.lastCPUTicks {
                cpuPerCore = Double(ticks - cached.lastCPUTicks) * MachTime.nanosPerTick / elapsedNanos * 100
            }
            let cpuSeconds = Double(ticks) * MachTime.nanosPerTick / 1_000_000_000
            let lifetime = max(1, wallNow.timeIntervalSince(cached.startTime))
            if hasTask { cached.lastCPUTicks = ticks }
            cache[pid] = cached

            result.append(ProcessSample(
                pid: pid,
                ppid: kp.kp_eproc.e_ppid,
                name: cached.name,
                command: cached.command,
                path: cached.path,
                user: cached.user,
                uid: cached.uid,
                threads: hasTask ? Int(task.pti_threadnum) : 0,
                residentBytes: hasTask ? task.pti_resident_size : 0,
                cpuPerCore: max(0, cpuPerCore),
                cpuLifetime: cpuSeconds / lifetime * 100,
                cpuTimeSeconds: cpuSeconds,
                // macOS reports nearly everything as SRUN; refine with the running-thread count like ps.
                state: {
                    let state = Self.state(kp.kp_proc.p_stat)
                    return state == .running && hasTask && task.pti_numrunning == 0 ? .sleeping : state
                }(),
                nice: Int(kp.kp_proc.p_nice),
                startTime: cached.startTime
            ))
        }
        cache = cache.filter { alive.contains($0.key) }
        return result
    }

    /// Per-process disk I/O for the detail panel (btop `_collect_details`).
    func detail(for pid: Int32) -> ProcessDetailSample? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        var fdCount: Int?
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bytes > 0 { fdCount = Int(bytes) / MemoryLayout<proc_fdinfo>.stride }
        guard ok || fdCount != nil else { return nil }
        return ProcessDetailSample(
            pid: pid,
            diskRead: ok ? usage.ri_diskio_bytesread : 0,
            diskWritten: ok ? usage.ri_diskio_byteswritten : 0,
            openFiles: fdCount
        )
    }

    private func makeCached(kp: kinfo_proc, ticks: UInt64) -> Cached {
        let pid = kp.kp_proc.p_pid
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cChars: pathBuffer) : ""
        let comm = string(fromCTuple: kp.kp_proc.p_comm)
        let name = path.isEmpty ? (comm.isEmpty ? "<defunct>" : comm) : (path as NSString).lastPathComponent

        var command = name
        let written = bt_proc_args(pid, &argsBuffer, Int32(argsBuffer.count))
        if written > 0 { command = String(cChars: argsBuffer) }

        let uid = kp.kp_eproc.e_ucred.cr_uid
        let start = kp.kp_proc.p_un.__p_starttime
        return Cached(
            name: name,
            path: path,
            command: command,
            user: userName(uid),
            uid: uid,
            startTime: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000),
            lastCPUTicks: ticks
        )
    }

    private func userName(_ uid: UInt32) -> String {
        if let name = users[uid] { return name }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? String(uid)
        users[uid] = name
        return name
    }

    private static func state(_ stat: CChar) -> ProcessState {
        switch Int32(stat) {
        case SRUN: .running
        case SSLEEP: .sleeping
        case SIDL: .idle
        case SSTOP: .stopped
        case SZOMB: .zombie
        default: .unknown
        }
    }
}
