import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

enum SourceKind: String, CaseIterable, Identifiable {
    case display
    case window
    case applications

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: return "Entire display"
        case .window: return "Single window"
        case .applications: return "Specific apps"
        }
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var content = ShareableContentStore()
    @StateObject private var engine = RecordingEngine()
    @StateObject private var exporter = MediaExporter()

    @State private var settings = SettingsStore.load()
    @State private var sourceKind: SourceKind = .display
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindowID: CGWindowID?
    @State private var selectedAppIDs: Set<String> = []
    @State private var exportTarget: MediaExporter.Target = .mp4Compatible

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !content.hasPermission {
                    PermissionBanner(store: content)
                }

                SourceSelection(
                    content: content,
                    sourceKind: $sourceKind,
                    selectedDisplayID: $selectedDisplayID,
                    selectedWindowID: $selectedWindowID,
                    selectedAppIDs: $selectedAppIDs,
                    isLocked: engine.isBusy
                )

                QualitySettingsView(settings: $settings, summary: qualitySummary, isLocked: engine.isBusy)

                OutputFolderView(settings: $settings, isLocked: engine.isBusy)

                TransportView(
                    engine: engine,
                    canRecord: resolvedTarget != nil && content.hasPermission,
                    onStart: startRecording,
                    onStop: { Task { await engine.stop() } }
                )

                if let message = engine.errorMessage {
                    MessageBanner(text: message, kind: .error) { engine.errorMessage = nil }
                }

                if let url = engine.lastRecordingURL, !engine.isBusy {
                    ResultView(
                        url: url,
                        exporter: exporter,
                        exportTarget: $exportTarget
                    )
                }

                if let message = exporter.errorMessage {
                    MessageBanner(text: message, kind: .error) { exporter.errorMessage = nil }
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await content.refresh()
            applyDefaultSelection()
        }
        .onChange(of: settings) { _, newValue in
            var normalized = newValue
            normalized.normalize()
            if normalized != newValue { settings = normalized }
            SettingsStore.save(normalized)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            guard !engine.isBusy else { return }
            Task {
                await content.refresh()
                applyDefaultSelection()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screen Recorder")
                .font(.system(size: 22, weight: .semibold))
            Text("Records the picture **and the sound the apps themselves are making** — straight from the system audio tap, not the microphone and not a loopback of your speakers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Target resolution

    private var resolvedTarget: CaptureTarget? {
        switch sourceKind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first else { return nil }
            return .display(display)
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selectedWindowID }) else { return nil }
            return .window(window)
        case .applications:
            let apps = content.applications.filter { selectedAppIDs.contains($0.bundleIdentifier) }
            guard !apps.isEmpty else { return nil }
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first else { return nil }
            return .applications(apps, onDisplay: display)
        }
    }

    private var qualitySummary: String {
        guard let target = resolvedTarget else { return "Choose something to record." }
        let size = target.pixelSize()
        let bitrate = settings.videoBitrate(width: size.width, height: size.height)
        let audioText: String
        switch settings.audio {
        case .lossless:
            audioText = "48 kHz stereo, uncompressed"
        case .aac256, .aac320:
            audioText = "48 kHz stereo, \((settings.audio.bitrate ?? 0) / 1000) kbps AAC"
        }
        let scope = target.capturesOnlySelectedAppAudio ? "audio from the selected apps only" : "all system audio"
        return "\(size.width)×\(size.height) @ \(settings.framesPerSecond) fps · video ≈ \(Format.bitrate(bitrate)) · \(audioText) · \(scope)"
    }

    private func applyDefaultSelection() {
        if selectedDisplayID == nil || !content.displays.contains(where: { $0.displayID == selectedDisplayID }) {
            selectedDisplayID = content.displays.first?.displayID
        }
        if selectedWindowID == nil || !content.windows.contains(where: { $0.windowID == selectedWindowID }) {
            selectedWindowID = content.windows.first?.windowID
        }
        let available = Set(content.applications.map(\.bundleIdentifier))
        selectedAppIDs.formIntersection(available)
    }

    private func startRecording() {
        guard let target = resolvedTarget else { return }
        var normalized = settings
        normalized.normalize()
        settings = normalized
        Task { await engine.start(target: target, settings: normalized) }
    }
}
