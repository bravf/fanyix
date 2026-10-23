import Foundation
import Combine
import TranslationCore

@MainActor
final class TranslationHistoryModel: ObservableObject {
    @Published private(set) var history = TranslationHistory()
    @Published private(set) var storageError = ""
    private let file: URL?
    private var blocked = false
    var records: [TranslationRecord] { history.records }

    init(file: URL? = TranslationHistory.file) {
        self.file = file
        if let file {
            do { history = try .load(from: file) }
            catch { blocked = true; storageError = "历史文件读取失败，原文件未改动。本次记录暂存内存。" }
        }
    }
    func begin(id: UUID, source: String, configuration: Configuration) {
        history.begin(TranslationRecord(id: id, source: source, backend: configuration.backend, model: configuration.selectedModel))
        persist()
    }
    func finish(id: UUID, translation: String, notes: [TranslationNote] = [], status: TranslationRecordStatus, detail: String) {
        if history.finish(id, translation: translation, notes: notes, status: status, detail: detail) { persist() }
    }
    func remove(_ id: UUID) { history.remove(id); persist() }
    func clearCompleted() { history.clearCompleted(); persist() }
    func seedPreview(_ records: [TranslationRecord]) { guard file == nil else { return }; history = TranslationHistory(records: records) }
    private func persist() {
        guard let file, !blocked else { return }
        do { try history.save(to: file); storageError = "" }
        catch { storageError = "历史保存失败，本次记录暂存内存；请检查磁盘空间与文件权限。" }
    }
}
