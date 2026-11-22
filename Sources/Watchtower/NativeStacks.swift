import Foundation
import MachO

/// One loaded Mach-O image: where it is, its `__TEXT` size and its `LC_UUID` (the dSYM's id).
struct ImageInfo: Codable, Equatable {
    var name: String
    var base: UInt64
    var size: UInt64
    var vmaddr: UInt64
    var uuid: String

    func contains(_ a: UInt64) -> Bool { a >= base && a - base < size }
}

enum Images {
    private static let lock = NSLock()
    private static var known: [ImageInfo] = []
    private static var tracking = false
    private static var onChange: (() -> Void)?
    private static var pending = false

    /// The images loaded now: once `track` runs, the registry it keeps up to date (so images loaded
    /// later with `dlopen` are in a crash report too), else a fresh walk of dyld's list.
    static func loaded() -> [ImageInfo] {
        lock.lock(); defer { lock.unlock() }
        return tracking ? known : enumerate()
    }

    /// Starts following dyld: every image already loaded and each one loaded later is added, and
    /// `changed` runs (debounced, off the loading thread) after additions so the caller can persist the list.
    static func track(_ changed: @escaping () -> Void) {
        lock.lock()
        if tracking { onChange = changed; lock.unlock(); return }
        tracking = true; onChange = changed
        lock.unlock()
        _dyld_register_func_for_add_image { header, _ in
            guard let header else { return }
            var di = Dl_info()
            let name = dladdr(UnsafeRawPointer(header), &di) != 0 ? di.dli_fname.map { String(cString: $0) } ?? "" : ""
            if let i = Images.info(UnsafeRawPointer(header), name: name) { Images.add(i) }
        }
    }

    private static func add(_ i: ImageInfo) {
        lock.lock()
        if !known.contains(where: { $0.base == i.base }) { known.append(i) }
        let schedule = !pending
        pending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            lock.lock(); pending = false; let cb = onChange; lock.unlock()
            cb?()
        }
    }

    private static func enumerate() -> [ImageInfo] {
        (0..<_dyld_image_count()).compactMap { i in
            guard let h = _dyld_get_image_header(i) else { return nil }
            let name = _dyld_get_image_name(i).map { String(cString: $0) } ?? ""
            return info(UnsafeRawPointer(h), name: name)
        }
    }

    /// Reads the load commands at a 64-bit Mach-O header; nil without an `LC_UUID`.
    static func info(_ p: UnsafeRawPointer, name: String) -> ImageInfo? {
        let h = p.assumingMemoryBound(to: mach_header_64.self).pointee
        guard h.magic == UInt32(MH_MAGIC_64) else { return nil }
        var cmd = p + MemoryLayout<mach_header_64>.size
        var uuid: String?
        var vm: UInt64 = 0, size: UInt64 = 0
        for _ in 0..<h.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == UInt32(LC_UUID) {
                let u = cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                uuid = UUID(uuid: u).uuidString.lowercased()
            } else if lc.cmd == UInt32(LC_SEGMENT_64) {
                let s = cmd.assumingMemoryBound(to: segment_command_64.self).pointee
                let seg = withUnsafeBytes(of: s.segname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                if seg == "__TEXT" { vm = s.vmaddr; size = s.vmsize }
            }
            cmd += Int(lc.cmdsize)
        }
        guard let id = uuid else { return nil }
        return ImageInfo(name: name, base: UInt64(UInt(bitPattern: p)), size: size, vmaddr: vm, uuid: id)
    }
}

/// Turns raw addresses (a crash report, a hang snapshot) into the wire attributes the server
/// symbolicates: `frames` (the stack that crashed or hung), `threads` (the others) and
/// `debug_images` (where each image was loaded, so absolute addresses become module-relative).
enum NativeStacks {
    /// Wire budget of the `threads` attribute: the edge keeps 32 KiB, the worker 24 KiB.
    static let threadsBudget = 22_000
    static let wireFramesPerThread = 32

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    /// `0x..` lines as addresses; anything else is skipped.
    static func addresses(_ lines: [String]) -> [UInt64] {
        lines.compactMap { $0.hasPrefix("0x") ? UInt64($0.dropFirst(2), radix: 16) : nil }
    }

    /// Frames oldest call first (the wire order) from `addrs`, innermost first.
    static func frames(_ addrs: [UInt64], _ images: [ImageInfo]) -> [[String: Any]] {
        addrs.reversed().map { a in
            var f: [String: Any] = ["function": "", "instruction_addr": hex(a)]
            if let i = images.first(where: { $0.contains(a) }) {
                f["module"] = (i.name as NSString).lastPathComponent
                f["debug_id"] = i.uuid
                f["in_app"] = i.name.hasPrefix(Bundle.main.bundlePath)
            }
            return f
        }
    }

    static func attrs(stack: [UInt64]?, threads: [[UInt64]], images: [ImageInfo]) -> [String: Any] {
        guard !images.isEmpty else { return [:] }
        var out: [String: Any] = [:]
        if let s = stack, !s.isEmpty { out["frames"] = frames(s, images) }
        var used = 0
        var ts: [[String: Any]] = []
        for (i, t) in threads.enumerated() where !t.isEmpty {
            let th: [String: Any] = ["id": i + 1, "frames": frames(Array(t.prefix(wireFramesPerThread)), images)]
            let n = (try? JSONSerialization.data(withJSONObject: th).count) ?? Int.max
            if used + n > threadsBudget { break }
            used += n
            ts.append(th)
        }
        if !ts.isEmpty { out["threads"] = ts }
        let all = (stack ?? []) + threads.flatMap { $0 }
        let seen = images.filter { i in all.contains(where: i.contains) }
        if !seen.isEmpty {
            out["debug_images"] = seen.map { i -> [String: Any] in
                ["debug_id": i.uuid, "image_addr": hex(i.base), "image_vmaddr": hex(i.vmaddr),
                 "name": (i.name as NSString).lastPathComponent]
            }
        }
        return out
    }
}
