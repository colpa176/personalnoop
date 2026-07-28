import Foundation
import GRDB

// MARK: - v32: durable AI Coach transcript
//
// The coach's conversation used to live only in `AICoachEngine.messages` — an in-memory array — so it
// vanished on every relaunch. This is its on-disk home: one row per TURN in the SAME on-device SQLite
// database as everything else. Nothing here talks to a network; the transcript is stored exactly where
// the strap streams, scores and journal already live, and leaves the device only if the user themselves
// sends a follow-up question to their chosen provider.
//
// Shape follows the established store pattern: a Codable value type, an idempotent write keyed by the
// natural key, range/limit reads, and every GRDB call routed through the actor's syncWrite/syncRead.

/// One stored turn of the coaching conversation.
public struct CoachTurn: Equatable, Codable, Sendable, Identifiable {
    /// The turn's own UUID string. Primary key: two turns can share a `ts` (a local model can reply
    /// inside the same second), so time is not unique enough to key on.
    public let id: String
    /// The LOCAL day the turn was spoken on, `yyyy-MM-dd` — the "session" a transcript groups into.
    public let sessionId: String
    /// Unix seconds. Orders turns within and across sessions.
    public let ts: Int
    /// `"user"` or `"assistant"`. Stored as text so an unknown future role round-trips instead of
    /// failing to decode.
    public let role: String
    public let text: String

    public init(id: String, sessionId: String, ts: Int, role: String, text: String) {
        self.id = id
        self.sessionId = sessionId
        self.ts = ts
        self.role = role
        self.text = text
    }
}

extension WhoopStore {

    /// Stable namespace the coach transcript is stored under. Deliberately NOT the active strap id:
    /// the conversation is user-authored text, and a strap remove+re-add mints a fresh device id
    /// (#814) that would orphan every past conversation.
    public static let coachDeviceId = "noop-coach"

    /// Rolling per-device cap on stored turns, applied on append (oldest dropped first). Bounds the
    /// table the same way `AICoachEngine.maxStoredMessages` bounds the in-memory transcript, but much
    /// higher — history you can scroll back through is the point of storing it at all.
    public static let coachTurnRetentionRows = 500

    // MARK: - Write

    /// Append one turn and enforce the retention cap. Idempotent on `id`: re-appending the same turn
    /// updates it in place rather than duplicating it, so a retry after a failed write is safe.
    public func appendCoachTurn(_ turn: CoachTurn, deviceId: String = WhoopStore.coachDeviceId) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO coachTurn (id, deviceId, sessionId, ts, role, text)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sessionId = excluded.sessionId,
                    ts = excluded.ts,
                    role = excluded.role,
                    text = excluded.text
                """, arguments: [turn.id, deviceId, turn.sessionId, turn.ts, turn.role, turn.text])

            // Rolling cap: drop the oldest rows beyond the limit for THIS device only. Ordered by
            // (ts, id) so an exact tie in `ts` still has one deterministic drop order rather than
            // whichever row SQLite happens to visit first.
            try db.execute(sql: """
                DELETE FROM coachTurn
                WHERE deviceId = ? AND id NOT IN (
                    SELECT id FROM coachTurn
                    WHERE deviceId = ?
                    ORDER BY ts DESC, id DESC
                    LIMIT ?
                )
                """, arguments: [deviceId, deviceId, WhoopStore.coachTurnRetentionRows])
        }
    }

    // MARK: - Read

    /// The most recent `limit` turns, returned OLDEST FIRST so the caller can hand them straight to a
    /// transcript view without reversing. Returns [] when nothing has been stored yet.
    public func coachTurns(deviceId: String = WhoopStore.coachDeviceId,
                           limit: Int = 200) async throws -> [CoachTurn] {
        guard limit > 0 else { return [] }
        return try syncRead { db in
            // Newest-first with a LIMIT is what the (deviceId, ts) index can serve; flip to
            // chronological order in memory afterwards.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, sessionId, ts, role, text FROM coachTurn
                WHERE deviceId = ?
                ORDER BY ts DESC, id DESC
                LIMIT ?
                """, arguments: [deviceId, limit])
            return rows.reversed().map {
                CoachTurn(id: $0["id"], sessionId: $0["sessionId"], ts: $0["ts"],
                          role: $0["role"], text: $0["text"])
            }
        }
    }

    /// One session's turns (a local day), oldest first.
    public func coachTurns(deviceId: String = WhoopStore.coachDeviceId,
                           sessionId: String) async throws -> [CoachTurn] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, sessionId, ts, role, text FROM coachTurn
                WHERE deviceId = ? AND sessionId = ?
                ORDER BY ts ASC, id ASC
                """, arguments: [deviceId, sessionId])
                .map {
                    CoachTurn(id: $0["id"], sessionId: $0["sessionId"], ts: $0["ts"],
                              role: $0["role"], text: $0["text"])
                }
        }
    }

    /// Number of stored turns for a device.
    public func coachTurnCount(deviceId: String = WhoopStore.coachDeviceId) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coachTurn WHERE deviceId = ?",
                             arguments: [deviceId]) ?? 0
        }
    }

    // MARK: - Delete

    /// Erase the whole transcript for a device. Returns the number of turns removed. Backs the
    /// "Clear conversation history" control in Settings — a user-initiated wipe, so it is a real
    /// DELETE, not a soft flag.
    @discardableResult
    public func clearCoachTurns(deviceId: String = WhoopStore.coachDeviceId) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachTurn WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount
        }
    }
}
