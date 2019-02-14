import XCTest
#if GRDBCIPHER
    import GRDBCipher
#elseif GRDBCUSTOMSQLITE
    import GRDBCustomSQLite
#else
    #if SWIFT_PACKAGE
        import CSQLite
    #else
        import SQLite3
    #endif
    import GRDB
#endif

class ValueObservationSchedulingTests: GRDBTestCase {
    func testMainQueueObservationStartedFromMainQueue() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let key = DispatchSpecificKey<()>()
            DispatchQueue.main.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            
            _ = try observation.start(in: dbWriter) { count in
                XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                counts.append(count)
                notificationExpectation.fulfill()
            }
            // .mainQueue scheduling: initial value MUST be synchronously
            // dispatched when observation is started from the main queue
            XCTAssertEqual(counts, [0])
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    @available(OSX 10.10, *) // DispatchQueue qos
    func testMainQueueObservationStartedFromAnotherQueue() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let key = DispatchSpecificKey<()>()
            DispatchQueue.main.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            
            DispatchQueue.global(qos: .default).async {
                _ = try! observation.start(in: dbWriter) { count in
                    XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                    counts.append(count)
                    notificationExpectation.fulfill()
                }
                
                try! dbWriter.write {
                    try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
                }
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testMainQueueError() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var errorCount = 0
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let key = DispatchSpecificKey<()>()
            DispatchQueue.main.setSpecific(key: key, value: ())
            
            var nextError: Error? = nil // If not null, reducer throws an error
            let reducer = AnyValueReducer(
                fetch: { _ -> Void in
                    if let error = nextError {
                        nextError = nil
                        throw error
                    }
            },
                value: { $0 })
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, reducer: { _ in reducer })
            observation.extent = .databaseLifetime
            
            _ = try observation.start(
                in: dbWriter,
                onError: { error in
                    XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                    errorCount += 1
                    notificationExpectation.fulfill()
            },
                onChange: { _ in
                    XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                    notificationExpectation.fulfill()
            })
            
            struct TestError: Error { }
            nextError = TestError()
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(errorCount, 1)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testCustomQueueStartImmediately() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let queue = DispatchQueue(label: "")
            let key = DispatchSpecificKey<()>()
            queue.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            observation.scheduling = .onQueue(queue, startImmediately: true)
            
            _ = try observation.start(in: dbWriter) { count in
                XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testCustomQueueDontStartImmediately() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 1
            
            let queue = DispatchQueue(label: "")
            let key = DispatchSpecificKey<()>()
            queue.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            observation.scheduling = .onQueue(queue, startImmediately: false)
            
            _ = try observation.start(in: dbWriter) { count in
                XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testCustomQueueError() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var errorCount = 0
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 1
            
            let queue = DispatchQueue(label: "")
            let key = DispatchSpecificKey<()>()
            queue.setSpecific(key: key, value: ())
            
            struct TestError: Error { }
            let reducer = AnyValueReducer(
                fetch: { _ in throw TestError() },
                value: { $0 })
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, reducer: { _ in reducer })
            observation.extent = .databaseLifetime
            observation.scheduling = .onQueue(queue, startImmediately: false)
            
            _ = try observation.start(
                in: dbWriter,
                onError: { error in
                    XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                    errorCount += 1
                    notificationExpectation.fulfill()
            },
                onChange: { _ in fatalError() })
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(errorCount, 1)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testUnsafeStartImmediatelyFromMainQueue() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let key = DispatchSpecificKey<()>()
            DispatchQueue.main.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            observation.scheduling = .unsafe(startImmediately: true)
            
            _ = try observation.start(in: dbWriter) { count in
                if counts.isEmpty {
                    // require main queue on first element
                    XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                }
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testUnsafeStartImmediatelyFromCustomQueue() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            let queue = DispatchQueue(label: "")
            let key = DispatchSpecificKey<()>()
            queue.setSpecific(key: key, value: ())
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            observation.scheduling = .unsafe(startImmediately: true)
            
            queue.async {
                _ = try! observation.start(in: dbWriter) { count in
                    if counts.isEmpty {
                        // require custom queue on first notification
                        XCTAssertNotNil(DispatchQueue.getSpecific(key: key))
                    }
                    counts.append(count)
                    notificationExpectation.fulfill()
                }
                
                try! dbWriter.write {
                    try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
                }
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testUnsafeDontStartImmediately() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 1
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            observation.scheduling = .unsafe(startImmediately: false)
            
            _ = try observation.start(in: dbWriter) { count in
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [1])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testUnsafeError() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(rawSQL: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var errorCount = 0
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 1
            
            struct TestError: Error { }
            let reducer = AnyValueReducer(
                fetch: { _ in throw TestError() },
                value: { $0 })
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, reducer: { _ in reducer })
            observation.extent = .databaseLifetime
            observation.scheduling = .unsafe(startImmediately: false)
            
            _ = try observation.start(
                in: dbWriter,
                onError: { error in
                    errorCount += 1
                    notificationExpectation.fulfill()
            },
                onChange: { _ in fatalError() })
            
            try dbWriter.write {
                try $0.execute(rawSQL: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(errorCount, 1)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
}
