import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Card container

@MainActor
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

// MARK: - Banners

@MainActor
struct PermissionBanner: View {
    @ObservedObject var store: ShareableContentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission required", systemImage: "lock.shield")
                .font(.headline)
            Text(store.loadError ?? "macOS must allow this app to record the screen and its audio. After granting permission, quit and reopen the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Request Permission") { store.requestPermission() }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings") { store.openPrivacySettings() }
                Button("Re-check") { Task { await store.refresh() } }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45))
        )
    }
}

@MainActor
struct MessageBanner: View {
    enum Kind { case error, info }


    let text: String
    let kind: Kind
    let onDismiss: @MainActor () -> Void

    private var tint: Color { kind == .error ? .red : .accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1))
        )
    }
}

// MARK: - Source selection

@MainActor
struct SourceSelection: View {
    @ObservedObject var content: ShareableContentStore
    @Binding var sourceKind: SourceKind
    @Binding var selectedDisplayID: CGDirectDisplayID?
    @Binding var selectedWindowID: CGWindowID?
    @Binding var selectedAppIDs: Set<String>
    let isLocked: Bool

    var body: some View {
        Card(
            title: "What to record",
            subtitle: Self.subtitle(for: sourceKind)
        ) {
            Picker("", selection: $sourceKind) {
                ForEach(SourceKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch sourceKind {
            case .display:
                displayPicker
            case .window:
                windowPicker
            case .applications:
                displayPicker
                appList
            }

            HStack {
                Button {
                    Task { await content.refresh() }
                } label: {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                }
                .disabled(content.isRefreshing)
                if content.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.6 : 1)
    }

    private var displayPicker: some View {
        Picker("Display", selection: $selectedDisplayID) {
            ForEach(content.displays, id: \.displayID) { display in
                Text(Self.label(for: display)).tag(Optional(display.displayID))
            }
        }
        .disabled(content.displays.isEmpty)
    }

    private var windowPicker: some View {
        Group {
            if content.windows.isEmpty {
                Text("No capturable windows found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Window", selection: $selectedWindowID) {
                    ForEach(content.windows, id: \.windowID) { window in
                        Text(Self.label(for: window)).tag(Optional(window.windowID))
                    }
                }
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applications")
                .font(.subheadline.weight(.medium))
            if content.applications.isEmpty {
                Text("No running apps with visible windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(content.applications, id: \.bundleIdentifier) { app in
                            Toggle(isOn: binding(for: app)) {
                                Text(app.applicationName)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
                )
            }
        }
    }

    private func binding(for app: SCRunningApplication) -> Binding<Bool> {
        Binding(
            get: { selectedAppIDs.contains(app.bundleIdentifier) },
            set: { isOn in
                if isOn { selectedAppIDs.insert(app.bundleIdentifier) }
                else { selectedAppIDs.remove(app.bundleIdentifier) }
            }
        )
    }

    private static func subtitle(for kind: SourceKind) -> String {
        switch kind {
        case .display:
            return "The whole screen plus every sound the system is playing."
        case .window:
            return "One window, and the audio of the app that owns it."
        case .applications:
            return "Only the chosen apps are drawn, and only their audio is recorded \u{2014} every other sound on the Mac stays out of the file."
        }
    }

    private static func label(for display: SCDisplay) -> String {
        let scale = CaptureTarget.backingScale(for: display)
        let pixels = "\(Int(Double(display.width) * scale))×\(Int(Double(display.height) * scale))"
        return "Display \(display.displayID) — \(pixels) px"
    }

    private static func label(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown app"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
    }
}

// MARK: - Quality settings

@MainActor
struct QualitySettingsView: View {
    @Binding var settings: RecordingSettings
    let summary: String
    let isLocked: Bool

    var body: some View {
        Card(title: "Quality & format", subtitle: summary) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Video codec")
                    Picker("", selection: $settings.codec) {
                        ForEach(VideoCodecChoice.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Container")
                    Picker("", selection: $settings.container) {
                        ForEach(settings.codec.supportedContainers) { container in
                            Text(container.displayName).tag(container)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Audio")
                    Picker("", selection: $settings.audio) {
                        ForEach(AudioQualityChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Bitrate target")
                    Picker("", selection: $settings.tier) {
                        ForEach(QualityTier.allCases) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(settings.codec.isIntraFrameMaster)
                }
                GridRow {
                    Text("Frame rate")
                    Picker("", selection: $settings.framesPerSecond) {
                        ForEach(RecordingSettings.supportedFrameRates, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Divider().padding(.vertical, 2)

            Toggle("Show the mouse pointer", isOn: $settings.showsCursor)
            Toggle("Capture at the display's native resolution", isOn: $settings.prefersBestResolution)
            Toggle("Exclude this app's own sounds", isOn: $settings.excludesOwnAudio)
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.6 : 1)
    }
}

// MARK: - Output folder

@MainActor
struct OutputFolderView: View {
    @Binding var settings: RecordingSettings
    let isLocked: Bool

    var body: some View {
        Card(title: "Save to") {
            HStack {
                Text(settings.outputDirectory.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Choose…") { chooseFolder() }
                Button {
                    try? FileManager.default.createDirectory(
                        at: settings.outputDirectory,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(settings.outputDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open this folder in the Finder")
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.6 : 1)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectoryPath = url.path
        }
    }
}

// MARK: - Transport

@MainActor
struct TransportView: View {
    @ObservedObject var engine: RecordingEngine
    let canRecord: Bool
    let onStart: @MainActor () -> Void
    let onStop: @MainActor () -> Void

    var body: some View {
        Card(title: "Recording") {
            HStack(spacing: 14) {
                if engine.state == .idle {
                    Button(action: onStart) {
                        Label("Start Recording", systemImage: "record.circle")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canRecord)
                    .keyboardShortcut("r", modifiers: [.command])
                } else {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(engine.state == .preparing || engine.state == .finishing)
                    .keyboardShortcut("r", modifiers: [.command])

                    Button {
                        engine.togglePause()
                    } label: {
                        Label(
                            engine.state == .paused ? "Resume" : "Pause",
                            systemImage: engine.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(minWidth: 90)
                    }
                    .controlSize(.large)
                    .disabled(engine.state == .preparing || engine.state == .finishing)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.duration(engine.elapsed))
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundStyle(engine.state == .paused ? .secondary : .primary)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AudioLevelBar(level: engine.audioLevel, isActive: engine.state == .recording)
        }
    }

    private var statusLine: String {
        switch engine.state {
        case .idle: return "Ready"
        case .preparing: return "Starting the capture stream…"
        case .recording: return "\(Format.bytes(engine.fileSize)) · \(engine.capturedFrames) frames"
        case .paused: return "Paused · \(Format.bytes(engine.fileSize))"
        case .finishing: return "Finalising the movie…"
        }
    }
}

@MainActor
struct AudioLevelBar: View {
    let level: Float
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(isActive
                     ? (level > 0.001 ? "Captured audio" : "Captured audio — silence")
                     : "Captured audio level")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level > 0.98 ? Color.red : Color.green)
                        .frame(width: max(0, min(1, CGFloat(level))) * geometry.size.width)
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Result & export

@MainActor
struct ResultView: View {
    let url: URL
    @ObservedObject var exporter: MediaExporter
    @Binding var exportTarget: MediaExporter.Target

    var body: some View {
        Card(title: "Last recording") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(Format.bytes(RecordingEngine.sizeOfFile(at: url))) · \(url.deletingLastPathComponent().path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Play") { NSWorkspace.shared.open(url) }
            }

            Divider()

            HStack {
                Picker("Also export as", selection: $exportTarget) {
                    ForEach(MediaExporter.Target.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .disabled(exporter.isExporting)
                Button("Export") {
                    Task { _ = await exporter.export(source: url, to: exportTarget) }
                }
                .disabled(exporter.isExporting)
            }

            if exporter.isExporting {
                HStack {
                    ProgressView(value: exporter.progress)
                    Button("Cancel") { exporter.cancel() }
                }
            }

            if let exported = exporter.lastExportURL, !exporter.isExporting {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(exported.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}
