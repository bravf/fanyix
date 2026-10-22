import Foundation

public enum AgentWorkspace {
    public static var directory: URL { Configuration.directory.appendingPathComponent("agent-workspace", isDirectory: true) }
    public static var instructionsFile: URL { directory.appendingPathComponent("AGENTS.md") }

    /// 首次安装；仅自动升级逐字匹配的旧版默认规则，保留自定义修改。
    @discardableResult
    public static func prepare(directory: URL = directory) throws -> Data {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("AGENTS.md")
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Shurufa_TranslationCore.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let template = resources.url(forResource: "AGENTS", withExtension: "md") else {
            throw TranslationError.message("缺少默认翻译规则文件，请重新构建应用。")
        }
        if !manager.fileExists(atPath: file.path) {
            try manager.copyItem(at: template, to: file)
        } else if let legacy = resources.url(forResource: "AGENTS-v1", withExtension: "md"),
                  try Data(contentsOf: file) == Data(contentsOf: legacy) {
            let backup = directory.appendingPathComponent("AGENTS.md.v1.bak")
            if !manager.fileExists(atPath: backup.path) { try manager.copyItem(at: file, to: backup) }
            try Data(contentsOf: template).write(to: file, options: .atomic)
        }
        let bridge = directory.appendingPathComponent("CLAUDE.md")
        if !manager.fileExists(atPath: bridge.path) {
            try Data("@AGENTS.md\n".utf8).write(to: bridge, options: .atomic)
        }
        let rules = try Data(contentsOf: file)
        guard let text = String(data: rules, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.message("AGENTS.md 翻译规则为空或不是 UTF-8 文件，请编辑后重试。")
        }
        let encoder = JSONEncoder()
        return try encoder.encode([rules, Data(contentsOf: bridge)])
    }
}
