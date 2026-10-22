import Foundation

public struct AgentLaunch {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: URL, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }

    public static func resolve(_ backend: Backend, override: String = "", workspaceDirectory: URL = AgentWorkspace.directory) throws -> AgentLaunch {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".cargo/bin").path, "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".volta/bin").path]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? manager.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        directories += versions.map { $0.appendingPathComponent("bin").path }
        directories += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        directories = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
        let name = backend.rawValue
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = custom.isEmpty ? environment[name.uppercased() + "_BIN"] : custom
        var candidates = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        if let explicit, !explicit.isEmpty { candidates = [URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)] }
        guard var executable = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw TranslationError.message("找不到 " + backend.title + "。请在设置中指定已安装的可执行文件路径。")
        }
        // npm 的 Codex 入口是 Node 包装器，优先直接使用其附带的 Rust 原生二进制。
        if backend == .codex {
            #if arch(arm64)
            let platform = "aarch64-apple-darwin"; let package = "codex-darwin-arm64"
            #else
            let platform = "x86_64-apple-darwin"; let package = "codex-darwin-x64"
            #endif
            let root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            let native = [root.appendingPathComponent("node_modules/@openai/" + package + "/vendor/" + platform + "/bin/codex"), root.appendingPathComponent("vendor/" + platform + "/bin/codex")]
            if let found = native.first(where: { manager.isExecutableFile(atPath: $0.path) }) { executable = found }
        }
        directories.insert(executable.deletingLastPathComponent().path, at: 0)
        environment["PATH"] = directories.joined(separator: ":")
        let arguments: [String]
        switch backend {
        case .codex:
            arguments = ["--disable", "shell_tool", "--disable", "unified_exec", "--disable", "multi_agent", "app-server", "--stdio"]
        case .claude:
            // CLAUDE.md 导入只是项目上下文，容易被编码助手角色和旧译文带偏。
            // 直接以同一份可编辑文件定义翻译角色；每轮仍只发送原文，不拼接规则。
            arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--system-prompt-file", workspaceDirectory.appendingPathComponent("AGENTS.md").path, "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--permission-mode", "dontAsk", "--settings", "{\"disableAllHooks\":true}"]
        case .pi:
            arguments = ["--mode", "rpc", "--no-session", "--no-tools", "--no-mcp", "--no-extensions", "--no-skills", "--no-prompt-templates"]
        }
        return AgentLaunch(executable: executable, arguments: arguments, environment: environment)
    }
}
