// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings a bundled extension declares (Resources/extensions/settings.json), drawn from that file.
/// Values reach the engine's environment at the next server start.
struct IntegrationsSettingsView: View {
    let extensions: EngineExtensions
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var server: ServerController
    @State private var values: [String: String] = [:]
    @State private var pendingRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(extensions.settings?.sections ?? []) { section in
                    sectionView(section)
                }
                restartRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            for field in extensions.fields { values[field.key] = EngineExtensions.value(field) }
        }
    }

    private func text(_ text: EngineExtensions.Text) -> String { text.pick(spanish: loc.isSpanish) }

    private func sectionView(_ section: EngineExtensions.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(section.title)).font(.headline)
            if let detail = section.detail {
                Text(text(detail)).font(.caption).foregroundStyle(.secondary)
            }
            if let notice = section.notice, notice.whenEmpty.allSatisfy({ (values[$0] ?? "").isEmpty }) {
                Label(text(notice.text), systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            SettingsRowGroup {
                ForEach(section.fields) { field in
                    fieldRow(field)
                }
            }
        }
    }

    private func binding(_ field: EngineExtensions.Field) -> Binding<String> {
        Binding(get: { values[field.key] ?? "" }, set: { store($0, field) })
    }

    private func store(_ value: String, _ field: EngineExtensions.Field) {
        guard values[field.key] != value else { return }
        values[field.key] = value
        EngineExtensions.setValue(value, for: field)
        pendingRestart = true
    }

    @ViewBuilder
    private func fieldRow(_ field: EngineExtensions.Field) -> some View {
        let title = text(field.title)
        let help = text(field.help)
        switch field.kind {
        case .toggle:
            SettingsRow(icon: "power", title: title, help: help) {
                SettingsToggle(isOn: Binding(get: { values[field.key] == "1" },
                                             set: { store($0 ? "1" : "0", field) }))
            }
        case .text:
            SettingsRow(icon: "textformat", title: title, help: help) {
                DeferredSettingsTextField("", text: binding(field), prompt: field.placeholder, width: 300)
            }
        case .secret:
            SettingsRow(icon: "key", title: title, help: help) {
                SecretSettingsField(stored: !(values[field.key] ?? "").isEmpty) { store($0, field) }
            }
        case .choice:
            SettingsRow(icon: "list.bullet", title: title, help: help) {
                Picker("", selection: binding(field)) {
                    ForEach(field.options ?? [], id: \.value) { option in
                        Text(text(option.title)).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
        case .json:
            VStack(alignment: .leading, spacing: 6) {
                SettingsRow(icon: "curlybraces", title: title, help: help) { EmptyView() }
                JSONSettingsEditor(text: binding(field), placeholder: field.placeholder ?? "")
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        case .paths:
            VStack(alignment: .leading, spacing: 6) {
                SettingsRow(icon: "folder", title: title, help: help) {
                    Button(loc.t("Añadir…", "Add…")) { addPath(field) }
                        .glassButton()
                        .help(loc.t("Elige un archivo o una carpeta de datos para leer en local.",
                                    "Pick a data file or folder to read locally."))
                }
                ForEach(paths(field)) { entry in
                    HStack(spacing: 8) {
                        Text(entry.name).font(.system(.callout, design: .monospaced))
                        Text(entry.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            setPaths(paths(field).filter { $0.name != entry.name }, field)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help(loc.t("Quitar esta fuente", "Remove this source"))
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: paths

    private struct PathEntry: Identifiable {
        let name: String
        let path: String
        var id: String { name }
    }

    private func paths(_ field: EngineExtensions.Field) -> [PathEntry] {
        guard let data = (values[field.key] ?? "").data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [] }
        return object.map { PathEntry(name: $0.key, path: $0.value) }.sorted { $0.name < $1.name }
    }

    private func setPaths(_ entries: [PathEntry], _ field: EngineExtensions.Field) {
        guard !entries.isEmpty else { store("", field); return }
        let object = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.path) })
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        store(String(decoding: data, as: UTF8.self), field)
    }

    private func addPath(_ field: EngineExtensions.Field) {
        let panel = NSOpenPanel()
        let folders = Set((field.folderTypes ?? []).map { $0.lowercased() })
        panel.canChooseFiles = true
        panel.canChooseDirectories = !folders.isEmpty
        panel.allowsMultipleSelection = false
        let types = (field.fileTypes ?? []).compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty && folders.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let ext = url.pathExtension.lowercased()
        let allowed = isFolder.boolValue ? folders.contains(ext)
            : (field.fileTypes ?? []).map { $0.lowercased() }.contains(ext)
        guard allowed else {
            let alert = NSAlert()
            alert.messageText = loc.t("Ese tipo de dato no se puede leer aquí", "That kind of data cannot be read here")
            alert.informativeText = ((field.fileTypes ?? []) + (field.folderTypes ?? [])).map { "." + $0 }.joined(separator: ", ")
            alert.runModal()
            return
        }
        var current = paths(field)
        current.append(PathEntry(name: uniqueName(url.deletingPathExtension().lastPathComponent, taken: current.map(\.name)),
                                 path: url.path))
        setPaths(current, field)
    }

    /// Names are how the model refers to a source, so they stay short, lowercase and unique.
    private func uniqueName(_ stem: String, taken: [String]) -> String {
        let base = String(stem.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let root = base.isEmpty ? "source" : base
        var name = root
        var n = 2
        while taken.contains(name) { name = "\(root)_\(n)"; n += 1 }
        return name
    }

    // MARK: restart

    private var serverRunning: Bool {
        if case .stopped = server.state { return false }
        if case .failed = server.state { return false }
        return true
    }

    private var restartRow: some View {
        HStack(spacing: 10) {
            Label(loc.t("Los cambios se aplican al reiniciar el servidor.",
                        "Changes apply when the server restarts."),
                  systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if pendingRestart && serverRunning {
                Button(loc.t("Reiniciar servidor", "Restart server")) {
                    server.restart(.fromDefaults())
                    pendingRestart = false
                }
                .glassButton(prominent: true)
                .help(loc.t("Reinicia el servidor con estos ajustes.", "Restarts the server with these settings."))
            }
        }
    }
}

/// A secret is written once and never shown again; the field only says whether one is stored.
private struct SecretSettingsField: View {
    let stored: Bool
    let save: (String) -> Void
    @EnvironmentObject private var loc: Localizer
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            SecureField(stored ? loc.t("Guardado en el Llavero", "Stored in the Keychain") : "",
                        text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(commit)
                .help(loc.t("Se guarda en el Llavero de macOS y solo llega al motor al arrancarlo.",
                            "Stored in the macOS Keychain and handed to the engine only when it starts."))
            Button(loc.t("Guardar", "Save"), action: commit)
                .glassButton()
                .disabled(draft.isEmpty)
                .help(loc.t("Guarda el valor en el Llavero.", "Saves the value in the Keychain."))
            if stored {
                Button(loc.t("Borrar", "Clear")) { save("") }
                    .glassButton()
                    .help(loc.t("Borra el valor guardado.", "Removes the stored value."))
            }
        }
    }

    private func commit() {
        guard !draft.isEmpty else { return }
        save(draft)
        draft = ""
    }
}

/// Multi-line JSON that is stored only once it parses as an object, or when cleared.
private struct JSONSettingsEditor: View {
    @Binding var text: String
    let placeholder: String
    @EnvironmentObject private var loc: Localizer
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: draft) { _, value in commit(value) }
            if invalid {
                Text(loc.t("No es un objeto JSON válido; se guarda en cuanto lo sea.",
                           "Not a valid JSON object; it is saved as soon as it is one."))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { draft = text }
    }

    private func commit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            invalid = false
            text = ""
            return
        }
        let parsed = trimmed.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        invalid = !(parsed is [String: Any])
        if !invalid { text = trimmed }
    }
}
