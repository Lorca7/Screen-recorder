import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

/// Drives one recording from "start" to a finished file on disk, and publishes everything
/// the UI needs while it runs.
@MainActor
final class RecordingEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var capturedFrames: Int = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published var errorMessage: String?

    private var session: CaptureSession?
    private var writer: MovieWriter?
    private var ticker: Timer?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0

    var isBusy: Bool { state != .idle }

    // MARK: - Start

    func start(target: CaptureTarget, settings: RecordingSettings) async {
        guard state == .idle else { return }
        state = .preparing
        errorMessage = nil
        audioLevel = 0
        capturedFrames = 0
        fileSize = 0
        elapsed = 0
        accumulated = 0

        let (width, height) = target.pixelSize()
        let url = RecordingEngine.makeOutputURL(settings: settings)

        var pendingWriter: MovieWriter?
        do {
            let writer = try MovieWriter(outputURL: url, settings: settings, width: width, height: height)
            pendingWriter = writer
            let session = CaptureSession(writer: writer)
            session.onAudioLevel = { [weak self] peak in
                Task { @MainActor in self?.updateAudioLevel(peak) }
            }
            session.onStreamStopped = { [weak self] error in
                Task { @MainActor in await self?.handleUnexpectedStop(error) }
            }

            try await session.start(target: target, settings: settings, width: width, height: height)

            self.writer = writer
            self.session = session
            startDate = Date()
            state = .recording
            startTicker()
        } catch {
            pendingWriter?.cancel()
            writer = nil
            session = nil
            state = .idle
            errorMessage = RecordingEngine.describe(error)
        }
    }

    // MARK: - Pause / resume

    func togglePause() {
        switch state {
        case .recording:
            writer?.pause()
            accumulated += Date().timeIntervalSince(startDate ?? Date())
            startDate = nil
            state = .paused
            audioLevel = 0
        case .paused:
            writer?.resume()
            startDate = Date()
            state = .recording
        default:
            break
        }
    }

    // MARK: - Stop

    @discardableResult
    func stop() async -> URL? {
        guard state == .recording || state == .paused else { return nil }
        state = .finishing
        stopTicker()

        await session?.stop()
        session = nil

        guard let writer else {
            state = .idle
            return nil
        }
        self.writer = nil

        do {
            let url = try await writer.finish()
            lastRecordingURL = url
            fileSize = RecordingEngine.sizeOfFile(at: url)
            state = .idle
            return url
        } catch {
            errorMessage = RecordingEngine.describe(error)
            state = .idle
            return nil
        }
    }

    /// The stream died on its own (display unplugged, captured window closed). Save whatever
    /// was recorded rather than losing it.
    private func handleUnexpectedStop(_ error: Error) async {
        guard state == .recording || state == .paused else { return }
        let saved = await stop()
        errorMessage = saved == nil
            ? "Capture stopped: \(RecordingEngine.describe(error))"
            : "Capture stopped early (\(RecordingEngine.describe(error))). The recording up to that point was saved."
    }

    // MARK: - Live stats

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        if let startDate {
            elapsed = accumulated + Date().timeIntervalSince(startDate)
        } else {
            elapsed = accumulated
        }
        if let writer {
            capturedFrames = writer.capturedFrameCount
            fileSize = RecordingEngine.sizeOfFile(at: writer.outputURL)
        }
        // Decay the meter so it falls smoothly when audio goes quiet.
        audioLevel = max(0, audioLevel - 0.08)
    }

    private func updateAudioLevel(_ peak: Float) {
        audioLevel = max(audioLevel, peak)
    }

    // MARK: - Helpers

    static func makeOutputURL(settings: RecordingSettings) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording \(formatter.string(from: Date()))"
        return settings.outputDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(settings.container.fileExtension)
    }

    static func sizeOfFile(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        if let size = values?.totalFileAllocatedSize { return Int64(size) }
        return 0
    }

    static func describe(_ error: Error) -> String {
        if let writerError = error as? MovieWriter.WriterError {
            return writerError.errorDescription ?? "\(writerError)"
        }
        let nsError = error as NSError
        if nsError.code == -3801 || nsError.domain.contains("ScreenCaptureKit") {
            return "\(nsError.localizedDescription) (ScreenCaptureKit error \(nsError.code))"
        }
        return nsError.localizedDescription
    }
}
