import AVFoundation
import CoreMedia
import Foundation

/// Wraps AVAssetWriter with the pieces ScreenCaptureKit needs: a real-time video track, a
/// real-time audio track for the captured system/app audio, pause-and-resume support and a
/// clean asynchronous finish.
///
/// Every public method is safe to call from any thread; work is funnelled onto one serial
/// queue so sample order is preserved.
///
/// `@unchecked Sendable` is accurate rather than a shortcut: every mutable property is
/// touched only inside `queue`, and the two UI-facing counters sit behind `statsLock`.
final class MovieWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case setupFailed(String)
        case writingFailed(String)
        case noFramesCaptured

        var errorDescription: String? {
            switch self {
            case .setupFailed(let reason): return "Could not prepare the movie file: \(reason)"
            case .writingFailed(let reason): return "Writing the movie failed: \(reason)"
            case .noFramesCaptured: return "No video frames were captured."
            }
        }
    }

    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let audioConverter: AudioSampleConverter?
    private let queue = DispatchQueue(label: "app.screenrecorder.writer", qos: .userInitiated)

    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime = .zero
    private var isPaused = false
    private var pauseStart: CMTime?
    private var pausedTotal: CMTime = .zero
    private var needsResumeAnchor = false
    private var isFinished = false

    /// Counters are read by the UI every frame, so they live behind a tiny lock rather than
    /// forcing the main thread to wait on the (busy) writer queue.
    private let statsLock = NSLock()
    private var videoFrameCountStorage = 0
    private var audioSampleCountStorage = 0

    init(outputURL: URL, settings: RecordingSettings, width: Int, height: Int) throws {
        self.outputURL = outputURL

        // AVAssetWriter refuses to overwrite.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.container.fileType)
        } catch {
            throw WriterError.setupFailed(error.localizedDescription)
        }

        let videoSettings = settings.videoOutputSettings(width: width, height: height)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw WriterError.setupFailed(
                "\(settings.codec.displayName) cannot be written into \(settings.container.displayName) on this Mac."
            )
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings = settings.audioOutputSettings()
        guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
            throw WriterError.setupFailed(
                "\(settings.audio.displayName) cannot be written into \(settings.container.displayName)."
            )
        }
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        if settings.audio == .lossless, let format = settings.losslessTargetFormat {
            audioConverter = AudioSampleConverter(targetFormat: format)
        } else {
            audioConverter = nil
        }

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw WriterError.setupFailed("The chosen track combination was rejected.")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw WriterError.setupFailed(writer.error?.localizedDescription ?? "unknown reason")
        }
    }

    // MARK: - Appending

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.handleVideo(sampleBuffer) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.handleAudio(sampleBuffer) }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }

        if sessionStart == nil {
            // The first frame defines time zero for both tracks.
            sessionStart = pts
            writer.startSession(atSourceTime: pts)
        }
        if isPaused { return }
        resolveResumeAnchor(at: pts)

        guard videoInput.isReadyForMoreMediaData else { return }
        guard let adjusted = MovieWriter.retimed(sampleBuffer, subtracting: pausedTotal) else { return }
        if videoInput.append(adjusted) {
            statsLock.withLock { videoFrameCountStorage += 1 }
            lastVideoTime = CMSampleBufferGetPresentationTimeStamp(adjusted)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinished, writer.status == .writing else { return }
        // Audio can only be written once the session clock has been started by a frame.
        guard let start = sessionStart, !isPaused else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric, pts >= start else { return }
        resolveResumeAnchor(at: pts)

        var buffer = sampleBuffer
        if let audioConverter {
            guard let converted = audioConverter.convert(sampleBuffer) else { return }
            buffer = converted
        }

        guard audioInput.isReadyForMoreMediaData else { return }
        guard let adjusted = MovieWriter.retimed(buffer, subtracting: pausedTotal) else { return }
        if audioInput.append(adjusted) {
            statsLock.withLock { audioSampleCountStorage += 1 }
        }
    }

    /// After a resume, the gap between the pause and the next sample is subtracted from
    /// every later timestamp so the movie has no silent/frozen hole in it.
    private func resolveResumeAnchor(at pts: CMTime) {
        guard needsResumeAnchor, let pauseStart else { return }
        let gap = CMTimeSubtract(pts, pauseStart)
        if gap.isNumeric, gap > .zero {
            pausedTotal = CMTimeAdd(pausedTotal, gap)
        }
        self.pauseStart = nil
        needsResumeAnchor = false
    }

    // MARK: - Pause / resume

    func pause() {
        queue.async { [weak self] in
            guard let self, !self.isPaused, self.sessionStart != nil else { return }
            self.isPaused = true
            // Record where the hole starts, in *source* time.
            self.pauseStart = CMTimeAdd(self.lastVideoTime, self.pausedTotal)
            self.needsResumeAnchor = false
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.isPaused else { return }
            self.isPaused = false
            self.needsResumeAnchor = self.pauseStart != nil
        }
    }

    // MARK: - Finishing

    /// Flushes both tracks and returns the finished file. Throws if nothing was captured
    /// or the writer failed.
    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: WriterError.writingFailed("writer went away"))
                    return
                }
                guard !self.isFinished else {
                    continuation.resume(returning: self.outputURL)
                    return
                }
                self.isFinished = true

                guard self.writer.status == .writing, self.capturedFrameCount > 0 else {
                    let failure = self.writer.error?.localizedDescription
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.outputURL)
                    continuation.resume(
                        throwing: failure.map { WriterError.writingFailed($0) } ?? WriterError.noFramesCaptured
                    )
                    return
                }

                self.videoInput.markAsFinished()
                self.audioInput.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: self.outputURL)
                    } else {
                        let reason = self.writer.error?.localizedDescription ?? "unknown error"
                        continuation.resume(throwing: WriterError.writingFailed(reason))
                    }
                }
            }
        }
    }

    /// Throws away a recording in progress (used when the stream dies during setup).
    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.isFinished = true
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }

    var capturedFrameCount: Int {
        statsLock.withLock { videoFrameCountStorage }
    }

    var capturedAudioBufferCount: Int {
        statsLock.withLock { audioSampleCountStorage }
    }

    // MARK: - Helpers

    /// Shifts every timestamp in a sample buffer back by `offset`.
    static func retimed(_ sampleBuffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        guard offset.isNumeric, offset > .zero else { return sampleBuffer }

        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        ) == noErr, count > 0 else { return sampleBuffer }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: Int(count)
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        ) == noErr else { return sampleBuffer }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isNumeric {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isNumeric {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }
}
