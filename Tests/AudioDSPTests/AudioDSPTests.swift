import Testing
import AudioDSP
import CoreAudio

struct AudioDSPTests {
    private func render(_ state: OpaquePointer, _ samples: [Float]) -> [Float] {
        var input = samples, output = [Float](repeating: -99, count: samples.count)
        input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var source = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var destination = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                var time = AudioTimeStamp()
                withUnsafePointer(to: &time) { t in
                    _ = MixerDSPCallback(0, t, &source, t, &destination, t, UnsafeMutableRawPointer(state))
                }
            }
        }
        return output
    }
    @Test func testIndependentRoutesPreserveStereoAndScale() {
        let quiet = MixerDSPCreate(0.3, 48000)!, loud = MixerDSPCreate(0.7, 48000)!
        defer { MixerDSPDestroy(quiet); MixerDSPDestroy(loud) }
        let source: [Float] = [0.5, -0.2, -0.8, 0.1]
        let a = render(quiet, source), b = render(loud, source)
        for index in source.indices {
            #expect(abs(a[index] - source[index] * 0.3) < 0.00001)
            #expect(abs(b[index] - source[index] * 0.7) < 0.00001)
        }
        #expect(MixerDSPFaults(quiet) == 0)
    }
    @Test func testMuteRampReachesSilenceWithoutStepAndRestores() {
        let dsp = MixerDSPCreate(1, 48000)!
        defer { MixerDSPDestroy(dsp) }
        MixerDSPSetGain(dsp, 0)
        let muted = render(dsp, Array(repeating: 1, count: 2048))
        #expect(muted[0] > 0.99)
        #expect(abs(muted.last!) < 0.0001)
        for frame in 1..<1024 { #expect(abs(muted[frame * 2] - muted[(frame - 1) * 2]) <= 1 / 480 + 0.00001) }
        MixerDSPSetGain(dsp, 0.7)
        let restored = render(dsp, Array(repeating: 1, count: 2048))
        #expect(abs(restored.last! - 0.7) < 0.0001)
    }
    @Test func testInvalidSamplesCannotPropagate() {
        let dsp = MixerDSPCreate(1, 48000)!
        defer { MixerDSPDestroy(dsp) }
        let result = render(dsp, [.nan, .infinity, -0.3, 0.2])
        #expect(result == [0, 0, -0.3, 0.2])
    }
    @Test func testMalformedBufferIsSilencedAndReported() {
        let dsp = MixerDSPCreate(1, 48000)!
        defer { MixerDSPDestroy(dsp) }
        var output: [Float] = [1, 1]
        output.withUnsafeMutableBytes { bytes in
            var destination = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var time = AudioTimeStamp()
            withUnsafePointer(to: &time) { t in _ = MixerDSPCallback(0, t, nil, t, &destination, t, UnsafeMutableRawPointer(dsp)) }
        }
        #expect(output == [0, 0]); #expect(MixerDSPFaults(dsp) == 1)
    }
}
