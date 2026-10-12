// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class EngineExtensionsTests: XCTestCase {
    private let engine = """
    {"servers": {"maps": {"command": "{python}", "args": ["-I", "{extensions}/maps.py"],
                          "env": {"KEY": "{trust_key}"}, "timeout_ms": 60000,
                          "enabled_by": "TEST_EXT_MAPS_ON", "agent_only": true},
                 "cloud": {"url": "https://mcp.example/mcp", "transport": "http", "timeout_ms": 30000,
                           "header_env": {"Authorization": "TEST_EXT_MAPS_URL"}}},
     "agent": {"command": "{python}", "args": ["{extensions}/agent.py", "--runtime", "{runtime}"]}}
    """
    private let settings = """
    {"sections": [{"id": "maps", "title": {"es": "Mapas", "en": "Maps"},
      "notice": {"when_empty": ["TEST_EXT_MAPS_URL"], "text": {"es": "Prueba", "en": "Test"}},
      "fields": [
        {"key": "TEST_EXT_MAPS_ON", "kind": "toggle", "default": "1",
         "title": {"es": "Activo", "en": "On"}, "help": {"es": "a", "en": "a"}},
        {"key": "TEST_EXT_MAPS_URL", "kind": "text", "placeholder": "https://",
         "title": {"es": "URL", "en": "URL"}, "help": {"es": "b", "en": "b"}},
        {"key": "TEST_EXT_MAPS_SOURCES", "kind": "paths", "file_types": ["csv"], "folder_types": ["gdb"],
         "title": {"es": "Fuentes", "en": "Sources"}, "help": {"es": "c", "en": "c"}}]}]}
    """

    private func makeExtensions(engine: String? = nil, settings: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tosh-extensions-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let engine { try Data(engine.utf8).write(to: directory.appendingPathComponent("engine.json")) }
        if let settings { try Data(settings.utf8).write(to: directory.appendingPathComponent("settings.json")) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeRuntime() throws -> URL {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("tosh-sympy-test-\(UUID().uuidString)")
        let bin = resources.appendingPathComponent("tosh-sympy/python/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: bin.appendingPathComponent("python3").path)
        addTeardownBlock { try? FileManager.default.removeItem(at: resources) }
        return resources
    }

    override func setUp() {
        super.setUp()
        for key in ["TEST_EXT_MAPS_ON", "TEST_EXT_MAPS_URL", "TEST_EXT_MAPS_SOURCES"] {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.extensionValue(key))
        }
    }

    func testAFolderWithoutEitherFileIsNoExtension() throws {
        XCTAssertNil(EngineExtensions(directory: try makeExtensions()))
        XCTAssertNil(EngineExtensions(directory: nil))
    }

    func testSettingsDecodeWithDefaultsAndNotice() throws {
        let extensions = try XCTUnwrap(EngineExtensions(directory: try makeExtensions(settings: settings)))
        XCTAssertEqual(extensions.fields.map(\.key), ["TEST_EXT_MAPS_ON", "TEST_EXT_MAPS_URL", "TEST_EXT_MAPS_SOURCES"])
        XCTAssertEqual(extensions.fields[0].defaultValue, "1")
        XCTAssertEqual(extensions.fields[2].folderTypes, ["gdb"])
        XCTAssertEqual(extensions.settings?.sections.first?.notice?.whenEmpty, ["TEST_EXT_MAPS_URL"])
        XCTAssertFalse(extensions.hasAgent)
    }

    func testEnvironmentCarriesSetValuesAndLeavesOffTogglesOut() throws {
        let extensions = try XCTUnwrap(EngineExtensions(directory: try makeExtensions(settings: settings)))
        XCTAssertEqual(extensions.environment(), ["TEST_EXT_MAPS_ON": "1"])
        let url = try XCTUnwrap(extensions.fields.first { $0.key == "TEST_EXT_MAPS_URL" })
        EngineExtensions.setValue("https://maps.example", for: url)
        let toggle = extensions.fields[0]
        EngineExtensions.setValue("0", for: toggle)
        XCTAssertEqual(extensions.environment(), ["TEST_EXT_MAPS_URL": "https://maps.example"])
    }

    func testEngineEntriesFillPlaceholdersAndFollowTheirSwitch() throws {
        let directory = try makeExtensions(engine: engine, settings: settings)
        let extensions = try XCTUnwrap(EngineExtensions(directory: directory))
        let runtime = URL(fileURLWithPath: "/rt")
        let on = extensions.engineEntries(runtime: runtime, trustKey: "k")
        let maps = try XCTUnwrap(on.servers["maps"] as? [String: Any])
        XCTAssertEqual(maps["command"] as? String, "/rt/python/bin/python3")
        XCTAssertEqual(maps["args"] as? [String], ["-I", directory.path + "/maps.py"])
        XCTAssertEqual(maps["env"] as? [String: String], ["KEY": "k"])
        XCTAssertEqual(on.agentOnly, ["maps"])
        XCTAssertEqual(on.agent?["args"] as? [String], [directory.path + "/agent.py", "--runtime", "/rt"])

        EngineExtensions.setValue("0", for: extensions.fields[0])
        let off = extensions.engineEntries(runtime: runtime, trustKey: "k")
        XCTAssertNil(off.servers["maps"])
        XCTAssertNotNil(off.agent, "the agent has no switch of its own")
    }

    func testARemoteServerRunsThroughTheRelayWithHeadersFromSettings() throws {
        let extensions = try XCTUnwrap(EngineExtensions(directory: try makeExtensions(engine: engine, settings: settings)))
        let cloud = try XCTUnwrap(extensions.engineEntries(runtime: URL(fileURLWithPath: "/rt"), trustKey: "k")
            .servers["cloud"] as? [String: Any])
        XCTAssertEqual(cloud["command"] as? String, "/rt/python/bin/python3")
        XCTAssertEqual(cloud["args"] as? [String], ["-I", "-B", "/rt/tosh_sympy/remote.py", "--url", "https://mcp.example/mcp",
                                                    "--timeout", "30", "--transport", "http",
                                                    "--header-env", "Authorization=TEST_EXT_MAPS_URL"])
        XCTAssertEqual(cloud["timeout_ms"] as? Int, 30_000)
    }

    func testTheBundledAgentReplacesTheMathAgentAndItsServersStayAgentOnly() throws {
        let extensions = try XCTUnwrap(EngineExtensions(directory: try makeExtensions(engine: engine, settings: settings)))
        let args = SymPyToolsService.serverArguments(enabled: false, resources: try makeRuntime(), extensions: extensions)
        let json = try XCTUnwrap(args.firstIndex(of: "--mcp-servers-json").map { args[$0 + 1] })
        let servers = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])["mcpServers"]
            as? [String: Any]
        XCTAssertEqual(Set((servers ?? [:]).keys), ["maps", "cloud", SymPyToolsService.agentName])
        let agent = try XCTUnwrap(servers?[SymPyToolsService.agentName] as? [String: Any])
        XCTAssertTrue((agent["args"] as? [String])?.first?.hasSuffix("/agent.py") == true)
        XCTAssertEqual(args.firstIndex(of: "--mcp-agent-only").map { args[$0 + 1] }, "maps")
    }

    func testWithoutExtensionsNothingChanges() throws {
        XCTAssertEqual(SymPyToolsService.serverArguments(enabled: false, resources: try makeRuntime(), extensions: nil), [])
    }
}
