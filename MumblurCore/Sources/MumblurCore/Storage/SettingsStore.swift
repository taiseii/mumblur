// MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift
import Foundation
import GRDB

public enum SettingsStoreError: Error, Equatable {
    case cannotDeleteLastActive
}

public actor SettingsStore {
    private let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func create(name: String, modelID: String, language: String? = nil,
                       initialPrompt: String? = nil) throws -> Profile {
        let id = UUID().uuidString
        let now = Date()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO profile(id,name,language,model_id,initial_prompt,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?)
            """, arguments: [id, name, language, modelID, initialPrompt,
                             Int64(now.timeIntervalSince1970 * 1000),
                             Int64(now.timeIntervalSince1970 * 1000)])
        }
        return Profile(id: id, name: name, language: language, modelID: modelID,
                       initialPrompt: initialPrompt, vocab: [], rules: [],
                       createdAt: now, updatedAt: now, deletedAt: nil)
    }

    public func listActive() throws -> [Profile] {
        try database.read { db in
            try Profile.fetchAllActive(db)
        }
    }

    public func get(profileID: String, includeDeleted: Bool = false) throws -> Profile? {
        try database.read { db in
            try Profile.fetchOne(db, id: profileID, includeDeleted: includeDeleted)
        }
    }

    /// Count of profiles that are not soft-deleted.
    public func lastActive() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile WHERE deleted_at IS NULL") ?? 0
        }
    }

    /// The active profile if the pointer resolves to a non-deleted row, else the
    /// first active profile by name, else nil. Never returns a soft-deleted row.
    public func activeOrFirstActive() throws -> Profile? {
        if let id = try activeProfileID(), let p = try get(profileID: id) {
            return p   // get() filters out soft-deleted by default
        }
        return try listActive().first
    }

    public func update(_ profile: Profile) throws {
        let updated = Date()
        try database.write { db in
            try db.execute(sql: """
                UPDATE profile SET name=?, language=?, model_id=?, initial_prompt=?,
                                   llm_edit_enabled=?, llm_edit_prompt=?, updated_at=?
                WHERE id=?
            """, arguments: [profile.name, profile.language, profile.modelID,
                             profile.initialPrompt,
                             profile.llmEditEnabled ? 1 : 0, profile.llmEditPrompt,
                             Int64(updated.timeIntervalSince1970 * 1000),
                             profile.id])
        }
    }

    public func softDelete(profileID: String) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT deleted_at FROM profile WHERE id=?", arguments: [profileID]) else {
                return  // no such profile; nothing to do
            }
            if (row["deleted_at"] as Int64?) != nil {
                return  // already soft-deleted: idempotent no-op, don't re-stamp or guard
            }
            let activeCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM profile WHERE deleted_at IS NULL") ?? 0
            if activeCount <= 1 {
                throw SettingsStoreError.cannotDeleteLastActive
            }
            try db.execute(sql: "UPDATE profile SET deleted_at=? WHERE id=?",
                           arguments: [Int64(Date().timeIntervalSince1970 * 1000), profileID])
        }
    }

    public func hardPurge(profileID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM transcript      WHERE profile_id=?", arguments: [profileID])
            try db.execute(sql: "DELETE FROM calibration_run WHERE profile_id=?", arguments: [profileID])
            try db.execute(sql: "DELETE FROM profile         WHERE id=?",         arguments: [profileID])
        }
    }

    public func setActiveProfileID(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting(key,value) VALUES('active_profile_id',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, arguments: [id])
        }
    }

    public func activeProfileID() throws -> String? {
        try database.read { db in
            try String.fetchOne(db,
                sql: "SELECT value FROM app_setting WHERE key='active_profile_id'")
        }
    }

    public func addVocab(profileID: String, term: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO vocab_term(profile_id,term) VALUES(?,?)
            """, arguments: [profileID, term])
        }
    }

    public func vocabCount(profileID: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vocab_term WHERE profile_id=?",
                             arguments: [profileID]) ?? 0
        }
    }
}

extension Profile {
    static func fetchAllActive(_ db: GRDB.Database) throws -> [Profile] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM profile WHERE deleted_at IS NULL ORDER BY name COLLATE NOCASE
        """)
        return try rows.map { try Profile(row: $0, db: db) }
    }
    static func fetchOne(_ db: GRDB.Database, id: String, includeDeleted: Bool = false) throws -> Profile? {
        let sql = includeDeleted
            ? "SELECT * FROM profile WHERE id=?"
            : "SELECT * FROM profile WHERE id=? AND deleted_at IS NULL"
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [id]) else { return nil }
        return try Profile(row: row, db: db)
    }
    init(row: Row, db: GRDB.Database) throws {
        let id: String = row["id"]
        let vocab = try String.fetchAll(db,
            sql: "SELECT term FROM vocab_term WHERE profile_id=? ORDER BY term", arguments: [id])
        let rules = try Row.fetchAll(db,
            sql: "SELECT * FROM replacement_rule WHERE profile_id=? ORDER BY sort_order, id",
            arguments: [id]).map { r in
                ReplacementRule(
                    id: r["id"], profileID: id,
                    pattern: r["pattern"], replacement: r["replacement"],
                    isRegex: (r["is_regex"] as Int) == 1,
                    caseSensitive: (r["case_sensitive"] as Int) == 1,
                    wordBoundary: (r["word_boundary"] as Int) == 1,
                    sortOrder: r["sort_order"])
            }
        func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000.0) }
        self.init(
            id: id,
            name: row["name"], language: row["language"], modelID: row["model_id"],
            initialPrompt: row["initial_prompt"], vocab: vocab, rules: rules,
            llmEditEnabled: (row["llm_edit_enabled"] as Int) == 1,
            llmEditPrompt: row["llm_edit_prompt"],
            createdAt: date(row["created_at"]),
            updatedAt: date(row["updated_at"]),
            deletedAt: (row["deleted_at"] as Int64?).map(date)
        )
    }
}
