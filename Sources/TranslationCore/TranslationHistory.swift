import Foundation

public enum TranslationRecordStatus: String, Codable {
    case translating, replaced, pasted, retained, failed, cancelled
    public var title: String {
        switch self {
        case .translating: return "翻译中"
        case .replaced: return "已替换"
        case .pasted: return "已粘贴"
        case .retained: return "已保留"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct TranslationRecord: Identifiable, Codable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let source: String
    public let backend: Backend
    public let model: String
    public var translation: String
    public var status: TranslationRecordStatus
    public var detail: String
    public var completedAt: Date?

    public init(id: UUID = UUID(), createdAt: Date = Date(), source: String, backend: Backend, model: String,
                translation: String = "", status: TranslationRecordStatus = .translating, detail: String = "", completedAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt; self.source = source; self.backend = backend; self.model = model
        self.translation = translation; self.status = status; self.detail = detail; self.completedAt = completedAt
    }
}

/// 文件按请求 ID 更新；旧任务的清理只结束自己的记录。不会记录剪贴板或桌面其它内容。
public struct TranslationHistory {
    public static let maximumRecords = 100
    public private(set) var records: [TranslationRecord]
    public init(records: [TranslationRecord] = []) {
        self.records = Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maximumRecords))
    }

    public mutating func begin(_ record: TranslationRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords { records.removeLast(records.count - Self.maximumRecords) }
    }
    @discardableResult public mutating func finish(_ id: UUID, translation: String, status: TranslationRecordStatus, detail: String, at date: Date = Date()) -> Bool {
        guard status != .translating, let index = records.firstIndex(where: { $0.id == id }), records[index].status == .translating else { return false }
        records[index].translation = translation; records[index].status = status
        records[index].detail = detail; records[index].completedAt = date
        return true
    }
    public mutating func remove(_ id: UUID) { records.removeAll { $0.id == id && $0.status != .translating } }
    public mutating func clearCompleted() { records.removeAll { $0.status != .translating } }

    public static var file: URL { Configuration.directory.appendingPathComponent("translation-history.json") }
    public static func load(from file: URL = Self.file) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let stored = try JSONDecoder().decode([TranslationRecord].self, from: Data(contentsOf: file))
        var history = Self(records: stored)
        // 进程退出后不继续旧任务，避免永久显示「翻译中」。
        for index in history.records.indices where history.records[index].status == .translating {
            history.records[index].status = .cancelled
            history.records[index].detail = "应用已退出，本次翻译未完成。"
            history.records[index].completedAt = Date()
        }
        // 升级时一并清理已有文件，磁盘与列表均只保留最近 100 条。
        if stored.count > Self.maximumRecords { try history.save(to: file) }
        return history
    }
    public func save(to file: URL = Self.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
