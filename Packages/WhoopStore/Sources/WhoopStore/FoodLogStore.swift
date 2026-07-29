import Foundation
import GRDB

// MARK: - v33: manually logged food entries
//
// NOOP's nutrition model is DAILY TOTALS in the long-format `metricSeries` table, written by
// `NutritionCsvImporter` under source "nutrition-csv" with the keys calories_in / protein_g / carbs_g /
// fat_g. This table is the PER-ENTRY layer under that: a (day, key, value) row has nowhere to put "chicken
// breast and rice for lunch", the time it was eaten, or where its numbers came from.
//
// The two layers are joined by `dayTotals`, which sums a day's entries into exactly those four keys — so
// a logged meal reaches Explore / Compare / Insights through the path an imported CSV already uses,
// rather than through a second parallel nutrition model.
//
// Honesty rules baked into the shape: every macro is OPTIONAL and defaults to nothing. An estimate that
// could not resolve a value stays absent rather than becoming a fabricated 0, and totals sum only what is
// actually present. `source` records how the numbers were produced so an LLM estimate is never shown as
// if it were measured.

/// How an entry's numbers were produced.
public enum FoodEntrySource: String, Sendable, Codable, CaseIterable {
    /// Estimated by the user's configured Coach model from the text they typed.
    case ai
    /// Typed in by hand.
    case manual
}

/// One logged food entry.
public struct FoodLogEntry: Equatable, Codable, Sendable, Identifiable {
    /// The entry's own UUID string. Primary key — two entries can share a `ts`, and re-logging the same
    /// meal text is a legitimate second entry, so neither time nor text is unique enough to key on.
    public let id: String
    /// The LOCAL day the entry belongs to, `yyyy-MM-dd`.
    public let day: String
    /// Unix seconds — when it was logged. Orders the day's list.
    public let ts: Int
    /// What the user typed, verbatim.
    public let text: String
    public let kcal: Double?
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    /// Stored as text so an unrecognised future source round-trips instead of failing to decode.
    public let source: String

    public init(id: String, day: String, ts: Int, text: String,
                kcal: Double? = nil, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil,
                source: FoodEntrySource) {
        self.init(id: id, day: day, ts: ts, text: text,
                  kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                  source: source.rawValue)
    }

    public init(id: String, day: String, ts: Int, text: String,
                kcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?,
                source: String) {
        self.id = id
        self.day = day
        self.ts = ts
        self.text = text
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.source = source
    }

    /// True when the entry carries at least one number. An entry with none is still legitimate — a note
    /// of what was eaten with no estimate — it simply contributes nothing to the day's totals.
    public var hasAnyValue: Bool {
        kcal != nil || proteinG != nil || carbsG != nil || fatG != nil
    }

    /// Whether the numbers came from the Coach model rather than the user's own hand.
    public var isEstimated: Bool { source == FoodEntrySource.ai.rawValue }
}

/// A day's summed macros. Each field is nil when NO entry that day carried that value, so "nothing
/// logged" and "logged, zero" stay distinguishable — a total of 0 g protein is a claim, and one that
/// should only be made when an entry actually said so.
public struct FoodDayTotals: Equatable, Sendable {
    public let day: String
    public let kcal: Double?
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    /// Number of entries logged that day, including any that carried no numbers at all.
    public let entryCount: Int

    public init(day: String, kcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?,
                entryCount: Int) {
        self.day = day
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.entryCount = entryCount
    }

    /// True when no entry that day carried any number.
    public var isEmpty: Bool {
        kcal == nil && proteinG == nil && carbsG == nil && fatG == nil
    }
}

extension WhoopStore {

    /// Stable namespace food entries are stored under. Deliberately NOT the active strap id: what the
    /// user ate is theirs, not the strap's, and a remove+re-add mints a fresh device id (#814) that
    /// would orphan the whole log.
    public static let foodDeviceId = "noop-food"

    /// Source id the DAILY ROLLUP is written to in `metricSeries`. Separate from
    /// `NutritionCsvImporter.sourceId` on purpose: metricSeries upserts are latest-wins on
    /// (deviceId, day, key), so sharing an id would let a CSV import and a manual entry silently
    /// overwrite each other's totals for the same day.
    public static let foodLogSourceId = "food-log"

    // MARK: - Write

    /// Insert or update one entry. Idempotent on `id`, so editing an entry is the same call as creating
    /// it and a retried write can't duplicate a meal.
    public func upsertFoodLogEntry(_ entry: FoodLogEntry,
                                   deviceId: String = WhoopStore.foodDeviceId) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO foodLogEntry (id, deviceId, day, ts, text, kcal, proteinG, carbsG, fatG, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    day = excluded.day,
                    ts = excluded.ts,
                    text = excluded.text,
                    kcal = excluded.kcal,
                    proteinG = excluded.proteinG,
                    carbsG = excluded.carbsG,
                    fatG = excluded.fatG,
                    source = excluded.source
                """, arguments: [entry.id, deviceId, entry.day, entry.ts, entry.text,
                                 entry.kcal, entry.proteinG, entry.carbsG, entry.fatG, entry.source])
        }
    }

    /// Delete one entry by id. Returns true when a row was actually removed.
    @discardableResult
    public func deleteFoodLogEntry(id: String,
                                   deviceId: String = WhoopStore.foodDeviceId) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodLogEntry WHERE deviceId = ? AND id = ?",
                           arguments: [deviceId, id])
            return db.changesCount > 0
        }
    }

    // MARK: - Read

    /// One day's entries, oldest first.
    public func foodLogEntries(deviceId: String = WhoopStore.foodDeviceId,
                               day: String) async throws -> [FoodLogEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, day, ts, text, kcal, proteinG, carbsG, fatG, source FROM foodLogEntry
                WHERE deviceId = ? AND day = ?
                ORDER BY ts ASC, id ASC
                """, arguments: [deviceId, day])
                .map(Self.entry(from:))
        }
    }

    /// Entries across a day range (inclusive, lexicographic `yyyy-MM-dd` compare), oldest first.
    public func foodLogEntries(deviceId: String = WhoopStore.foodDeviceId,
                               from: String, to: String) async throws -> [FoodLogEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, day, ts, text, kcal, proteinG, carbsG, fatG, source FROM foodLogEntry
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC, ts ASC, id ASC
                """, arguments: [deviceId, from, to])
                .map(Self.entry(from:))
        }
    }

    /// One day's summed macros. SUM() over an all-NULL column yields NULL in SQLite, which is exactly
    /// the distinction wanted: a macro no entry recorded stays nil rather than summing to a 0 nobody
    /// claimed. Returns nil when the day has no entries at all.
    public func foodDayTotals(deviceId: String = WhoopStore.foodDeviceId,
                              day: String) async throws -> FoodDayTotals? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n,
                       SUM(kcal) AS kcal, SUM(proteinG) AS proteinG,
                       SUM(carbsG) AS carbsG, SUM(fatG) AS fatG
                FROM foodLogEntry WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day]),
                let count: Int = row["n"], count > 0
            else { return nil }
            return FoodDayTotals(day: day, kcal: row["kcal"], proteinG: row["proteinG"],
                                 carbsG: row["carbsG"], fatG: row["fatG"], entryCount: count)
        }
    }

    /// Per-day summed macros across a day range (inclusive, lexicographic `yyyy-MM-dd` compare), oldest
    /// day first. One GROUP BY instead of a `foodDayTotals(day:)` per day, so a 90-day nutrition trend is
    /// a single read rather than 90 round-trips.
    ///
    /// Days with NO entries are simply absent from the result rather than present as zero rows — the same
    /// rule the single-day rollup follows. A gap in a trend line means "nothing logged", which is not the
    /// same claim as "ate nothing", and the caller must stay able to tell those apart.
    public func foodDayTotals(deviceId: String = WhoopStore.foodDeviceId,
                              from: String, to: String) async throws -> [FoodDayTotals] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, COUNT(*) AS n,
                       SUM(kcal) AS kcal, SUM(proteinG) AS proteinG,
                       SUM(carbsG) AS carbsG, SUM(fatG) AS fatG
                FROM foodLogEntry
                WHERE deviceId = ? AND day >= ? AND day <= ?
                GROUP BY day
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map { row in
                    let day: String = row["day"]
                    let count: Int = row["n"]
                    let kcal: Double? = row["kcal"]
                    let proteinG: Double? = row["proteinG"]
                    let carbsG: Double? = row["carbsG"]
                    let fatG: Double? = row["fatG"]
                    return FoodDayTotals(day: day, kcal: kcal, proteinG: proteinG,
                                         carbsG: carbsG, fatG: fatG, entryCount: count)
                }
        }
    }

    /// Distinct days that have at least one entry, newest first.
    public func foodLogDays(deviceId: String = WhoopStore.foodDeviceId,
                            limit: Int = 400) async throws -> [String] {
        guard limit > 0 else { return [] }
        return try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT day FROM foodLogEntry
                WHERE deviceId = ?
                ORDER BY day DESC
                LIMIT ?
                """, arguments: [deviceId, limit])
        }
    }

    // MARK: - Row mapping

    /// Every column is bound to an explicitly-typed local first. `FoodLogEntry` has two inits with the
    /// same argument labels (one taking `FoodEntrySource`, one taking the raw `String`), so leaving the
    /// types to be inferred from GRDB's generic `Row` subscript would make the call ambiguous.
    private static func entry(from row: Row) -> FoodLogEntry {
        let id: String = row["id"]
        let day: String = row["day"]
        let ts: Int = row["ts"]
        let text: String = row["text"]
        let kcal: Double? = row["kcal"]
        let proteinG: Double? = row["proteinG"]
        let carbsG: Double? = row["carbsG"]
        let fatG: Double? = row["fatG"]
        let source: String = row["source"]
        return FoodLogEntry(id: id, day: day, ts: ts, text: text,
                            kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                            source: source)
    }
}
