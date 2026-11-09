import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns one SCStream and routes its screen and audio sample buffers into a `MovieWriter`.
///
/// Audio here is the audio *of the capture* — the mix produced by the apps on screen, taken
/// straight from the window server's audio tap. It is not the microphone and it is not a
/// loopback of the output device, so nothing needs to be installed and the recording is
/// unaffected by the system volume, the chosen output device, or headphones being plugged in.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let videoQueue = DispatchQueue(label: "app.screenrecorder.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "app.screenrecorder.audio", qos: .userInitiated)

    private var stream: SCStream?
    private let writer: MovieWriter

    /// Peak level (0…1) of the most recent audio buffer, for the level meter.
    var onAudioLevel: ((Float) -> Void)?
    /// Called if the stream stops by itself (display disconnected, window closed, …).
    var onStreamStopped: ((Error) -> Void)?

    init(writer: MovieWriter) {
        self.writer = writer
        super.init()
    }

    func start(target: CaptureTarget, settings: RecordingSettings, width: Int, height: Int) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = settings.codec.capturePixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(settings.framesPerSecond)
        )
        configuration.showsCursor = settings.showsCursor
        configuration.scalesToFit = false
        // Deeper queue = more slack before ScreenCaptureKit starts dropping frames when the
        // encoder briefly stalls. 8 is the documented maximum.
        configuration.queueDepth = 8
        configuration.captureResolution = settings.prefersBestResolution ? .best : .automatic

        // --- The audio half ---
        configuration.capturesAudio = true
        configuration.sampleRate = RecordingSettings.sampleRate
        configuration.channelCount = RecordingSettings.channelCount
        configuration.excludesCurrentProcessAudio = settings.excludesOwnAudio

        let stream = SCStream(filter: target.contentFilter(), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            // A stream that already stopped on its own throws here; the file is still valid.
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            guard CaptureSession.isCompleteFrame(sampleBuffer) else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            if let peak = AudioLevelMeter.peak(of: sampleBuffer) {
                onAudioLevel?(peak)
            }
            writer.appendAudio(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStreamStopped?(error)
    }

    /// ScreenCaptureKit also emits idle/blank frames that carry no new pixels; appending
    /// them would waste bitrate (and, for `.blank`, write black video).
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard sampleBuffer.imageBuffer != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
