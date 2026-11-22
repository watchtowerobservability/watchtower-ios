import Foundation
import MachO

/// Async-signal-safe capture of fatal signals (the KSCrash pattern). Everything the handler
/// touches is set up at install: a file descriptor opened ahead of time, a preallocated frame
/// array, a scratch line and an alternate signal stack (so a stack overflow can still be
/// reported). The handler only calls `backtrace` (frame-pointer walk, warmed up at install),
/// `write`, `signal` and `raise`: no allocation, no locks, no Swift runtime calls. The report is
/// a few text lines (the crashing thread's frames, then every other thread's, see `ThreadWalker`);
/// the next launch turns it into an error event and deletes it. The images loaded at install are
/// saved beside it (`images.json`) so the next launch can name each address's module and dSYM.
enum CrashReport {
    static let maxFrames: Int32 = 128
    private static let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    private static var fd: Int32 = -1
    private static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private static var scratch: UnsafeMutablePointer<UInt8>?
    private static var imageBase: UInt = 0
    /// Set by the exception handler, which records the crash itself; the SIGABRT that follows
    /// must not write a second report.
    static var exceptionRecorded: Int32 = 0

    static func file(_ dir: URL) -> URL { dir.appendingPathComponent("signal.report") }
    static func imagesFile(_ dir: URL) -> URL { dir.appendingPathComponent("images.json") }

    /// Open the report file and install the handlers. Call `collect` first: this truncates it.
    static func install(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(file(dir).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        let imagesURL = imagesFile(dir)
        // dyld calls back for every image now and each one loaded later; the list is rewritten after each batch
        Images.track { if let d = try? JSONEncoder().encode(Images.loaded()) { try? d.write(to: imagesURL) } }
        ThreadWalker.recordMainThread()
        frames = .allocate(capacity: Int(maxFrames))
        scratch = .allocate(capacity: 32)
        if let h = _dyld_get_image_header(0) { imageBase = UInt(bitPattern: h) }
        _ = backtrace(frames, maxFrames) // first call may load libunwind state: never in the handler
        let stackSize = 64 * 1024
        var ss = stack_t(ss_sp: malloc(stackSize), ss_size: stackSize, ss_flags: 0)
        if ss.ss_sp != nil { _ = sigaltstack(&ss, nil) }
        for s in signals {
            var sa = sigaction()
            sa.__sigaction_u = __sigaction_u(__sa_handler: handler)
            sa.sa_flags = SA_ONSTACK
            sa.sa_mask = 0 // sigset_t is a bit mask on Darwin
            _ = sigaction(s, &sa, nil)
        }
    }

    private static let handler: @convention(c) (Int32) -> Void = { s in
        if CrashReport.exceptionRecorded == 0 { CrashReport.writeReport(s) }
        signal(s, SIG_DFL)
        raise(s)
    }

    /// The handler's body (also called by tests). Async-signal-safe.
    static func writeReport(_ sig: Int32) {
        guard fd >= 0, let frames, let scratch else { return }
        put("wt-crash v1\nsignal ")
        putDecimal(UInt(bitPattern: Int(sig)), scratch)
        put("\nbase ")
        putHex(imageBase, scratch)
        put("frames\n")
        let n = backtrace(frames, maxFrames)
        var i = 0
        while i < Int(n) {
            putHex(UInt(bitPattern: frames[i]), scratch)
            i += 1
        }
        // the other threads (a suspended thread cannot change under the walk)
        ThreadWalker.walk(thread: { index, _ in
            put("thread ")
            putDecimal(UInt(index + 1), scratch)
            put("\n")
        }, frame: { putHex($0, scratch) })
    }

    private static func put(_ s: StaticString) {
        _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
    }

    private static func putHex(_ v: UInt, _ b: UnsafeMutablePointer<UInt8>) {
        b[0] = 0x30; b[1] = 0x78 // "0x"
        var i = 2
        var shift = UInt.bitWidth - 4
        while true {
            let d = UInt8((v >> UInt(shift)) & 0xf)
            b[i] = d < 10 ? 0x30 + d : 0x57 + d
            i += 1
            if shift == 0 { break }
            shift -= 4
        }
        b[i] = 0x0a
        _ = write(fd, b, i + 1)
    }

    private static func putDecimal(_ v: UInt, _ b: UnsafeMutablePointer<UInt8>) {
        var n = v, i = 31
        repeat {
            b[i] = 0x30 + UInt8(n % 10)
            n /= 10
            i -= 1
        } while n > 0 && i >= 0
        _ = write(fd, b + i + 1, 31 - i)
    }

    /// The report a previous launch left behind, as an error event; the file is removed.
    static func collect(_ dir: URL) -> Event? {
        let f = file(dir)
        defer { try? FileManager.default.removeItem(at: f) }
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let images = (try? Data(contentsOf: imagesFile(dir))).flatMap { try? JSONDecoder().decode([ImageInfo].self, from: $0) } ?? []
        return parse(text, images: images)
    }

    /// `images` are the previous run's loaded images; with them the event carries parsed frames,
    /// the other threads and the image table the server symbolicates with.
    static func parse(_ text: String, images: [ImageInfo] = []) -> Event? {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.first == "wt-crash v1", lines.count >= 3,
              lines[1].hasPrefix("signal "), let sig = Int32(lines[1].dropFirst(7)) else { return nil }
        let base = lines[2].hasPrefix("base ") ? String(lines[2].dropFirst(5)) : ""
        var stack: [String] = []
        var others: [[String]] = []
        for l in lines.drop(while: { $0 != "frames" }).dropFirst() {
            if l.hasPrefix("thread ") { others.append([]) }
            else if others.isEmpty { stack.append(l) }
            else { others[others.count - 1].append(l) }
        }
        var attrs: [String: Any] = [
            "error.stack": stack.joined(separator: "\n"),
            "crash.class": "signal", "crash.handled": false, "crash.previous_session": true,
            "crash.image_base": base,
        ]
        let wire = NativeStacks.attrs(stack: NativeStacks.addresses(stack),
                                      threads: others.map(NativeStacks.addresses), images: images)
        attrs.merge(wire) { _, w in w }
        return Event(type: "error", name: "signal \(sig)", attrs: attrs)
    }
}
