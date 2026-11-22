import AVFAudio
import AudioToolbox

/// Plays stereo PCM from the native SRTP receive pipeline through the current tvOS audio route.
final class NvstTVAudioOutput {
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode

    init(pipeline: NvstAudioReceivePipeline) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: NvstOpusDecoder.sampleRate, channels: 2) else {
            throw NvstTVAudioError.unsupportedFormat
        }
        source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            let frames = Int(frameCount)
            let samples = pipeline.pull(sampleCount: frames * 2)
            isSilence.pointee = ObjCBool(samples.isEmpty)

            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let outputSamples = data.assumingMemoryBound(to: Float.self)
                let availableFrames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for frame in 0 ..< availableFrames {
                    let index = frame * 2 + channel
                    outputSamples[frame] = index < samples.count ? samples[index] : 0
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    deinit {
        engine.stop()
    }

    private enum NvstTVAudioError: Error {
        case unsupportedFormat
    }
}
