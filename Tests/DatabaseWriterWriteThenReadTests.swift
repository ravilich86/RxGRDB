import GRDB
import RxBlocking
import RxGRDB
import RxSwift
import XCTest

private struct Player: Codable, FetchableRecord, PersistableRecord {
    var id: Int64
    var name: String
    var score: Int?
    
    static func createTable(_ db: Database) throws {
        try db.create(table: "player") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("score", .integer)
        }
    }
}

class DatabaseWriterWriteThenReadTests : XCTestCase {
    func testRxJoiner() {
        // Make sure `rx` joiner is available in various contexts
        func f1(_ writer: DatabasePool) {
            _ = writer.rx.write(updates: { db in })
        }
        func f2(_ writer: DatabaseQueue) {
            _ = writer.rx.write(updates: { db in })
        }
        func f3<Writer: DatabaseWriter>(_ writer: Writer) {
            _ = writer.rx.write(updates: { db in })
        }
        func f4(_ writer: DatabaseWriter) {
            _ = writer.rx.write(updates: { db in })
        }
    }
    
    func testRxWriteThenRead() throws {
        func setup<Writer: DatabaseWriter>(_ writer: Writer) throws -> Writer {
            try writer.write(Player.createTable)
            return writer
        }
        
        func test(writer: DatabaseWriter, disposeBag: DisposeBag) throws {
            let single: Single<Int> = writer.rx.write(
                updates: { db in try Player(id: 1, name: "Arthur", score: 1000).insert(db) },
                thenRead: { (db, _) in try Player.fetchCount(db) })
            try XCTAssertEqual(writer.read(Player.fetchCount), 0)
            let count = try single.toBlocking(timeout: 1).single()
            XCTAssertEqual(count, 1)
        }
        
        try Test(test).run { try setup(DatabaseQueue()) }
            .runAtPath { try setup(DatabaseQueue(path: $0)) }
            .runAtPath { try setup(DatabasePool(path: $0)) }
    }
    
    func testRxWriteValueThenRead() throws {
        func setup<Writer: DatabaseWriter>(_ writer: Writer) throws -> Writer {
            try writer.write(Player.createTable)
            return writer
        }
        
        func test(writer: DatabaseWriter, disposeBag: DisposeBag) throws {
            let single: Single<Int> = writer.rx.write(
                updates: { db -> Int in
                    try Player(id: 1, name: "Arthur", score: 1000).insert(db)
                    return 42
            },
                thenRead: { (db, int) in try int + Player.fetchCount(db) })
            try XCTAssertEqual(writer.read(Player.fetchCount), 0)
            let count = try single.toBlocking(timeout: 1).single()
            XCTAssertEqual(count, 43)
        }
        
        try Test(test).run { try setup(DatabaseQueue()) }
            .runAtPath { try setup(DatabaseQueue(path: $0)) }
            .runAtPath { try setup(DatabasePool(path: $0)) }
    }
    
    func testRxWriteThenReadScheduler() throws {
        if #available(OSX 10.12, iOS 10.0, watchOS 3.0, *) {
            func setup<Writer: DatabaseWriter>(_ writer: Writer) throws -> Writer {
                try writer.write { db in
                    try Player.createTable(db)
                }
                return writer
            }
            
            func test(writer: DatabaseWriter, disposeBag: DisposeBag) throws {
                do {
                    let single = writer.rx
                        .write(
                            updates: { db in try Player(id: 1, name: "Arthur", score: 1000).insert(db) },
                            thenRead: { (db, _) in try Player.fetchCount(db) })
                        .do(onSuccess: { _ in
                            dispatchPrecondition(condition: .onQueue(.main))
                        })
                    _ = try single.toBlocking(timeout: 1).single()
                }
                do {
                    let queue = DispatchQueue(label: "test")
                    let single = writer.rx
                        .write(
                            observeOn: SerialDispatchQueueScheduler(queue: queue, internalSerialQueueName: "test"),
                            updates: { db in try Player(id: 2, name: "Barbara", score: nil).insert(db) },
                            thenRead: { (db, _) in try Player.fetchCount(db) })
                        .do(onSuccess: { _ in
                            dispatchPrecondition(condition: .onQueue(queue))
                        })
                    _ = try single.toBlocking(timeout: 1).single()
                }
            }
            
            try Test(test)
                .run { try setup(DatabaseQueue()) }
                .runAtPath { try setup(DatabaseQueue(path: $0)) }
                .runAtPath { try setup(DatabasePool(path: $0)) }
        }
    }
    
    func testRxWriteThenReadIsReadOnly() throws {
        func test(writer: DatabaseWriter, disposeBag: DisposeBag) throws {
            let single = writer.rx.write(
                updates: { _ in },
                thenRead: { (db, _) in try Player.createTable(db) })
            
            let sequence = single
                .asObservable()
                .toBlocking(timeout: 1)
                .materialize()
            switch sequence {
            case .completed:
                XCTFail("Expected error")
            case let .failed(elements: elements, error: error):
                XCTAssertTrue(elements.isEmpty)
                guard let dbError = error as? DatabaseError else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
                XCTAssertEqual(dbError.resultCode, .SQLITE_READONLY)
            }
        }
        
        try Test(test)
            .run { DatabaseQueue() }
            .runAtPath { try DatabaseQueue(path: $0) }
            .runAtPath { try DatabasePool(path: $0) }
    }
}
