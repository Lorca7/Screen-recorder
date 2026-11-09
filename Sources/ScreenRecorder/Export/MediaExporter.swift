import AVFoundation
import Foundation

/// Converts a finished recording into one of the formats people actually need to hand off:
/// a universally playable MP4, a smaller HEVC MP4, a re-wrapped QuickTime movie, or an
/// audio-only M4A of the captured app audio.
@MainActor
final class MediaExporter: ObservableObject {
    enum Target: String, CaseIterable, Identifiable {
        case mp4Compatible
        case mp4HEVC
        case movRewrap
        case m4aAudioOnly

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .mp4Compatible: return "MP4 · H.264 + AAC (plays everywhere)"
            case .mp4HEVC: return "MP4 · HEVC + AAC (smaller file)"
            case .movRewrap: return "MOV · keep existing codecs (no re-encode)"
            case .m4aAudioOnly: return "M4A · captured audio only"
            }
        }

        var presetName: String {
            switch self {
            case .mp4Compatible: return AVAssetExportPresetHighestQuality
            case .mp4HEVC: return AVAssetExportPresetHEVCHighestQuality
            case .movRewrap: return AVAssetExportPresetPassthrough
            case .m4aAudioOnly: return AVAssetExportPresetAppleM4A
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4Compatible, .mp4HEVC: return .mp4
            case .movRewrap: return .mov
            case .m4aAudioOnly: return .m4a
            }
        }

        var fileExtension: String {
            switch self {
            case .mp4Compatible, .mp4HEVC: return "mp4"
            case .movRewrap: return "mov"
            case .m4aAudioOnly: return "m4a"
            }
        }

        var fileNameSuffix: String {
            switch self {
            case .mp4Compatible: return " (H.264)"
            case .mp4HEVC: return " (HEVC)"
            case .movRewrap: return " (rewrapped)"
            case .m4aAudioOnly: return " (audio)"
            }
        }
    }

    enum ExportError: LocalizedError {
        case unsupported(String)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): return reason
            case .failed(let reason): return "Export failed: \(reason)"
            case .cancelled: return "Export cancelled."
            }
        }
    }

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastExportURL: URL?
    @Published var errorMessage: String?

    private var currentSession: AVAssetExportSession?
    private var progressTimer: Timer?

    func export(source: URL, to target: Target, overwrite: Bool = true) async -> URL? {
        guard !isExporting else { return nil }
        isExporting = true
        progress = 0
        errorMessage = nil
        defer {
            isExporting = false
            stopProgressTimer()
            currentSession = nil
        }

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: target.presetName) else {
            errorMessage = ExportError.unsupported(
                "This Mac cannot export with the \(target.displayName) preset."
            ).localizedDescription
            return nil
        }

        guard session.supportedFileTypes.contains(target.fileType) else {
            errorMessage = ExportError.unsupported(
                "The recording's codecs cannot go into a .\(target.fileExtension) file without re-encoding. "
                + "Choose one of the MP4 options instead."
            ).localizedDescription
            return nil
        }

        let destination = MediaExporter.destinationURL(for: source, target: target)
        if overwrite, FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        session.outputURL = destination
        session.outputFileType = target.fileType
        session.shouldOptimizeForNetworkUse = (target.fileType == .mp4)
        currentSession = session
        startProgressTimer(for: session)

        await session.export()

        switch session.status {
        case .completed:
            progress = 1
            lastExportURL = destination
            return destination
        case .cancelled:
            errorMessage = ExportError.cancelled.localizedDescription
            return nil
        default:
            let reason = session.error?.localizedDescription ?? "unknown error"
            errorMessage = ExportError.failed(reason).localizedDescription
            return nil
        }
    }

    func cancel() {
        currentSession?.cancelExport()
    }

    static func destinationURL(for source: URL, target: Target) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + target.fileNameSuffix
        return source
            .deletingLastPathComponent()
            .appendingPathComponent(base)
            .appendingPathExtension(target.fileExtension)
    }

    private func startProgressTimer(for session: AVAssetExportSession) {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak session] _ in
            guard let session else { return }
            let value = Double(session.progress)
            Task { @MainActor in self?.progress = value }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

private extension AVAssetExportSession {
    /// Bridges the completion-handler API to async/await.
    func export() async {
        await withCheckedContinuation { continuation in
            exportAsynchronously {
                continuation.resume()
            }
        }
    }
}
