// MumblurCore/Sources/MumblurCore/Storage/CustomModelStore.swift
import Foundation
import GRDB

/// A user-added model: either a local CoreML folder on disk, or a custom
/// Hugging Face repo to download a variant from.
public struct CustomModel: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case folder, repo }
    public let id: String          // doubles as Profile.modelID / download variant
    public let kind: Kind
    public let repo: String?       // .repo only
    public let folderPath: String? // .folder only

    public init(id: String, kind: Kind, repo: String? = nil, folderPath: String? = nil) {
        self.id = id; self.kind = kind; self.repo = repo; self.folderPath = folderPath
    }

    public static func folder(id: String, path: String) -> CustomModel {
        .init(id: id, kind: .folder, folderPath: path)
    }
    public static func repo(variant: String, repo: String) -> CustomModel {
        .init(id: variant, kind: .repo, repo: repo)
    }
}

/// Persists the custom-model list as JSON in `app_setting`. Small, unordered,
/// no joins — a real table would be overkill and would need a migration.
public actor CustomModelStore {
    private static let key = "custom_models"
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func all() throws -> [CustomModel] {
        try database.read { db in
            guard let json = try String.fetchOne(db,
                sql: "SELECT value FROM app_setting WHERE key=?", arguments: [Self.key]),
                  let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([CustomModel].self, from: data)) ?? []
        }
    }

    public func get(id: String) throws -> CustomModel? {
        try all().first { $0.id == id }
    }

    /// Insert or replace by `id`.
    public func add(_ model: CustomModel) throws {
        var list = try all().filter { $0.id != model.id }
        list.append(model)
        try write(list)
    }

    public func remove(id: String) throws {
        try write(try all().filter { $0.id != id })
    }

    private func write(_ list: [CustomModel]) throws {
        let json = String(data: try JSONEncoder().encode(list), encoding: .utf8) ?? "[]"
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, arguments: [Self.key, json])
        }
    }
}
