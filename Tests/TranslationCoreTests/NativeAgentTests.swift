import XCTest
@testable import TranslationCore

final class NativeAgentTests: XCTestCase {
    private func fixture() throws -> URL {
        var directory = Bundle(for: NativeAgentTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("AgentFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw TranslationError.message("测试 AgentFixture 未构建。")
    }
    private func configuration(_ backend: Backend, timeout: Double = 3) -> Configuration {
        var config = Configuration(); config.backend = backend; config.timeout = timeout; return config
    }

    @MainActor
    func testAllProtocolsReuseProcessAndHandleEarlyUnicodeEvents() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            let first = try await agent.translate("第一句", configuration: configuration(backend))
            let pid = try XCTUnwrap(agent.processIdentifier)
            let second = try await agent.translate("第二句", configuration: configuration(backend))
            XCTAssertEqual(first, "I might be a little late today. 🌏")
            XCTAssertEqual(second, first)
            XCTAssertEqual(pid, agent.processIdentifier)
            XCTAssertEqual(agent.pendingCount, 0)
        }
    }

    @MainActor
    func testAllProtocolsReuseSessionAndResetAfterClose() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            let config = configuration(backend)
            let first = try await agent.translate("__SESSION__", configuration: config)
            let second = try await agent.translate("__SESSION__", configuration: config)
            XCTAssertEqual(first, "1|1")
            XCTAssertEqual(second, "1|2")
            agent.close()
            let restarted = try await agent.translate("__SESSION__", configuration: config)
            XCTAssertEqual(restarted, "1|1")
        }
    }

    @MainActor
    func testModelChangeStartsFreshSession() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            var config = configuration(backend)
            _ = try await agent.translate("__SESSION__", configuration: config)
            config.models[backend.rawValue] = backend == .pi ? "fixture/other" : "other"
            let output = try await agent.translate("__SESSION__", configuration: config)
            XCTAssertEqual(output, "1|1")
        }
    }

    func testAgentLaunchUsesWorkspaceRulesInsteadOfPromptFlags() throws {
        for backend in Backend.allCases {
            let launch = try AgentLaunch.resolve(backend, override: try fixture().path)
            XCTAssertFalse(launch.arguments.contains("--system-prompt"))
            XCTAssertFalse(launch.arguments.contains("--no-context-files"))
        }
    }

    func testClaudeLaunchLoadsEditableRulesAsSystemPromptFromActualWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FanyiX 中文规则 \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try AgentWorkspace.prepare(directory: directory)
        for backend in Backend.allCases {
            let launch = try AgentLaunch.resolve(backend, override: try fixture().path, workspaceDirectory: directory)
            if backend == .claude {
                let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--system-prompt-file"))
                XCTAssertEqual(launch.arguments[index + 1], directory.appendingPathComponent("AGENTS.md").path)
                XCTAssertFalse(launch.arguments.contains("--system-prompt"))
                let tools = try XCTUnwrap(launch.arguments.firstIndex(of: "--tools"))
                XCTAssertEqual(launch.arguments[tools + 1], "")
            } else {
                XCTAssertFalse(launch.arguments.contains("--system-prompt-file"))
            }
        }
    }

    @MainActor
    func testEditedInstructionsStartFreshSessionAndRemainOnDisk() async throws {
        for backend in Backend.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]), workspaceDirectory: directory)
            defer { agent.close() }
            let config = configuration(backend)
            _ = try await agent.translate("__SESSION__", configuration: config)
            let rules = directory.appendingPathComponent("AGENTS.md")
            let edited = try String(contentsOf: rules, encoding: .utf8) + "\nUser-edited rule.\n"
            try edited.write(to: rules, atomically: true, encoding: .utf8)
            let output = try await agent.translate("__SESSION__", configuration: config)
            XCTAssertEqual(output, "1|1")
            XCTAssertEqual(try String(contentsOf: rules, encoding: .utf8), edited)
        }
    }

    @MainActor
    func testEmptyAndMalformedOutputAndExitReconnect() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            for text in ["__EMPTY__", "__BAD_JSON__", "__EXIT__"] {
                do { _ = try await agent.translate(text, configuration: configuration(backend)); XCTFail("应拒绝无效输出") }
                catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
                XCTAssertEqual(agent.pendingCount, 0)
                let output = try await agent.translate("重试", configuration: configuration(backend))
                XCTAssertTrue(output.contains("late"))
            }
        }
    }

    @MainActor
    func testCancellationClosesPendingContinuationsAndReconnects() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            let config = configuration(backend)
            let pending = Task { try await agent.translate("__HANG__", configuration: config) }
            try await Task.sleep(nanoseconds: 100_000_000)
            pending.cancel()
            do { _ = try await pending.value; XCTFail("应取消") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(agent.pendingCount, 0)
            let result = try await agent.translate("再次翻译", configuration: config)
            XCTAssertTrue(result.contains("late"))
        }
    }

    @MainActor
    func testRepeatedCancellationThenFreshRequestDoesNotReceiveOldCleanup() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            let config = configuration(backend)
            for iteration in 0..<5 {
                let pending = Task { try await agent.translate("__HANG__", configuration: config) }
                try await Task.sleep(nanoseconds: 25_000_000)
                pending.cancel()
                do { _ = try await pending.value; XCTFail("应取消") } catch { XCTAssertTrue(error is CancellationError, "\(backend) 第 \(iteration) 次取消：\(error)") }
                do {
                    let result = try await agent.translate("新选区", configuration: config)
                    XCTAssertTrue(result.contains("late"), "\(backend) 第 \(iteration) 次结果：\(result)")
                } catch { XCTFail("\(backend) 第 \(iteration) 次新请求失败：\(error)"); return }
                XCTAssertEqual(agent.pendingCount, 0)
            }
        }
    }

    @MainActor
    func testTimeoutAndConcurrentRequest() async throws {
        let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: ["codex"]))
        defer { agent.close() }
        let config = configuration(.codex, timeout: 0.3)
        let pending = Task { try await agent.translate("__HANG__", configuration: config) }
        try await Task.sleep(nanoseconds: 50_000_000)
        do { _ = try await agent.translate("并发", configuration: config); XCTFail("应拒绝并发") }
        catch { XCTAssertTrue(error.localizedDescription.contains("等待")) }
        do { _ = try await pending.value; XCTFail("应超时") } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertEqual(agent.pendingCount, 0)
    }

    func testOldSettingsMigrationAndExplicitMissingExecutable() throws {
        let data = Data("{\"backend\":\"claude\",\"timeout\":75,\"shortcut\":1}".utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.backend, .claude)
        XCTAssertTrue(config.executablePaths.isEmpty)
        XCTAssertTrue(config.models.isEmpty)
        XCTAssertThrowsError(try AgentLaunch.resolve(.codex, override: "/no-such-executable"))
    }

    @MainActor
    func testModelCatalogsUseRealProtocolAndCodexPagination() async throws {
        for backend in Backend.allCases {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            let models = try await agent.listModels(configuration: configuration(backend))
            XCTAssertEqual(models.first?.id, backend == .pi ? "fixture/fixture-small" : "fixture-small")
            XCTAssertEqual(models.count, backend == .codex ? 2 : 1)
            XCTAssertEqual(agent.pendingCount, 0)
        }
    }

    @MainActor
    func testSelectedCodexAndPiModelsArePassedToAgent() async throws {
        for backend in [Backend.codex, .pi] {
            let agent = NativeAgent(launchOverride: AgentLaunch(executable: try fixture(), arguments: [backend.rawValue]))
            defer { agent.close() }
            var config = configuration(backend)
            config.models[backend.rawValue] = backend == .pi ? "fixture/model/with-slash" : "fixture-large"
            let text = try await agent.translate("__MODEL__", configuration: config)
            XCTAssertEqual(text, config.selectedModel)
        }
    }

    func testSelectionsPersistPerBackendAndDeduplicateModels() throws {
        var config = Configuration(); config.models = ["codex": "a", "claude": "b"]
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.models, config.models)
        config.backend = .claude; XCTAssertEqual(config.selectedModel, "b")
        let models = AgentModel.decode([["value": "x"], ["value": "x"], [:]], backend: .claude)
        XCTAssertEqual(models.count, 1)
    }
}
