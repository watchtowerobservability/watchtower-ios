import Foundation

/// Disk queue of serialized events, one file per event, oldest first. Past `maxBytes` the oldest
/// files are deleted, so an offline device never fills its storage.
final class OfflineBuffer {
    private let dir: URL
    private let maxBytes: Int
    private var seq = 0
    private let lock = NSLock()

    init(dir: URL, maxBytes: Int) {
        self.dir = dir; self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func add(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let name = String(format: "%020d-%06d.json", Int(Date().timeIntervalSince1970 * 1000), seq)
        seq += 1
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        trim()
    }

    func peek(_ max: Int) -> [(URL, Data)] {
        lock.lock(); defer { lock.unlock() }
        return files().prefix(max).compactMap { u in (try? Data(contentsOf: u)).map { (u, $0) } }
    }

    func remove(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return files().count }

    private func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    private func trim() {
        let all = files()
        var total = all.reduce(0) { $0 + size($1) }
        for f in all where total > maxBytes {
            total -= size(f)
            try? FileManager.default.removeItem(at: f)
        }
    }
}
