import XCTest
@testable import TranslationCore

final class TranslationHistoryTests: XCTestCase {
    private func records(_ count: Int) -> [TranslationRecord] {
        (0..<count).map { index in
            TranslationRecord(createdAt: Date(timeIntervalSince1970: Double(index)), source: String(index),
                backend: .codex, model: "", translation: "Result", status: .retained)
        }
    }
    func testInitializationKeepsNewestHundredInTimeOrder() {
        let stored = records(150)
        let history = TranslationHistory(records: stored.reversed())
        XCTAssertEqual(history.records.count, 100)
        XCTAssertEqual(history.records.map(\.id), Array(stored.suffix(100).reversed()).map(\.id))
        XCTAssertEqual(TranslationHistory(records: records(100)).records.count, 100)
        XCTAssertEqual(TranslationHistory(records: records(99)).records.count, 99)
    }
    func testNewRequestEvictsOldestWithoutLosingCurrentOrDuplicateRecords() {
        let stored = records(100)
        var history = TranslationHistory(records: stored)
        history.begin(stored[99])
        XCTAssertEqual(history.records.count, 100)
        XCTAssertEqual(history.records.last?.id, stored[0].id)
        let active = TranslationRecord(createdAt: Date(timeIntervalSince1970: 101), source: "当前翻译", backend: .claude, model: "")
        history.begin(active)
        XCTAssertEqual(history.records.count, 100)
        XCTAssertEqual(history.records.first?.id, active.id)
        XCTAssertEqual(history.records.last?.id, stored[1].id)
        XCTAssertFalse(history.finish(stored[0].id, translation: "迟到结果", status: .retained, detail: ""))
        XCTAssertTrue(history.finish(active.id, translation: "Current translation", status: .retained, detail: ""))
        XCTAssertEqual(history.records.count, 100)
        XCTAssertEqual(history.records.first?.translation, "Current translation")
    }
    func testLoadingOversizedLegacyHistoryTrimsTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        let stored = records(125)
        try JSONEncoder().encode(stored).write(to: file)
        let loaded = try TranslationHistory.load(from: file)
        XCTAssertEqual(loaded.records.map(\.id), Array(stored.suffix(100).reversed()).map(\.id))
        let persisted = try JSONDecoder().decode([TranslationRecord].self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted, loaded.records)
        XCTAssertEqual(try TranslationHistory.load(from: file).records, loaded.records)
    }
    func testRoundTripPreservesTextModelsAndDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let notes = [TranslationNote(term: "might be", kind: "情态动词", explain: "表示不确定的推测。")]
        let record = TranslationRecord(createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: "你好 🌏\n明天见", backend: .pi, model: "provider/model", translation: "Hello 🌏\nSee you tomorrow.", notes: notes, status: .retained, detail: "选区已变化", completedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try TranslationHistory(records: [record]).save(to: file)
        XCTAssertEqual(try TranslationHistory.load(from: file).records, [record])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testLegacyRecordWithoutNotesStillDecodes() throws {
        let json = #"{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","createdAt":0,"source":"旧记录","backend":"codex","model":"","translation":"Old","status":"retained","detail":""}"#
        let decoder = JSONDecoder()
        let record = try decoder.decode(TranslationRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.translation, "Old")
        XCTAssertTrue(record.notes.isEmpty)
    }
    func testNewestFirstAndRequestCompletionIsIsolated() {
        let old = TranslationRecord(createdAt: Date(timeIntervalSince1970: 1), source: "旧", backend: .claude, model: "")
        let current = TranslationRecord(createdAt: Date(timeIntervalSince1970: 2), source: "新", backend: .codex, model: "chosen")
        var history = TranslationHistory(records: [old])
        history.begin(current); history.begin(current)
        XCTAssertEqual(history.records.map(\.id), [current.id, old.id])
        XCTAssertTrue(history.finish(old.id, translation: "Old", status: .cancelled, detail: "已取消"))
        XCTAssertEqual(history.records.first?.status, .translating)
        XCTAssertTrue(history.finish(current.id, translation: "New", status: .replaced, detail: "已替换"))
        XCTAssertFalse(history.finish(current.id, translation: "stale", status: .failed, detail: ""))
        XCTAssertEqual(history.records.first?.translation, "New")
        XCTAssertFalse(history.finish(UUID(), translation: "", status: .failed, detail: ""))
    }
    func testRemoveAndClearKeepActiveRequest() {
        let active = TranslationRecord(source: "处理中", backend: .codex, model: "")
        let done = TranslationRecord(source: "完成", backend: .codex, model: "", status: .replaced)
        var history = TranslationHistory(records: [done, active])
        history.remove(active.id)
        XCTAssertEqual(history.records.count, 2)
        history.remove(done.id)
        XCTAssertEqual(history.records.map(\.id), [active.id])
        history.begin(done); history.clearCompleted()
        XCTAssertEqual(history.records.map(\.id), [active.id])
    }
    func testRestartCancelsUnfinishedRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let active = TranslationRecord(source: "处理中", backend: .claude, model: "")
        try TranslationHistory(records: [active]).save(to: file)
        let record = try XCTUnwrap(TranslationHistory.load(from: file).records.first)
        XCTAssertEqual(record.id, active.id)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertNotNil(record.completedAt)
        XCTAssertFalse(record.detail.isEmpty)
    }
    func testMissingFileIsEmptyAndCorruptFileIsNotOverwrittenByLoad() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try TranslationHistory.load(from: file).records.isEmpty)
        let broken = Data("invalid history".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try TranslationHistory.load(from: file))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testAllFinalStatusesPersistAndTranslatingCannotFinishItself() throws {
        var history = TranslationHistory()
        for status in [TranslationRecordStatus.replaced, .pasted, .retained, .failed, .cancelled] {
            let record = TranslationRecord(source: status.rawValue, backend: .codex, model: "")
            history.begin(record)
            XCTAssertFalse(history.finish(record.id, translation: "", status: .translating, detail: ""))
            XCTAssertTrue(history.finish(record.id, translation: "Result", status: status, detail: "detail"))
        }
        let encoded = try JSONEncoder().encode(history.records)
        XCTAssertEqual(try JSONDecoder().decode([TranslationRecord].self, from: encoded), history.records)
    }
}
