import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
#if canImport(CoreData)
import CoreData
#endif
@testable import Watchtower

final class DatastoreTests: XCTestCase {
    private var got: [Event] = []
    private let lock = NSLock()

    override func setUp() {
        got = []
        Datastore.slowMs = 100
        Datastore.sink = { [weak self] e in self?.lock.lock(); self?.got.append(e); self?.lock.unlock() }
    }

    override func tearDown() {
        Datastore.sink = { Watchtower.shared.record($0) }
        Datastore.slowMs = 100
    }

    func testSummaryKeepsOperationAndTableOnly() {
        XCTAssertEqual(Datastore.querySummary("select * from \"users\" where email = 'a@b'").operation, "SELECT")
        XCTAssertEqual(Datastore.querySummary("select * from \"users\" where email = 'a@b'").collection, "users")
        XCTAssertEqual(Datastore.querySummary("INSERT INTO main.orders VALUES (1)").collection, "main.orders")
        XCTAssertEqual(Datastore.querySummary("").operation, "QUERY")
    }

    func testOnlySlowOrFailedOpsAndMainThreadAgainstOneFrame() {
        XCTAssertNil(Datastore.event(system: "sqlite", operation: "SELECT", ms: 50, mainThread: false))
        XCTAssertNotNil(Datastore.event(system: "sqlite", operation: "SELECT", ms: 120, mainThread: false))
        let main = Datastore.event(system: "realm", operation: "write", namespace: "default.realm", ms: 20, mainThread: true)?.json()
        let a = main?["attrs"] as? [String: Any]
        XCTAssertEqual(main?["type"] as? String, "db")
        XCTAssertEqual(main?["value"] as? Double, 20)
        XCTAssertEqual(a?["db.main_thread"] as? Bool, true)
        XCTAssertEqual(a?["db.namespace"] as? String, "default.realm")
        let failed = Datastore.event(system: "coredata", operation: "save", ms: 1, mainThread: false, error: "NSCocoaErrorDomain:133020")
        XCTAssertEqual((failed?.json()["attrs"] as? [String: Any])?["error.type"] as? String, "NSCocoaErrorDomain:133020")
    }

    func testMeasureRecordsErrorsAndRethrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try Datastore.measure("realm", "write") { throw Boom() })
        XCTAssertEqual(got.count, 1)
        XCTAssertNotNil(got.first?.attrs["error.type"])
        XCTAssertEqual(Datastore.measure("realm", "write") { 7 }, 7)
        XCTAssertEqual(got.count, 1, "fast and fine: not recorded")
    }

    #if canImport(SQLite3)
    func testSQLiteProfileHookReportsStatementsWithoutText() {
        Datastore.slowMs = 0
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        Datastore.instrumentSQLite(db!, name: "app.db")
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE users(email TEXT); INSERT INTO users VALUES ('secret@x')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(got.map(\.name), ["CREATE users", "INSERT users"])
        XCTAssertEqual(got.first?.attrs["db.namespace"] as? String, "app.db")
        XCTAssertFalse(got.contains { "\($0.json())".contains("secret") })
    }
    #endif

    #if canImport(CoreData) && canImport(ObjectiveC)
    func testCoreDataFetchAndSaveAreTimed() throws {
        Datastore.slowMs = 0
        let entity = NSEntityDescription()
        entity.name = "Item"
        let attr = NSAttributeDescription()
        attr.name = "title"
        attr.attributeType = .stringAttributeType
        entity.properties = [attr]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        try psc.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        // a main-queue context, used directly: XCTest runs on the main thread
        let ctx = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        ctx.persistentStoreCoordinator = psc
        Datastore.instrumentCoreData()
        Datastore.instrumentCoreData() // once only: a second swap would undo the first
        NSManagedObject(entity: entity, insertInto: ctx).setValue("a", forKey: "title")
        try ctx.save()
        _ = try ctx.fetch(NSFetchRequest<NSFetchRequestResult>(entityName: "Item"))
        XCTAssertEqual(got.map(\.name), ["save", "fetch Item"])
        XCTAssertEqual(got.last?.attrs["db.system.name"] as? String, "coredata")
        XCTAssertEqual(got.last?.attrs["db.main_thread"] as? Bool, true)
    }
    #endif
}
