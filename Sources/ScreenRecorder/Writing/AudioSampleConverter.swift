import AVFoundation
import CoreMedia
import Foundation

/// Converts the de-interleaved 32-bit float PCM that ScreenCaptureKit delivers into the
/// interleaved layout AVAssetWriter needs when it is asked to store uncompressed audio.
///
/// The AAC path does not need this — the encoder accepts the native buffers — so the
/// converter is only built when the user picks the lossless preset.
final class AudioSampleConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormatDescription: CMAudioFormatDescription?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let sourceDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(sourceDescription)
        else { return nil }

        var asbd = asbdPointer.pointee
        guard let source = AVAudioFormat(streamDescription: &asbd) else { return nil }

        // AVAudioConverter's simple `convert(to:from:)` does not resample, which is fine
        // because both sides run at the stream's own rate.
        guard source.sampleRate == targetFormat.sampleRate else { return nil }

        if sourceFormat != source || converter == nil {
            converter = AVAudioConverter(from: source, to: targetFormat)
            sourceFormat = source
        }
        guard let converter else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frameCount),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return nil }

        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        do {
            try converter.convert(to: outputBuffer, from: inputBuffer)
        } catch {
            return nil
        }

        return makeSampleBuffer(
            from: outputBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        if targetFormatDescription == nil {
            var description: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: targetFormat.streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
            guard status == noErr else { return nil }
            targetFormatDescription = description
        }
        guard let formatDescription = targetFormatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetFormat.sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard status == noErr else { return nil }

        return sampleBuffer
    }
}

// MARK: - Level metering

enum AudioLevelMeter {
    /// Peak amplitude (0…1) across all channels of a float PCM sample buffer.
    static func peak(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        var peak: Float = 0
        do {
            try sampleBuffer.withAudioBufferList { bufferList, _ in
                for buffer in bufferList {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for index in 0..<count {
                        peak = max(peak, abs(samples[index]))
                    }
                }
            }
        } catch {
            return nil
        }
        return min(peak, 1.0)
    }
}
