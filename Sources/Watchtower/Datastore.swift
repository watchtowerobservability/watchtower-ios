import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
#if canImport(CoreData)
import CoreData
#endif

/// Client storage instrumentation (embedded stores). Only slow or failed operations are recorded,
/// as RUM `db` events (value = duration ms) with OTel `db.*` attributes; statement text and values
/// are never sent. Work on the main thread blocks the UI: it is judged against one frame (16 ms)
/// and flagged `db.main_thread`.
///
/// - SQLite (GRDB, SQLite.swift, FMDB, raw): `Datastore.instrumentSQLite(handle, name:)`.
/// - Core Data: `Datastore.instrumentCoreData()` (fetch, batch requests and save).
/// - SwiftData, Realm and anything else: `Datastore.measure("realm", "write") { ... }`.
/// - File sizes: `Datastore.recordStoreSize(system: "sqlite", url: storeURL)`.
public enum Datastore {
    /// Operations off the main thread at or over this many ms are reported (default 100).
    public static var slowMs: Double = 100
    static let frameMs: Double = 16
    /// Where events go; tests replace it.
    static var sink: (Event) -> Void = { Watchtower.shared.record($0) }

    /// The `db` event for one operation, or nil when it was fast and succeeded. Pure.
    static func event(system: String, operation: String, collection: String? = nil, namespace: String? = nil,
                      ms: Double, mainThread: Bool, error: String? = nil, attrs: [String: Any] = [:]) -> Event? {
        let limit = mainThread ? min(slowMs, frameMs) : slowMs
        guard error != nil || ms >= limit else { return nil }
        let summary = [operation, collection].compactMap { $0 }.joined(separator: " ")
        var a = attrs
        a["db.system.name"] = system
        a["db.operation.name"] = operation
        a["db.query.summary"] = summary
        if let c = collection { a["db.collection.name"] = c }
        if let n = namespace { a["db.namespace"] = n }
        if mainThread { a["db.main_thread"] = true }
        if let e = error { a["error.type"] = e }
        return Event(type: "db", name: summary, value: max(0, ms).rounded(), attrs: a)
    }

    static func report(system: String, operation: String, collection: String? = nil, namespace: String? = nil,
                       ms: Double, mainThread: Bool, error: Error? = nil, attrs: [String: Any] = [:]) {
        // domain and code only: messages can quote values (a failed constraint, a key)
        let err = error.map { e -> String in let ns = e as NSError; return "\(ns.domain):\(ns.code)" }
        if let e = event(system: system, operation: operation, collection: collection, namespace: namespace,
                         ms: ms, mainThread: mainThread, error: err, attrs: attrs) { sink(e) }
    }

    /// Times `body` (synchronous). Rethrows its error after recording it.
    @discardableResult
    public static func measure<T>(_ system: String, _ operation: String, collection: String? = nil,
                                  namespace: String? = nil, _ body: () throws -> T) rethrows -> T {
        let main = Thread.isMainThread
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ms = { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        do {
            let r = try body()
            report(system: system, operation: operation, collection: collection, namespace: namespace, ms: ms(), mainThread: main)
            return r
        } catch {
            report(system: system, operation: operation, collection: collection, namespace: namespace, ms: ms(),
                   mainThread: main, error: error)
            throw error
        }
    }

    /// Times an async `body`; its duration includes suspension, so it is never judged as main-thread work.
    @discardableResult
    public static func measure<T>(_ system: String, _ operation: String, collection: String? = nil,
                                  namespace: String? = nil, _ body: () async throws -> T) async rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ms = { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        do {
            let r = try await body()
            report(system: system, operation: operation, collection: collection, namespace: namespace, ms: ms(), mainThread: false)
            return r
        } catch {
            report(system: system, operation: operation, collection: collection, namespace: namespace, ms: ms(),
                   mainThread: false, error: error)
            throw error
        }
    }

    private static let opRe = try? NSRegularExpression(pattern: #"^\s*(?:with\b[\s\S]*?\)\s*)?([a-z]+)"#, options: .caseInsensitive)
    private static let targetRe = try? NSRegularExpression(
        pattern: #"\b(?:from|into|update|join|table)\s+((?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$]+)(?:\.(?:"[^"]+"|[\w$]+))?)"#,
        options: .caseInsensitive)

    /// `SELECT users`-style parts (same rules as the other SDKs): never values or the statement text.
    public static func querySummary(_ sql: String) -> (operation: String, collection: String?) {
        func group(_ re: NSRegularExpression?) -> String? {
            let r = NSRange(sql.startIndex..., in: sql)
            guard let m = re?.firstMatch(in: sql, range: r), let g = Range(m.range(at: 1), in: sql) else { return nil }
            return String(sql[g])
        }
        let op = group(opRe)?.uppercased() ?? "QUERY"
        let target = group(targetRe)?.filter { !"\"`[]".contains($0) }
        return (op, target)
    }

    /// Reports the store file's size and, when present, its `-wal` file as `storage` events
    /// (`wt.embedded.file_size`, `wt.embedded.wal_size`). Read off the main thread.
    public static func recordStoreSize(system: String, url: URL, namespace: String? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let ns = namespace ?? url.lastPathComponent
            func size(_ p: String) -> Int64? { (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int64 }
            let at: [String: Any] = ["db.system.name": system, "db.namespace": ns]
            if let s = size(url.path) { sink(Event(type: "storage", name: "wt.embedded.file_size", value: Double(s), attrs: at)) }
            if let w = size(url.path + "-wal") { sink(Event(type: "storage", name: "wt.embedded.wal_size", value: Double(w), attrs: at)) }
        }
    }
}

#if canImport(SQLite3)
private final class NameBox { let name: String?; init(_ n: String?) { name = n } }

extension Datastore {
    /// Times every statement on a SQLite connection with `sqlite3_trace_v2(SQLITE_TRACE_PROFILE)`; the
    /// callback runs on the thread that stepped the statement, so main-thread queries are flagged.
    /// Handles: GRDB `db.sqliteConnection` (in `Configuration.prepareDatabase`), SQLite.swift
    /// `connection.handle`, FMDB `db.sqliteHandle`. It replaces any trace callback already set
    /// (GRDB's `db.trace` included). Profile events carry no error codes.
    /// shortcut: the name box is retained for the process lifetime (one per connection, a few bytes).
    public static func instrumentSQLite(_ db: OpaquePointer, name: String? = nil) {
        let box = Unmanaged.passRetained(NameBox(name)).toOpaque()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, ctx, p, x in
            guard let p = p, let x = x else { return 0 }
            let ns = Double(x.assumingMemoryBound(to: Int64.self).pointee) / 1e6
            let sql = sqlite3_sql(OpaquePointer(p)).map { String(cString: $0) } ?? ""
            let name = ctx.flatMap { Unmanaged<NameBox>.fromOpaque($0).takeUnretainedValue().name }
            let q = Datastore.querySummary(sql)
            Datastore.report(system: "sqlite", operation: q.operation, collection: q.collection, namespace: name,
                             ms: ns, mainThread: Thread.isMainThread)
            return 0
        }, box)
    }
}
#endif

#if canImport(CoreData) && canImport(ObjectiveC)
extension Datastore {
    private static let coreDataSwizzled: Void = {
        let cls = NSManagedObjectContext.self
        // by Objective-C name: Swift's generic `fetch` overlay makes `#selector` ambiguous
        for (a, b) in [("executeFetchRequest:error:", "wt_executeFetchRequest:error:"),
                       ("executeRequest:error:", "wt_executeRequest:error:"), ("save:", "wt_save:")] {
            if let m = class_getInstanceMethod(cls, NSSelectorFromString(a)),
               let n = class_getInstanceMethod(cls, NSSelectorFromString(b)) { method_exchangeImplementations(m, n) }
        }
    }()

    /// Swizzles `NSManagedObjectContext` fetch, execute (batch requests) and save, once. Main-queue
    /// contexts doing heavy fetches or saves show up flagged `db.main_thread`.
    public static func instrumentCoreData() { _ = coreDataSwizzled }
}

extension NSManagedObjectContext {
    var wtStoreName: String? { persistentStoreCoordinator?.persistentStores.first?.url?.lastPathComponent }

    @objc(wt_executeFetchRequest:error:)
    func wt_fetch(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        try Datastore.measure("coredata", "fetch", collection: request.entityName, namespace: wtStoreName) {
            try wt_fetch(request) // the original, after the swap
        }
    }

    @objc(wt_executeRequest:error:)
    func wt_execute(_ request: NSPersistentStoreRequest) throws -> NSPersistentStoreResult {
        let entity = (request as? NSBatchDeleteRequest)?.fetchRequest.entityName
            ?? (request as? NSBatchUpdateRequest)?.entityName ?? (request as? NSBatchInsertRequest)?.entityName
        return try Datastore.measure("coredata", "execute", collection: entity, namespace: wtStoreName) { try wt_execute(request) }
    }

    @objc(wt_save:)
    func wt_save() throws {
        guard hasChanges else { return try wt_save() }
        try Datastore.measure("coredata", "save", namespace: wtStoreName) { try wt_save() }
    }
}
#endif
