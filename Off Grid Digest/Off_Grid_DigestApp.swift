//
//  Off_Grid_DigestApp.swift
//  Off Grid Digest
//
//  Created by Josh Daniel on 9/10/25.
//

import SwiftUI

// MARK: - Config model
struct FGConfig {
    var enabled: Bool = true
    var start: Date? = Date() // now
    var end: Date? = Calendar.current.date(byAdding: .day, value: 1, to: Date()) // same time tomorrow
}

@main
struct MsgForwardMenuApp: App {
    @StateObject private var vm = MenuVM()
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(vm)
                .frame(width: 320)
        } label: {
            Text(vm.config.enabled ? "📨" : "⏸️")
        }
        .menuBarExtraStyle(.window) // keeps calendar pickers comfy
    }
}

// MARK: - View
struct MenuView: View {
    @EnvironmentObject var vm: MenuVM
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enabled", isOn: $vm.config.enabled)
                .onChange(of: vm.config.enabled) { _ in vm.saveConfig() }

            GroupBox("Off-grid window (local time)") {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Start", selection: Binding(get: {
                        vm.startBindingDate
                    }, set: { vm.startBindingDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: Binding(get: {
                        vm.endBindingDate
                    }, set: { vm.endBindingDate = $0 }), displayedComponents: [.date, .hourAndMinute])

                    HStack {
                        Button("Clear Start") { vm.clearStart() }.buttonStyle(.borderless)
                        Button("Clear End") { vm.clearEnd() }.buttonStyle(.borderless)
                    }.font(.caption)
                }
                .onChange(of: vm.startBindingDate) { _ in vm.saveConfig() }
                .onChange(of: vm.endBindingDate) { _ in vm.saveConfig() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Kick Now") { vm.kick() }
                Button("Reload LaunchAgent") { vm.reload() }
                Button("Open Log") { vm.openLog() }
                Button("Open Config") { vm.openConfig() }
            }

            Divider()
            Text(vm.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { vm.loadConfig() }
    }
}

// MARK: - ViewModel
final class MenuVM: ObservableObject {
    @Published var config = FGConfig()
    @Published var statusLine: String = ""

    // File locations
    private let cfgURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MsgForward/config.ini")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ForwardMessages.log")
    private let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.jdaniel.forward-messages.plist")

    // Date format used in config.ini
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // Bindings that never crash when nil (defaults to “now” but we also have Clear buttons)
    var startBindingDate: Date {
        get { config.start ?? Date() }
        set { config.start = newValue }
    }
    var endBindingDate: Date {
        get { config.end ?? Date() }
        set { config.end = newValue }
    }

    func clearStart() { config.start = nil; saveConfig() }
    func clearEnd() { config.end = nil; saveConfig() }

    // MARK: Config I/O
    func loadConfig() {
        do {
            try FileManager.default.createDirectory(at: cfgURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch { }

        guard let s = try? String(contentsOf: cfgURL) else {
            // Write defaults on first run
            saveConfig()
            return
        }

        var dict: [String:String] = [:]
        s.split(separator: "\n").forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { dict[parts[0].lowercased()] = parts[1] }
        }

        config.enabled = (dict["enabled"] ?? "true").lowercased() == "true"
        if let st = dict["offgridstart"], !st.isEmpty, let d = df.date(from: st) { config.start = d } else { config.start = nil }
        if let en = dict["offgridend"], !en.isEmpty, let d = df.date(from: en) { config.end = d } else { config.end = nil }

        updateStatus()
    }

    func saveConfig() {
        let startStr = config.start.map { df.string(from: $0) } ?? ""
        let endStr = config.end.map { df.string(from: $0) } ?? ""
        let txt = """
        enabled=\(config.enabled ? "true" : "false")
        offgridStart=\(startStr)
        offgridEnd=\(endStr)
        """
        do {
            try FileManager.default.createDirectory(at: cfgURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try txt.write(to: cfgURL, atomically: true, encoding: .utf8)
            updateStatus("Saved.")
        } catch {
            updateStatus("Failed to save config: \(error.localizedDescription)")
        }
    }

    // MARK: launchctl helpers
    func kick()    { runLaunchctl(["kickstart","-kp","gui/\(uid())/com.jdaniel.forward-messages"]) }
    func reload()  {
        runLaunchctl(["bootout","gui/\(uid())", plistURL.path])
        runLaunchctl(["bootstrap","gui/\(uid())", plistURL.path])
    }

    // MARK: Utilities
    func openLog()    { NSWorkspace.shared.open(logURL) }
    func openConfig() { NSWorkspace.shared.open(cfgURL) }

    private func uid() -> String { String(getuid()) }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            let out = String(data: data, encoding: .utf8) ?? ""
            updateStatus(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "OK" : out)
            return task.terminationStatus
        } catch {
            updateStatus("launchctl error: \(error.localizedDescription)")
            return -1
        }
    }

    private func updateStatus(_ msg: String? = nil) {
        let enabledText = config.enabled ? "Enabled" : "Disabled"
        let s = config.start.map { df.string(from: $0) } ?? "—"
        let e = config.end.map { df.string(from: $0) } ?? "—"
        statusLine = "\(enabledText) • Window: \(s) → \(e)" + (msg.map { " • \($0)" } ?? "")
    }
}

