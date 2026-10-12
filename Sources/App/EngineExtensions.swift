// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a build carries in Resources/extensions (TOSH_APP_EXTENSIONS in make-app.sh): MCP servers and an
/// agent for the engine (engine.json) and the settings they read (settings.json). A plain ToshLLM build
/// has none, so `bundled` is nil and nothing here runs.
struct EngineExtensions: Sendable {
    struct Text: Decodable, Sendable {
        let es: String
        let en: String
        func pick(spanish: Bool) -> String { spanish ? es : en }
    }

    struct Server: Decodable, Sendable {
        /// A local server: the executable and its arguments.
        var command: String?
        var args: [String]?
        /// A remote one, reached through the bundled relay: its URL, "http" or "sse" to skip the
        /// detection, and headers filled from settings (header name to setting key).
        var url: String?
        var transport: String?
        var headerEnv: [String: String]?
        var env: [String: String]?
        var timeoutMs: Int?
        /// The setting that switches the server on; without one it always runs.
        var enabledBy: String?
        /// Its tools are listed only to the agent, never to the chat's own tool loop.
        var agentOnly: Bool?
    }

    struct Engine: Decodable, Sendable {
        var servers: [String: Server]?
        /// Replaces the engine's agent, so every agent turn goes through it.
        var agent: Server?
    }

    struct Option: Decodable, Sendable {
        let value: String
        let title: Text
    }

    struct Field: Decodable, Sendable, Identifiable {
        enum Kind: String, Decodable, Sendable { case toggle, text, secret, choice, json, paths }
        let key: String
        let kind: Kind
        let title: Text
        let help: Text
        var defaultValue: String?
        var placeholder: String?
        var options: [Option]?
        /// For `paths`: file extensions to pick, and folder extensions (such as gdb) picked as a whole.
        var fileTypes: [String]?
        var folderTypes: [String]?
        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, kind, title, help, placeholder, options, fileTypes, folderTypes
            case defaultValue = "default"
        }
    }

    struct Notice: Decodable, Sendable {
        /// Shown while every one of these settings is empty.
        let whenEmpty: [String]
        let text: Text
    }

    struct Section: Decodable, Sendable, Identifiable {
        let id: String
        let title: Text
        var detail: Text?
        var notice: Notice?
        let fields: [Field]
    }

    struct Settings: Decodable, Sendable {
        let sections: [Section]
    }

    let directory: URL
    let engine: Engine?
    let settings: Settings?

    static let bundled = EngineExtensions(directory: Bundle.main.resourceURL?.appendingPathComponent("extensions"))

    init?(directory: URL?) {
        guard let directory else { return nil }
        let engine: Engine? = Self.load("engine.json", in: directory)
        let settings: Settings? = Self.load("settings.json", in: directory)
        guard engine != nil || settings != nil else { return nil }
        self.directory = directory
        self.engine = engine
        self.settings = settings
    }

    private static func load<T: Decodable>(_ name: String, in directory: URL) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLog.app.error("extension \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var hasAgent: Bool { engine?.agent != nil }
    var fields: [Field] { settings?.sections.flatMap(\.fields) ?? [] }

    // MARK: values

    /// What a setting holds, or its declared default. Secrets live in the Keychain, the rest in defaults.
    static func value(_ field: Field) -> String {
        if field.kind == .secret { return Keychain.get(account(field.key)) ?? "" }
        return UserDefaults.standard.string(forKey: SettingsKeys.extensionValue(field.key)) ?? field.defaultValue ?? ""
    }

    static func setValue(_ value: String, for field: Field) {
        if field.kind == .secret {
            if value.isEmpty { Keychain.delete(account(field.key)) } else { Keychain.set(value, account: account(field.key)) }
        } else {
            UserDefaults.standard.set(value, forKey: SettingsKeys.extensionValue(field.key))
        }
    }

    private static func account(_ key: String) -> String { "extension." + key }

    func isOn(_ key: String) -> Bool {
        guard let field = fields.first(where: { $0.key == key }) else { return false }
        return Self.value(field) == "1"
    }

    /// Every setting that holds something, for the engine's environment: the servers it starts inherit
    /// it, so a secret never shows on a command line. A switched-off toggle is left out.
    func environment() -> [String: String] {
        var env: [String: String] = [:]
        for field in fields {
            let value = Self.value(field)
            if field.kind == .toggle {
                if value == "1" { env[field.key] = "1" }
            } else if !value.isEmpty {
                env[field.key] = value
            }
        }
        return env
    }

    // MARK: engine

    /// The servers whose switch is on and the agent, with {python}, {runtime}, {extensions} and
    /// {trust_key} filled in, in the shape --mcp-servers-json takes.
    func engineEntries(runtime: URL, trustKey: String)
        -> (servers: [String: Any], agent: [String: Any]?, agentOnly: [String]) {
        let python = runtime.appendingPathComponent("python/bin/python3").path
        let fill: (String) -> String = {
            $0.replacingOccurrences(of: "{python}", with: python)
                .replacingOccurrences(of: "{runtime}", with: runtime.path)
                .replacingOccurrences(of: "{extensions}", with: directory.path)
                .replacingOccurrences(of: "{trust_key}", with: trustKey)
        }
        func entry(_ server: Server) -> [String: Any]? {
            var entry: [String: Any]
            if let url = server.url {
                let headers = (server.headerEnv ?? [:]).sorted { $0.key < $1.key }
                    .flatMap { ["--header-env", "\($0.key)=\($0.value)"] }
                entry = SymPyToolsService.relayEntry(runtime: runtime, url: fill(url), transport: server.transport,
                                                     timeoutSeconds: (server.timeoutMs ?? 60_000) / 1000,
                                                     headerArguments: headers)
            } else if let command = server.command {
                entry = ["command": fill(command), "args": (server.args ?? []).map(fill)]
                if let timeout = server.timeoutMs { entry["timeout_ms"] = timeout }
            } else {
                return nil
            }
            if let env = server.env { entry["env"] = env.mapValues(fill) }
            return entry
        }
        var servers: [String: Any] = [:]
        var agentOnly: [String] = []
        for (name, server) in engine?.servers ?? [:] where server.enabledBy.map(isOn) ?? true {
            guard let built = entry(server) else { continue }
            servers[name] = built
            if server.agentOnly == true { agentOnly.append(name) }
        }
        return (servers, engine?.agent.flatMap(entry), agentOnly.sorted())
    }
}
