import Foundation
import GRDB

extension MeetingStore {
    /// Records the owned paths before deleting anything. Replaying this journal is idempotent.
    public func retireVisualContext() throws {
        struct Retirement: Codable { var meetingID: String; var screenshots: [ScreenshotRecord] }
        // Completed meetings leave no journal or visual rows. Avoid writing one
        // empty retirement transaction per meeting on every app launch.
        let pendingMeetingIDs: [String] = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT meeting_id FROM screenshots
                UNION SELECT meeting_id FROM processing_jobs WHERE kind='vision'
                UNION SELECT substr(id,length('visual-retirement-')+1)
                  FROM cleanup_journal WHERE id LIKE 'visual-retirement-%'
                """)
        }
        for meetingID in pendingMeetingIDs {
            guard let meeting = try meeting(id: meetingID) else { continue }
            let key = "visual-retirement-" + meeting.id
            let retirement: Retirement = try database.write { db in
                if let data = try Data.fetchOne(db, sql: "SELECT payload FROM cleanup_journal WHERE id=?", arguments: [key]) { return try decode(Retirement.self, from: data) }
                let screenshots = try Row.fetchAll(db, sql: "SELECT * FROM screenshots WHERE meeting_id=?", arguments: [meeting.id]).map(decodeScreenshot)
                let value = Retirement(meetingID: meeting.id, screenshots: screenshots)
                try db.execute(sql: "INSERT INTO cleanup_journal(id,payload) VALUES (?,?)", arguments: [key, try encode(value)])
                try db.execute(sql: "UPDATE processing_jobs SET status='cancelled',error='Visual context was removed' WHERE meeting_id=? AND kind='vision' AND status != 'completed'", arguments: [meeting.id])
                return value
            }
            for screenshot in retirement.screenshots {
                let url = try paths.resolveMeetingAsset(meetingID: meeting.id, relativePath: screenshot.relativePath)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            let removed = Set(retirement.screenshots.map(\.id))
            try database.write { db in
                func detached(_ items: [NoteItem]) -> [NoteItem] { items.map { item in var copy = item; copy.evidenceIDs.removeAll { removed.contains($0) }; if !item.evidenceIDs.isEmpty && copy.evidenceIDs.isEmpty { copy.evidenceRemoved = true }; return copy } }
                for row in try Row.fetchAll(db, sql: "SELECT * FROM meeting_notes WHERE meeting_id=?", arguments: [meeting.id]) {
                    let notes = try decodeNotes(row)
                    try db.execute(sql: "UPDATE meeting_notes SET summary_json=?,decisions_json=?,action_items_json=? WHERE meeting_id=? AND id=?", arguments: [try encode(detached(notes.summary)), try encode(detached(notes.decisions)), try encode(detached(notes.actionItems)), meeting.id, notes.id])
                }
                try db.execute(sql: "DELETE FROM screenshots WHERE meeting_id=?", arguments: [meeting.id])
                try db.execute(sql: "DELETE FROM processing_jobs WHERE meeting_id=? AND kind='vision'", arguments: [meeting.id])
                try db.execute(sql: "DELETE FROM cleanup_journal WHERE id=?", arguments: [key])
            }
        }
    }
}
