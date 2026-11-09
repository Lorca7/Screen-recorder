import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// MARK: - Container

/// Output container (wrapper) for the recorded movie.
enum Container: String, CaseIterable, Codable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mov: return "QuickTime (.mov)"
        case .mp4: return "MPEG-4 (.mp4)"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    var fileExtension: String { rawValue }
}

// MARK: - Video codec

enum VideoCodecChoice: String, CaseIterable, Codable, Identifiable {
    /// H.264 — the most widely compatible codec (every browser, editor, phone, TV).
    case h264
    /// HEVC/H.265 — same quality at roughly 40–50 % of the bitrate. Native on macOS/iOS.
    case hevc
    /// Apple ProRes 422 — intra-frame mastering codec for editing. Very large files.
    case proRes422

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264 — maximum compatibility"
        case .hevc: return "HEVC / H.265 — best quality per MB"
        case .proRes422: return "Apple ProRes 422 — editing master"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422: return .proRes422
        }
    }

    /// Containers this codec can legally be written into.
    var supportedContainers: [Container] {
        switch self {
        case .h264, .hevc: return [.mp4, .mov]
        case .proRes422: return [.mov]
        }
    }

    /// Codecs with their own fixed, very high data rate ignore the bitrate ladder.
    var isIntraFrameMaster: Bool { self == .proRes422 }

    /// Pixel format requested from ScreenCaptureKit.
    ///
    /// 4:2:0 bi-planar is what the H.264/HEVC hardware encoders consume natively, so
    /// handing it over directly avoids a colour conversion per frame. ProRes 422 keeps
    /// 4:2:2 chroma, so it is fed full BGRA to preserve crisp coloured text.
    var capturePixelFormat: OSType {
        switch self {
        case .h264, .hevc: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .proRes422: return kCVPixelFormatType_32BGRA
        }
    }
}

// MARK: - Audio quality

enum AudioQualityChoice: String, CaseIterable, Codable, Identifiable {
    /// 256 kbit/s AAC-LC, stereo, 48 kHz — transparent for screen/voice/music content.
    case aac256
    /// 320 kbit/s AAC-LC, stereo, 48 kHz.
    case aac320
    /// Uncompressed 32-bit float PCM, exactly the samples ScreenCaptureKit delivered.
    case lossless

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aac256: return "AAC 256 kbps (transparent)"
        case .aac320: return "AAC 320 kbps"
        case .lossless: return "Lossless 32-bit float PCM"
        }
    }

    var bitrate: Int? {
        switch self {
        case .aac256: return 256_000
        case .aac320: return 320_000
        case .lossless: return nil
        }
    }

    /// Uncompressed PCM is only valid inside a QuickTime movie.
    var supportedContainers: [Container] {
        switch self {
        case .aac256, .aac320: return [.mp4, .mov]
        case .lossless: return [.mov]
        }
    }
}

// MARK: - Quality tier

enum QualityTier: String, CaseIterable, Codable, Identifiable {
    case balanced
    case high
    case maximum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    var bitrateMultiplier: Double {
        switch self {
        case .balanced: return 0.65
        case .high: return 1.0
        case .maximum: return 1.6
        }
    }
}

// MARK: - Settings

struct RecordingSettings: Codable, Equatable {
    var codec: VideoCodecChoice = .hevc
    var container: Container = .mov
    var audio: AudioQualityChoice = .aac256
    var tier: QualityTier = .high
    var framesPerSecond: Int = 60
    var showsCursor: Bool = true
    /// Keep this app's own output (alert sounds, etc.) out of the recording so there is
    /// no feedback loop.
    var excludesOwnAudio: Bool = true
    /// Ask ScreenCaptureKit for the sharpest available buffers rather than a scaled proxy.
    var prefersBestResolution: Bool = true
    var outputDirectoryPath: String = RecordingSettings.defaultOutputDirectory.path

    static let sampleRate: Int = 48_000
    static let channelCount: Int = 2

    static var defaultOutputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Screen Recordings", isDirectory: true)
    }

    var outputDirectory: URL { URL(fileURLWithPath: outputDirectoryPath, isDirectory: true) }

    static let supportedFrameRates = [24, 30, 48, 60, 120]

    /// Forces the combination of codec / container / audio format back into a legal state.
    /// Called after every change made in the UI, so an impossible combination can never
    /// reach AVAssetWriter.
    mutating func normalize() {
        if !codec.supportedContainers.contains(container) {
            container = codec.supportedContainers[0]
        }
        if !audio.supportedContainers.contains(container) {
            // Uncompressed audio only fits in QuickTime, and every video codec here can
            // live in QuickTime — so honour the audio choice and move the container.
            if audio.supportedContainers.contains(.mov), codec.supportedContainers.contains(.mov) {
                container = .mov
            } else {
                audio = .aac256
            }
        }
        if !RecordingSettings.supportedFrameRates.contains(framesPerSecond) {
            framesPerSecond = 60
        }
    }

    /// Target average bitrate in bits per second, derived from the pixel throughput.
    ///
    /// Screen content is mostly static with occasional full-frame changes, so a
    /// bits-per-pixel model tracks perceived quality far better than a fixed ladder.
    func videoBitrate(width: Int, height: Int) -> Int {
        let bitsPerPixel: Double
        switch codec {
        case .h264: bitsPerPixel = 0.11
        case .hevc: bitsPerPixel = 0.075
        case .proRes422: return 0
        }
        let pixelRate = Double(width * height * framesPerSecond)
        let raw = pixelRate * bitsPerPixel * tier.bitrateMultiplier
        return Int(min(max(raw, 2_500_000), 240_000_000))
    }

    // MARK: AVAssetWriter settings

    func videoOutputSettings(width: Int, height: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        guard !codec.isIntraFrameMaster else { return settings }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate(width: width, height: height),
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            // A keyframe every two seconds keeps seeking responsive without wasting
            // bitrate on a mostly-static screen.
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true
        ]

        switch codec {
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        case .hevc:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .proRes422:
            break
        }

        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    func audioOutputSettings() -> [String: Any] {
        switch audio {
        case .aac256, .aac320:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: RecordingSettings.sampleRate,
                AVNumberOfChannelsKey: RecordingSettings.channelCount,
                AVEncoderBitRateKey: audio.bitrate ?? 256_000
            ]
        case .lossless:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: RecordingSettings.sampleRate,
                AVNumberOfChannelsKey: RecordingSettings.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    /// Interleaved layout the asset writer expects for uncompressed output. ScreenCaptureKit
    /// hands over *non*-interleaved float buffers, so they are converted on the way in.
    var losslessTargetFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(RecordingSettings.sampleRate),
            channels: AVAudioChannelCount(RecordingSettings.channelCount),
            interleaved: true
        )
    }
}

// MARK: - Persistence

/// Tiny UserDefaults-backed store so settings survive relaunches.
enum SettingsStore {
    private static let key = "recordingSettings.v1"

    static func load() -> RecordingSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else { return RecordingSettings() }
        settings.normalize()
        return settings
    }

    static func save(_ settings: RecordingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
