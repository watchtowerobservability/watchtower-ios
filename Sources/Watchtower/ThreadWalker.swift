import Foundation
import MachO

/// Stacks of every thread but the caller's, read with Mach calls (the way KSCrash does): each
/// other thread is suspended, its registers read, and its frame-pointer chain followed with
/// `vm_read_overwrite` (so a bad pointer ends the walk, never faults). `walk` allocates nothing
/// itself, so the signal handler can use it; `snapshot` is the allocating form for the exception
/// and hang paths.
enum ThreadWalker {
    static let maxThreads = 24
    static let maxFrames = 48
    /// The main thread's Mach port, set once at install (from the main queue).
    static var mainThread: mach_port_t = 0

    #if arch(arm64)
    private static let addrMask: UInt = 0x0000_007F_FFFF_FFFF // strips pointer-authentication bits
    #else
    private static let addrMask: UInt = .max
    #endif

    struct Snapshot {
        /// Innermost frame first, one array per thread.
        var threads: [[UInt64]] = []
        var mainIndex: Int?
    }

    static func recordMainThread() {
        // `start` normally runs on the main thread: known at once, before the first launch sample
        if Thread.isMainThread { mainThread = mach_thread_self() } else { DispatchQueue.main.async { mainThread = mach_thread_self() } }
    }

    /// Calls `thread` before each thread's frames, then `frame` per address (innermost first).
    /// With `only` set, just that thread is walked.
    static func walk(only: mach_port_t = 0, thread: (_ index: Int, _ isMain: Bool) -> Void, frame: (UInt) -> Void) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let threads = list else { return }
        let me = mach_thread_self()
        var seen = 0
        var i = 0
        while i < Int(count) && seen < maxThreads {
            let t = threads[i]
            i += 1
            if t == me || (only != 0 && t != only) || thread_suspend(t) != KERN_SUCCESS { continue }
            thread(seen, t == mainThread)
            seen += 1
            walkOne(t, frame)
            _ = thread_resume(t)
        }
    }

    static func snapshot() -> Snapshot {
        var s = Snapshot()
        walk(thread: { _, isMain in
            if isMain { s.mainIndex = s.threads.count }
            s.threads.append([])
        }, frame: { a in
            s.threads[s.threads.count - 1].append(UInt64(a))
        })
        return s
    }

    private static func walkOne(_ t: thread_act_t, _ frame: (UInt) -> Void) {
        var pc: UInt = 0, fp: UInt = 0, lr: UInt = 0
        #if arch(arm64)
        var st = arm_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let cap = Int(n)
        let kr = withUnsafeMutablePointer(to: &st) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: cap) {
                thread_get_state(t, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &n)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        pc = UInt(st.__pc) & addrMask
        fp = UInt(st.__fp)
        lr = UInt(st.__lr) & addrMask
        #elseif arch(x86_64)
        var st = x86_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let cap = Int(n)
        let kr = withUnsafeMutablePointer(to: &st) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: cap) {
                thread_get_state(t, thread_state_flavor_t(x86_THREAD_STATE64), $0, &n)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        pc = UInt(st.__rip)
        fp = UInt(st.__rbp)
        #else
        return
        #endif
        var depth = 0
        var last: UInt = 0
        if pc != 0 { frame(pc); depth += 1; last = pc }
        if lr != 0 && lr != last { frame(lr); depth += 1; last = lr } // the caller of a leaf function
        var pair: (UInt, UInt) = (0, 0)
        while depth < maxFrames, fp != 0, fp & 7 == 0, readPair(fp, &pair) {
            let ret = pair.1 & addrMask
            if ret == 0 { break }
            if ret != last { frame(ret); depth += 1; last = ret }
            if pair.0 <= fp { break } // the chain must climb
            fp = pair.0
        }
    }

    /// The two words at `addr` (saved frame pointer, return address), false when unreadable.
    private static func readPair(_ addr: UInt, _ out: inout (UInt, UInt)) -> Bool {
        var got: vm_size_t = 0
        let ok = withUnsafeMutablePointer(to: &out) { p in
            vm_read_overwrite(mach_task_self_, vm_address_t(addr), 16, vm_address_t(UInt(bitPattern: p)), &got) == KERN_SUCCESS
        }
        return ok && got == 16
    }
}
