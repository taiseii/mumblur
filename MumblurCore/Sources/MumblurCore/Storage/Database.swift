// MumblurCore/Sources/MumblurCore/Storage/Database.swift
import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    public enum Location { case inMemory; case file(URL) }

    public let queue: DatabaseQueue

    public init(location: Location) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true     // PRAGMA foreign_keys = ON at every open
        switch location {
        case .inMemory:
            self.queue = try DatabaseQueue(configuration: config)
        case .file(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            self.queue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try runMigrations()
    }

    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    public func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.write(block)
    }

    public func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerV1()
        migrator.registerV2()
        try migrator.migrate(queue)
    }
}
