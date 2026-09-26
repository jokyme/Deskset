import CoreAudio
import Foundation
import DesksetCore

/// "App: Audio …" suites of `Deskset --self-test`. No real capture, device change or key event: the engine runs with
/// fake backends, Win7Audio with fake controllers, the DSP with synthetic signals (MediaKey is tested with MediaUI).
enum AudioSelfTests {
    static func run(_ t: AppTestRunner) {
        optionTests(t)
        levelTests(t)
        spectrumTests(t)
        bandTests(t)
        ringTests(t)
        engineTests(t)
        measureTests(t)
        captureScopeTests(t)
        win7AudioTests(t)
        outputControlTests(t)
        tapAggregateTests(t)
        appVolumeTests(t)
        registrationTests(t)
        deviceTests(t)
        testSkinTests(t)
    }

    // MARK: Signals

    static let rate = 48_000.0

    /// Interleaved sine on every channel (or only `channel`).
    static func sine(_ frequency: Double, amplitude: Double, seconds: Double, channels: Int = 2,
                     channel: Int? = nil, sampleRate: Double = rate) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * frequency * Double(f) / sampleRate))
            for c in 0..<channels where channel == nil || channel == c { out[f * channels + c] = v }
        }
        return out
    }

    /// Deterministic white noise, uniform in ±amplitude.
    static func noise(amplitude: Double, seconds: Double, channels: Int = 2, seed: UInt64 = 42) -> [Float] {
        var state = seed
        let count = Int(seconds * rate) * channels
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u = Double(state >> 11) / Double(1 << 53)
            return Float((u * 2 - 1) * amplitude)
        }
    }

    static func feed(_ a: AudioAnalyzer, _ samples: [Float], channels: Int = 2, sampleRate: Double = rate) {
        samples.withUnsafeBufferPointer { p in
            a.process(p.baseAddress!, stride: channels, frames: samples.count / channels, channels: channels,
                      sampleRate: sampleRate)
        }
    }

    /// Feeds in 16 ms slices, as the engine's analysis timer does (one transform per slice at most).
    static func feedLikeEngine(_ a: AudioAnalyzer, _ samples: [Float], channels: Int = 2) {
        let slice = Int(rate * AudioCaptureEngine.analysisInterval) * channels
        var start = 0
        while start < samples.count {
            let end = min(start + slice, samples.count)
            feed(a, Array(samples[start..<end]), channels: channels)
            start = end
        }
    }

    // MARK: Options

    static func optionTests(_ t: AppTestRunner) {
        t.suite("App: Audio options") {
            t.equal(AudioChannel.parse("L"), .index(0))
            t.equal(AudioChannel.parse("fl"), .index(0))
            t.equal(AudioChannel.parse("1"), .index(1))
            t.equal(AudioChannel.parse("C"), .index(2))
            t.equal(AudioChannel.parse("sub"), .index(3))
            t.equal(AudioChannel.parse("LFE"), .index(3))
            t.equal(AudioChannel.parse("BL"), .index(4))
            t.equal(AudioChannel.parse("br"), .index(5))
            t.equal(AudioChannel.parse("SL"), .index(6))
            t.equal(AudioChannel.parse(" SR "), .index(7))
            t.equal(AudioChannel.parse("Avg"), .sum)
            t.equal(AudioChannel.parse(""), .sum)
            t.equal(AudioChannel.parse("Left"), nil)
            // Rows: mono answers L, R and C; stereo has no centre; Sum is the extra row.
            t.equal(AudioChannel.index(1).row(channels: 1), 0)
            t.equal(AudioChannel.index(3).row(channels: 1), nil)
            t.equal(AudioChannel.index(2).row(channels: 2), nil)
            t.equal(AudioChannel.sum.row(channels: 2), 2)
            t.equal(AudioChannel.index(5).row(channels: 6), 5)
            t.equal(AudioChannel.sum.row(channels: 0), nil)

            t.equal(AudioLevelType.parse("rms"), .rms)
            t.equal(AudioLevelType.parse("BandFreq"), .bandFreq)
            t.equal(AudioLevelType.parse("DEVICELIST"), .deviceList)
            t.equal(AudioLevelType.parse("Level"), nil)
            t.check(AudioLevelType.deviceName.isString && !AudioLevelType.deviceStatus.isString)

            let defaults = AudioLevelParentOptions.read { _ in nil }
            t.equal(defaults.port, .output)
            t.equal(defaults.deviceID, nil)
            t.equal(defaults.analysis, AudioAnalysisSettings())
            let values: [String: String] = [
                "port": "INPUT", "id": " BuiltInMicrophoneDevice ", "rmsattack": "100", "rmsdecay": "(150*2)",
                "rmsgain": "2.5", "peakattack": "0", "peakdecay": "1000", "peakgain": "3", "fftsize": "1023",
                "fftoverlap": "4096", "fftattack": "15", "fftdecay": "250", "bands": "10", "freqmin": "16500",
                "freqmax": "100", "sensitivity": "0",
            ]
            let o = AudioLevelParentOptions.read { values[$0.lowercased()] }
            t.equal(o.port, .input)
            t.equal(o.deviceID, "BuiltInMicrophoneDevice")
            t.equal(o.analysis.rmsAttack, 100)
            t.equal(o.analysis.rmsDecay, 300, "formulas are evaluated")
            t.equal(o.analysis.rmsGain, 2.5)
            t.equal(o.analysis.peakAttack, 0)
            t.equal(o.analysis.peakGain, 3)
            t.equal(o.analysis.fftSize, 1024, "odd sizes round up to even")
            t.equal(o.analysis.fftOverlap, 1023, "overlap stays below the size")
            t.equal(o.analysis.bands, 10)
            t.equal(o.analysis.freqMin, 100, "FreqMin/FreqMax given the wrong way round are swapped")
            t.equal(o.analysis.freqMax, 16500)
            t.equal(o.analysis.sensitivity, 1, "Sensitivity is at least 1 dB")
            let bad = AudioLevelParentOptions.read { ["port": "Loopback", "fftsize": "-5", "bands": "99999",
                                                       "rmsattack": "-3"][$0.lowercased()] }
            t.equal(bad.port, .output)
            t.equal(bad.invalidPort, "Loopback")
            t.equal(bad.analysis.fftSize, 0)
            t.equal(bad.analysis.bands, AudioAnalysisSettings.maxBands)
            t.equal(bad.analysis.rmsAttack, 0)
            var huge = AudioAnalysisSettings()
            huge.fftSize = 10_000_000
            t.equal(huge.normalized().fftSize, AudioAnalysisSettings.maxFFTSize)

            let child = AudioLevelChildOptions.read {
                ["type": "Band", "channel": "R", "bandidx": "3", "fftidx": "(2+2)"][$0.lowercased()]
            }
            t.equal(child.type, .band)
            t.equal(child.channel, .index(1))
            t.equal(child.bandIndex, 3)
            t.equal(child.fftIndex, 4)
            let badChild = AudioLevelChildOptions.read { ["type": "Volume", "channel": "Middle"][$0.lowercased()] }
            t.equal(badChild.type, nil)
            t.equal(badChild.invalidType, "Volume")
            t.equal(badChild.channel, .sum)
            t.equal(badChild.invalidChannel, "Middle")
        }
    }

    // MARK: RMS / Peak

    static func levelTests(_ t: AppTestRunner) {
        t.suite("App: Audio RMS and peak") {
            var s = AudioAnalysisSettings()
            s.rmsAttack = 0
            s.rmsDecay = 0
            s.peakAttack = 0
            s.peakDecay = 0
            let a = AudioAnalyzer(settings: s)
            t.equal(a.rms(.sum), 0, "silent before any audio")
            feed(a, sine(1000, amplitude: 0.5, seconds: 0.1))
            t.close(a.rms(.index(0)), 0.5 / 2.0.squareRoot(), accuracy: 0.01, "RMS of a sine is A/√2")
            t.close(a.rms(.sum), 0.5 / 2.0.squareRoot(), accuracy: 0.01)
            t.close(a.peak(.index(1)), 0.5, accuracy: 0.01)
            t.equal(a.rms(.index(2)), 0, "a stereo stream has no centre channel")
            t.equal(a.format.channels, 2)
            t.equal(a.format.sampleRate, rate)

            // Only the left channel plays: L is loud, R silent, Sum is the average of the mean squares.
            let left = AudioAnalyzer(settings: s)
            feed(left, sine(440, amplitude: 0.8, seconds: 0.1, channel: 0))
            t.close(left.rms(.index(0)), 0.8 / 2.0.squareRoot(), accuracy: 0.01)
            t.close(left.rms(.index(1)), 0, accuracy: 1e-6)
            t.close(left.rms(.sum), (0.32 / 2).squareRoot(), accuracy: 0.01)
            t.close(left.peak(.sum), 0.4, accuracy: 0.01, "Sum peak averages the channels")

            // Gain multiplies, the value is clipped at 1.
            var g = s
            g.rmsGain = 10
            g.peakGain = 0.5
            let gained = AudioAnalyzer(settings: g)
            feed(gained, sine(1000, amplitude: 0.5, seconds: 0.05))
            t.equal(gained.rms(.sum), 1)
            t.close(gained.peak(.sum), 0.25, accuracy: 0.01)

            // Attack: after one time constant the mean square reached 1 − 1/e of the target.
            var slow = AudioAnalysisSettings()
            slow.rmsAttack = 300
            slow.rmsDecay = 300
            let rising = AudioAnalyzer(settings: slow)
            feed(rising, sine(1000, amplitude: 1, seconds: 0.3))
            t.close(rising.rms(.sum), (0.5 * (1 - exp(-1))).squareRoot(), accuracy: 0.02)
            // Decay: silence for one decay time constant keeps 1/e of the mean square.
            feed(rising, sine(1000, amplitude: 1, seconds: 3))
            let before = rising.rms(.sum)
            feed(rising, [Float](repeating: 0, count: Int(0.3 * rate) * 2))
            t.close(rising.rms(.sum), before * exp(-0.5), accuracy: 0.02)

            // Peak default: 50 ms attack, 2.5 s decay.
            let peak = AudioAnalyzer(settings: AudioAnalysisSettings())
            feed(peak, sine(1000, amplitude: 1, seconds: 0.5))
            t.close(peak.peak(.sum), 1, accuracy: 0.02)
            feed(peak, [Float](repeating: 0, count: Int(2.5 * rate) * 2))
            t.close(peak.peak(.sum), exp(-1), accuracy: 0.03, "falls to 1/e in PeakDecay")

            // No audio at all (device stopped): values decay instead of freezing.
            let frozen = AudioAnalyzer(settings: s)
            feed(frozen, sine(1000, amplitude: 1, seconds: 0.05))
            frozen.decay(seconds: 0.5)
            t.equal(frozen.rms(.sum), 0, "zero decay time drops at once")
            let fading = AudioAnalyzer(settings: slow)
            feed(fading, sine(1000, amplitude: 1, seconds: 3))
            let loud = fading.rms(.sum)
            fading.decay(seconds: 0.3)
            t.close(fading.rms(.sum), loud * exp(-0.5), accuracy: 0.02)
            fading.reset()
            t.equal(fading.rms(.sum), 0)
            t.equal(fading.format.channels, 0)

            // Mono (microphones): L, R and C read the only channel.
            let mono = AudioAnalyzer(settings: s)
            feed(mono, sine(200, amplitude: 0.5, seconds: 0.1, channels: 1), channels: 1)
            t.close(mono.rms(.index(1)), 0.5 / 2.0.squareRoot(), accuracy: 0.01)
            t.close(mono.rms(.index(2)), 0.5 / 2.0.squareRoot(), accuracy: 0.01)
            t.equal(mono.rms(.index(3)), 0)

            // Hostile input: NaN / infinite samples do not poison the values.
            let hostile = AudioAnalyzer(settings: s)
            feed(hostile, [Float.nan, .infinity, 0.5, -0.5])
            t.check(hostile.rms(.sum).isFinite && hostile.peak(.sum).isFinite)
            hostile.process([Float](repeating: 0, count: 4), stride: 2, frames: 2, channels: 2, sampleRate: 0)
            hostile.process([Float](repeating: 0, count: 40), stride: 20, frames: 2, channels: 20, sampleRate: rate)
            t.equal(hostile.format.channels, AudioAnalyzer.maxChannels, "at most 8 channels")
        }
    }

    // MARK: FFT

    static func spectrumTests(_ t: AppTestRunner) {
        t.suite("App: Audio FFT") {
            var s = AudioAnalysisSettings()
            s.fftSize = 1024
            s.fftOverlap = 512
            s.fftAttack = 0
            s.fftDecay = 0
            let a = AudioAnalyzer(settings: s)
            a.requestBinValues()
            let binHz = rate / 1024
            // Full-scale sine centred on bin 40: its bin reads 1, the neighbours (Hann leakage, −6 dB) nearly as
            // much, far bins nothing.
            feed(a, sine(binHz * 40, amplitude: 1, seconds: 0.2))
            t.close(a.fft(.sum, index: 40), 1, accuracy: 1e-3)
            t.check(a.fft(.sum, index: 41) > 0.7, "Hann leakage into the next bin: \(a.fft(.sum, index: 41))")
            t.close(a.fft(.sum, index: 200), 0, accuracy: 1e-3)
            t.equal(a.fft(.sum, index: 513), 0, "FFTIdx beyond FFTSize/2")
            t.equal(a.fft(.sum, index: -1), 0)
            t.close(a.fftFrequency(index: 40, sampleRate: 1), binHz * 40, accuracy: 1e-9)
            t.equal(a.fftFrequency(index: 512, sampleRate: 1), rate / 2)
            t.equal(a.fftFrequency(index: 513, sampleRate: 1), 0)

            // dB mapping: amplitude 0.1 is −20 dB; +10 reference, Sensitivity 35 → 1 − 10/35.
            let quiet = AudioAnalyzer(settings: s)
            quiet.requestBinValues()
            feed(quiet, sine(binHz * 40, amplitude: 0.1, seconds: 0.2))
            t.close(quiet.fft(.sum, index: 40), 1 - 10.0 / 35, accuracy: 0.01)
            var sensitive = s
            sensitive.sensitivity = 70
            let wide = AudioAnalyzer(settings: sensitive)
            wide.requestBinValues()
            feed(wide, sine(binHz * 40, amplitude: 0.1, seconds: 0.2))
            t.close(wide.fft(.sum, index: 40), 1 - 10.0 / 70, accuracy: 0.01, "higher Sensitivity shows quieter sound")

            // One channel only: its row and the Sum row (half the power, −3 dB).
            let left = AudioAnalyzer(settings: s)
            left.requestBinValues()
            feed(left, sine(binHz * 40, amplitude: 0.1, seconds: 0.2, channel: 0))
            t.close(left.fft(.index(0), index: 40), 1 - 10.0 / 35, accuracy: 0.01)
            t.close(left.fft(.index(1), index: 40), 0, accuracy: 1e-3)
            t.close(left.fft(.sum, index: 40), 1 - (10.0 + 3.01) / 35, accuracy: 0.01)

            // Smoothing: FFTDecay lets the bin fall with its time constant after the sound stops.
            var smooth = s
            smooth.fftDecay = 500
            let falling = AudioAnalyzer(settings: smooth)
            falling.requestBinValues()
            feed(falling, sine(binHz * 40, amplitude: 1, seconds: 0.2))
            t.close(falling.fft(.sum, index: 40), 1, accuracy: 1e-3)
            feed(falling, [Float](repeating: 0, count: Int(0.5 * rate) * 2))
            // The window empties after 1024 samples (≈21 ms), so the value falls for ≈ 0.48 s of the 0.5 s.
            let after = falling.fft(.sum, index: 40)
            t.check(after > 0.3 && after < 0.45, "FFTDecay 500 ms: \(after)")
            var attack = s
            attack.fftAttack = 1000
            let rising = AudioAnalyzer(settings: attack)
            rising.requestBinValues()
            feed(rising, sine(binHz * 40, amplitude: 1, seconds: 0.1))
            let early = rising.fft(.sum, index: 40)
            t.check(early > 0.03 && early < 0.15, "FFTAttack 1 s: \(early) after 0.1 s")

            // A size vDSP cannot transform directly (1000): zero-padded, then read on the 1000-point grid.
            var odd = s
            odd.fftSize = 1000
            let padded = AudioAnalyzer(settings: odd)
            padded.requestBinValues()
            feed(padded, sine(rate / 1000 * 50, amplitude: 1, seconds: 0.2))
            t.close(padded.fft(.sum, index: 50), 1, accuracy: 0.05)
            t.close(padded.fft(.sum, index: 150), 0, accuracy: 0.05)
            t.close(padded.fftFrequency(index: 50, sampleRate: 1), 2400, accuracy: 1e-9)
            t.equal(AudioMath.supportedDFTSize(atLeast: 1000), 1024)
            t.equal(AudioMath.supportedDFTSize(atLeast: 1500), 1536)
            t.equal(AudioMath.supportedDFTSize(atLeast: 2), 16)

            // Per-bin values are only computed once something reads Type=FFT (bands do not need them).
            let lazy = AudioAnalyzer(settings: s)
            feed(lazy, sine(binHz * 40, amplitude: 1, seconds: 0.05))
            t.equal(lazy.fft(.sum, index: 40), 0, "not computed before the first FFT read")
            feed(lazy, sine(binHz * 40, amplitude: 1, seconds: 0.05))
            t.close(lazy.fft(.sum, index: 40), 1, accuracy: 1e-3, "computed from the next transform on")

            // FFTSize 0: no spectrum, FFT reads 0.
            let off = AudioAnalyzer(settings: AudioAnalysisSettings())
            feed(off, sine(1000, amplitude: 1, seconds: 0.1))
            t.equal(off.fft(.sum, index: 0), 0)
            t.equal(off.band(.sum, index: 0), 0)
            t.equal(off.fftFrequency(index: 1, sampleRate: rate), 0)

            // Overlap: FFTSize 4096 without overlap transforms every 85 ms; with 3/4 overlap every 21 ms.
            var noOverlap = s
            noOverlap.fftSize = 4096
            noOverlap.fftOverlap = 0
            let late = AudioAnalyzer(settings: noOverlap)
            late.requestBinValues()
            feed(late, sine(rate / 4096 * 100, amplitude: 1, seconds: 0.05))
            t.equal(late.fft(.sum, index: 100), 0, "no transform before one hop")
            var overlapped = noOverlap
            overlapped.fftOverlap = 3072
            let soon = AudioAnalyzer(settings: overlapped)
            soon.requestBinValues()
            feed(soon, sine(rate / 4096 * 100, amplitude: 1, seconds: 0.05))
            t.check(soon.fft(.sum, index: 100) > 0, "a hop of 1024 samples already transformed")
        }
    }

    // MARK: Bands

    static func bandTests(_ t: AppTestRunner) {
        t.suite("App: Audio bands") {
            let edges = AudioBandLayout.edges(bands: 10, freqMin: 20, freqMax: 20000)
            t.equal(edges.count, 11)
            t.close(edges[0], 20, accuracy: 1e-9)
            t.close(edges[10], 20000, accuracy: 1e-6)
            t.close(edges[1] / edges[0], edges[7] / edges[6], accuracy: 1e-9, "log spacing")
            t.close(edges[1], 20 * pow(1000, 0.1), accuracy: 1e-9)

            var s = AudioAnalysisSettings()
            s.fftSize = 4096
            s.fftOverlap = 2048
            s.fftAttack = 0
            s.fftDecay = 0
            s.bands = 10
            let a = AudioAnalyzer(settings: s)
            t.close(a.bandFrequency(index: 0), (edges[0] * edges[1]).squareRoot(), accuracy: 1e-9, "geometric centre")
            t.equal(a.bandFrequency(index: 10), 0)
            t.equal(a.bandFrequency(index: -1), 0)

            // A 1 kHz sine lights the band that contains 1 kHz; the others stay (nearly) dark.
            feed(a, sine(1000, amplitude: 0.5, seconds: 0.3))
            let values = (0..<10).map { a.band(.sum, index: $0) }
            let lit = edges.indices.dropLast().first { edges[$0] <= 1000 && 1000 < edges[$0 + 1] } ?? -1
            t.equal(values.firstIndex(of: values.max() ?? 0), lit, "\(values)")
            t.check(values[lit] > 0.9, "sine band \(values[lit])")
            t.check(values[0] < 0.05 && values[9] < 0.05, "far bands \(values)")
            t.equal(a.band(.sum, index: 10), 0, "BandIdx beyond Bands-1")

            // White noise: the power per octave doubles every octave → +3 dB per 1-octave band.
            // (Smoothed over many transforms: a single noise spectrum scatters by about ±1 dB per band.)
            var w = s
            w.freqMin = 250
            w.freqMax = 16000
            w.bands = 6
            w.fftAttack = 1000
            w.fftDecay = 1000
            let white = AudioAnalyzer(settings: w)
            let whiteNoise = noise(amplitude: 0.3, seconds: 6)
            feedLikeEngine(white, whiteNoise)
            let steps = (1..<6).map { white.band(.sum, index: $0) - white.band(.sum, index: $0 - 1) }
            for d in steps { t.close(d, 3.01 / 35, accuracy: 0.02, "white noise slope \(steps)") }
            // The value of a band does not depend on how many bands split the range (per-octave density).
            var fine = w
            fine.bands = 24
            let split = AudioAnalyzer(settings: fine)
            feedLikeEngine(split, whiteNoise)
            let quarterAverage = (8..<12).map { split.band(.sum, index: $0) }.reduce(0, +) / 4
            t.close(quarterAverage, white.band(.sum, index: 2), accuracy: 0.03,
                    "24 bands vs 6 bands over the same octave")

            // Calibration: white noise at about −12 dBFS RMS gives mid-range values, not 0 and not 1.
            let mid = white.band(.sum, index: 3)
            t.check(mid > 0.3 && mid < 0.9, "noise at −12 dBFS maps to \(mid)")

            // Narrow bands below the bin spacing still read (interpolated), without holes.
            var narrow = s
            narrow.fftSize = 1024
            narrow.bands = 81
            narrow.freqMin = 100
            narrow.freqMax = 16500
            let many = AudioAnalyzer(settings: narrow)
            feed(many, noise(amplitude: 0.3, seconds: 0.5))
            let low = (0..<10).map { many.band(.sum, index: $0) }
            t.check(low.allSatisfy { $0 > 0 }, "low narrow bands \(low)")

            // Layout weights: a band covering whole bins weighs them 1 (after normalisation).
            let layout = AudioBandLayout(bands: 1, freqMin: 1000, freqMax: 2000, fftSize: 48, sampleRate: 48000, enbw: 1)
            t.equal(layout.count, 1)
            let total = layout.weights[0].values.reduce(0, +)
            t.close(Double(total), 1000 / 1000 / log2(2.0), accuracy: 1e-5, "∫ over 1 kHz of 1 kHz bins = 1 bin")
            t.equal(AudioBandLayout(bands: 0, freqMin: 20, freqMax: 200, fftSize: 64, sampleRate: 48000, enbw: 1).count, 0)
        }
    }

    // MARK: Ring buffer

    static func ringTests(_ t: AppTestRunner) {
        t.suite("App: Audio ring buffer") {
            let ring = AudioRingBuffer(capacity: 1024)
            t.equal(ring.capacity, 1024)
            let out = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * AudioRingBuffer.stride)
            defer { out.deallocate() }
            var r = ring.read(into: out, maxFrames: 4096)
            t.equal(r.frames, 0)

            // Interleaved list: 1 buffer × 2 channels.
            var interleaved: [Float] = [1, -1, 2, -2, 3, -3]
            interleaved.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                ring.write(&list)
            }
            r = ring.read(into: out, maxFrames: 4096)
            t.equal(r.frames, 3)
            t.equal(r.channels, 2)
            t.equal([out[0], out[1], out[8], out[9], out[16], out[17]], [1, -1, 2, -2, 3, -3])

            // Non-interleaved: 2 buffers × 1 channel; `lastBuffers` keeps the tap's buffers only.
            let listPointer = AudioBufferList.allocate(maximumBuffers: 3)
            defer { free(listPointer.unsafeMutablePointer) }
            var mic: [Float] = [9, 9]
            var l: [Float] = [0.1, 0.2]
            var rr: [Float] = [-0.1, -0.2]
            mic.withUnsafeMutableBytes { m in
                l.withUnsafeMutableBytes { lb in
                    rr.withUnsafeMutableBytes { rb in
                        listPointer[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: m.baseAddress)
                        listPointer[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: lb.baseAddress)
                        listPointer[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: rb.baseAddress)
                        ring.write(listPointer.unsafePointer, lastBuffers: 2)
                    }
                }
            }
            r = ring.read(into: out, maxFrames: 4096)
            t.equal(r.frames, 2)
            t.equal(r.channels, 2)
            t.equal([out[0], out[1], out[8], out[9]], [0.1, -0.1, 0.2, -0.2])

            // Overflow keeps the newest frames; maxFrames keeps the newest too.
            let many: [Float] = (0..<3000).flatMap { [Float($0), Float(0)] }
            many.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 3000, channels: 2) }
            r = ring.read(into: out, maxFrames: 4096)
            t.equal(r.frames, 1024)
            t.equal(out[0], 1976)
            t.equal(out[1023 * AudioRingBuffer.stride], 2999)
            many.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 100, channels: 2) }
            r = ring.read(into: out, maxFrames: 10)
            t.equal(r.frames, 10)
            t.equal(out[0], 90)
            // More than 8 channels: the first 8 are kept.
            let wide = [Float](repeating: 1, count: 12 * 4)
            wide.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 4, channels: 12) }
            t.equal(ring.read(into: out, maxFrames: 100).channels, 8)
            // Empty / malformed lists are ignored.
            var empty = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0,
                                                                                   mData: nil))
            ring.write(&empty)
            t.equal(ring.read(into: out, maxFrames: 100).frames, 0)
            t.equal(ring.droppedSlices, 0)
            // Output silencing.
            var loud: [Float] = [1, 1, 1, 1]
            loud.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                ring.zeroOutput(&list)
            }
            t.equal(loud, [0, 0, 0, 0])
        }
    }

    // MARK: Engine

    final class FakeBackend: AudioCaptureBackend {
        var deviceID: AudioObjectID? = 7
        var running = true
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var ring: AudioRingBuffer?
        private(set) var events: AudioBackendEvents?

        func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
            starts += 1
            self.ring = ring
            self.events = events
            return AudioSourceStatus(running: running, deviceName: "Fake Speakers", deviceUID: "FakeUID",
                                     format: AudioHAL.describe(sampleRate: 48000, bitsPerChannel: 32, isFloat: true,
                                                               channels: 2),
                                     sampleRate: 48000, channels: 2, message: running ? nil : "denied")
        }

        func stop() { stops += 1 }
    }

    static func makeEngine(_ backends: @escaping (AudioSourceKey) -> FakeBackend?) -> AudioCaptureEngine {
        let engine = AudioCaptureEngine()
        engine.isCaptureAllowed = true
        engine.stopDelay = 0
        engine.makeBackend = { backends($0) }
        return engine
    }

    /// Polls (the analysis timer runs on its own queue) until `condition` holds or `timeout` passed. It returns as
    /// soon as the condition holds; the long default only gives a busy CI runner's queues time (restart debounce,
    /// retries on the HAL queue).
    @discardableResult
    static func wait(timeout: TimeInterval = 20, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    static func engineTests(_ t: AppTestRunner) {
        t.suite("App: Audio capture engine") {
            var created: [AudioSourceKey: FakeBackend] = [:]
            let lock = NSLock()
            let engine = makeEngine { key in
                let b = FakeBackend()
                lock.lock(); created[key] = b; lock.unlock()
                return b
            }
            var s = AudioAnalysisSettings()
            s.rmsAttack = 0
            s.rmsDecay = 0
            let a = AudioAnalyzer(settings: s)
            let b = AudioAnalyzer(settings: s)
            let key = AudioSourceKey(kind: .output, deviceID: nil)
            engine.subscribe(a, to: key)
            engine.subscribe(b, to: key)
            engine.drain()
            t.equal(created.count, 1, "one capture for every analyzer of a stream")
            guard let backend = created[key], let ring = backend.ring else {
                t.check(false, "backend started")
                return
            }
            t.equal(backend.starts, 1)
            t.equal(engine.status(for: key).deviceName, "Fake Speakers")
            t.check(engine.status(for: key).running)

            // Audio written by the "real-time thread" reaches both analyzers through the analysis timer. It keeps
            // arriving while the test waits: with zero decay one late look (a busy main thread) could otherwise land
            // after the silence timeout had already put the values back to 0.
            let signal = sine(1000, amplitude: 0.5, seconds: 0.05)
            t.check(wait {
                signal.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: signal.count / 2,
                                                            channels: 2) }
                return a.rms(.sum) > 0.3 && b.rms(.sum) > 0.3
            }, "analyzers fed: \(a.rms(.sum))")
            // Silence timeout: no frames → the analyzers decay (to 0 with zero decay time).
            t.check(wait { a.rms(.sum) == 0 }, "decays without audio")

            // A second stream (input) gets its own capture.
            let micKey = AudioSourceKey(kind: .input, deviceID: "Mic")
            let c = AudioAnalyzer(settings: s)
            engine.subscribe(c, to: micKey)
            engine.drain()
            t.equal(created.count, 2)

            // Restart request (device change): stop, then a fresh backend after the debounce.
            func current() -> FakeBackend? {
                lock.lock(); defer { lock.unlock() }
                return created[key]
            }
            backend.events?.restart()
            t.check(wait { backend.stops == 1 && current() !== backend }, "restarted")
            guard let second = current() else { return }
            t.equal(second.starts, 1)
            second.events?.restart()
            second.events?.restart()
            t.check(wait { second.stops == 1 }, "a burst of restart requests restarts once")
            engine.drain()
            guard let third = current() else { return }
            t.check(third !== second)
            // A stale backend's late status is ignored.
            second.events?.status(AudioSourceStatus(running: true, deviceName: "Old"))
            engine.drain()
            t.equal(engine.status(for: key).deviceName, "Fake Speakers")

            // Last subscriber gone: the source stops (stopDelay 0 in tests) and forgets its status.
            engine.unsubscribe(a)
            engine.drain()
            t.equal(third.stops, 0, "still one subscriber")
            engine.unsubscribe(b)
            engine.drain()
            engine.drain()
            t.equal(third.stops, 1)
            t.equal(engine.status(for: key).running, false)
            t.equal(engine.activeSourceKeys(), [micKey])
            engine.unsubscribe(c)
            engine.drain()
            engine.drain()
            t.equal(engine.activeSourceKeys().count, 0)

            // Capture not allowed (command-line modes): no backend, a status message.
            let off = makeEngine { _ in FakeBackend() }
            off.isCaptureAllowed = false
            off.subscribe(AudioAnalyzer(settings: s), to: key)
            off.drain()
            t.equal(off.status(for: key).running, false)
            t.check(off.status(for: key).message?.contains("command-line") == true)
            t.check(!AudioCaptureEngine.captureAllowed, "--self-test never captures")

            // A backend that cannot run (permission denied) reports it; no analysis timer runs. The next subscriber
            // (a skin loading or refreshing) retries — here the "permission" has been granted meanwhile.
            var allow = false
            var attempts = 0
            let denied = makeEngine { _ in
                let f = FakeBackend()
                lock.lock(); f.running = allow; attempts += 1; lock.unlock()
                return f
            }
            let d = AudioAnalyzer(settings: s)
            denied.subscribe(d, to: key)
            denied.drain()
            t.equal(denied.status(for: key).message, "denied")
            t.equal(denied.status(for: key).running, false)
            lock.lock(); allow = true; lock.unlock()
            let retry = AudioAnalyzer(settings: s)
            denied.subscribe(retry, to: key)
            t.check(wait { denied.status(for: key).running }, "retried after the refusal")
            t.equal(attempts, 2)
            denied.unsubscribe(d)
            denied.unsubscribe(retry)
            denied.drain()
        }
    }

    // MARK: AudioLevel measure

    /// A loaded skin from `ini` (in a temporary Skins folder) with a render host.
    static func makeSkin(_ t: AppTestRunner, _ ini: String, config: String = "AudioTest") throws -> Skin {
        let root = t.temporaryDirectory("audio")
        let dir = root.appendingPathComponent(config, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Test.ini")
        try ini.write(to: file, atomically: true, encoding: .utf8)
        let skin = Skin(config: config, fileURL: file, skinsDirectory: root, system: SystemMonitor.shared,
                        host: host)
        try skin.load()
        return skin
    }

    static let host = RenderHost()

    static func fakeSnapshot() -> AudioSystemSnapshot {
        var s = AudioSystemSnapshot()
        s.loaded = true
        s.devices = [
            AudioDeviceInfo(id: 10, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", inputChannels: 0,
                            outputChannels: 2, sampleRate: 48000, canBeDefaultOutput: true, canBeDefaultInput: false),
            AudioDeviceInfo(id: 11, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", inputChannels: 1,
                            outputChannels: 0, sampleRate: 48000, canBeDefaultOutput: false, canBeDefaultInput: true),
            AudioDeviceInfo(id: 12, uid: "USB-DAC-1", name: "USB DAC", inputChannels: 0, outputChannels: 2,
                            sampleRate: 44100, canBeDefaultOutput: true, canBeDefaultInput: false),
            AudioDeviceInfo(id: 13, uid: "Hidden-Agg", name: "Aggregate", inputChannels: 2, outputChannels: 2,
                            sampleRate: 48000, canBeDefaultOutput: false, canBeDefaultInput: false),
        ]
        s.defaultOutput = 10
        s.defaultInput = 11
        s.output = AudioOutputState(deviceID: 10, name: "MacBook Pro Speakers", volume: 0.5, muted: false,
                                    canSetVolume: true, canMute: true)
        return s
    }

    static func measureTests(_ t: AppTestRunner) {
        t.suite("App: Audio AudioLevel measure") {
            let ini = """
            [Rainmeter]
            Update=25

            [Variables]
            ChildType=RMS

            [MeasureAudio]
            Measure=Plugin
            Plugin=AudioLevel
            Port=Output
            RMSAttack=0
            RMSDecay=3600000
            PeakAttack=0
            PeakDecay=3600000
            FFTSize=1024
            FFTOverlap=512
            FFTAttack=0
            FFTDecay=3600000
            Bands=8
            FreqMin=50
            FreqMax=12800

            [MeasureLeft]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Channel=L
            Type=#ChildType#
            DynamicVariables=1

            [MeasureBand]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=Band
            BandIdx=4

            [MeasureBandFreq]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=BandFreq
            BandIdx=0

            [MeasureFFTFreq]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=FFTFreq
            FFTIdx=512

            [MeasureName]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=DeviceName

            [MeasureID]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=DeviceID

            [MeasureList]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=DeviceList

            [MeasureStatus]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=DeviceStatus

            [MeasureFormat]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureAudio
            Type=Format

            [MeasureOrphan]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=NoSuchMeasure
            Type=RMS

            [MeasureGrandchild]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureLeft
            Type=RMS

            [MeasureMic]
            Measure=Plugin
            Plugin=AudioLevel
            Port=Input
            ID=MacBook Pro Microphone
            Type=DeviceName

            [MeasureMicList]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=MeasureMic
            Type=DeviceList

            [MeterText]
            Meter=String
            MeasureName=MeasureLeft
            """
            let skin = try makeSkin(t, ini)
            withExtendedLifetime(skin) {
                var backends: [AudioSourceKey: FakeBackend] = [:]
                let lock = NSLock()
                let engine = makeEngine { key in
                    let b = FakeBackend()
                    lock.lock(); backends[key] = b; lock.unlock()
                    return b
                }
                var measures: [String: AudioLevelMeasure] = [:]
                let names = ["MeasureAudio", "MeasureLeft", "MeasureBand", "MeasureBandFreq", "MeasureFFTFreq",
                             "MeasureName", "MeasureID", "MeasureList", "MeasureStatus", "MeasureFormat",
                             "MeasureOrphan", "MeasureGrandchild", "MeasureMic", "MeasureMicList"]
                for n in names {
                    guard let section = skin.document.section(named: n) else { continue }
                    let m = AudioLevelMeasure(name: n, section: section, skin: skin, type: "audiolevel")
                    m.engine = engine
                    m.system = { fakeSnapshot() }
                    m.prepareSystem = {}
                    m.mayCapture = { _ in true }
                    m.parentLookup = { measures[$0.lowercased()] }
                    measures[n.lowercased()] = m
                }
                for n in names { measures[n.lowercased()]?.readOptions() }
                engine.drain()
                func m(_ n: String) -> AudioLevelMeasure { measures[n.lowercased()]! }

                t.equal(backends.count, 0, "reading the options captures nothing")
                // The parents' first update subscribes them.
                _ = m("MeasureAudio").computeValue()
                _ = m("MeasureMic").computeValue()
                engine.drain()
                t.equal(backends.count, 2, "two parents (output and input) → two captures")
                t.equal(m("MeasureAudio").parentOptions?.analysis.bands, 8)
                t.check(m("MeasureLeft").parentOptions == nil, "a child has no parent options")
                t.equal(m("MeasureAudio").computeValue(), 0, "a parent without Type reads 0")

                // Audio arrives through the parent's capture (left channel loud), so only the analysis thread touches
                // its analyzer. The longest decay time (with attack 0) holds the values through the silence that
                // follows, however late the checks below run.
                t.check(m("MeasureAudio").analyzer != nil, "parent has an analyzer")
                lock.lock()
                let ring = m("MeasureAudio").parentOptions.flatMap { backends[$0.sourceKey]?.ring }
                lock.unlock()
                guard let ring else {
                    t.check(false, "the parent's capture started")
                    return
                }
                let signal = sine(1000, amplitude: 0.5, seconds: 0.2, channel: 0)
                var dropped = -1
                t.check(wait {
                    // A write that meets the analysis thread's read is dropped (the real-time writer never waits).
                    if ring.droppedSlices != dropped {
                        dropped = ring.droppedSlices
                        signal.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!,
                                                                    frames: signal.count / 2, channels: 2) }
                    }
                    return abs(m("MeasureLeft").computeValue() - 0.5 / 2.0.squareRoot()) < 0.01
                }, "fed: \(m("MeasureLeft").computeValue())")
                // Type follows a variable (DynamicVariables=1): Peak now.
                skin.setVariable("ChildType", "Peak")
                m("MeasureLeft").readOptions()
                t.equal(m("MeasureLeft").child.type, .peak)
                t.close(m("MeasureLeft").computeValue(), 0.5, accuracy: 0.01)
                // Bands: 8 octave bands 50…12800 Hz; 1 kHz lies in band 4 (800–1600 Hz).
                t.check(m("MeasureBand").computeValue() > 0.5, "band 4 lit")
                t.close(m("MeasureBandFreq").computeValue(), (50 * 100).squareRoot(), accuracy: 1e-6)
                t.close(m("MeasureFFTFreq").computeValue(), 24000, accuracy: 1e-6, "Nyquist of the stream")
                t.close(m("MeasureFFTFreq").automaticMaxValue, 24000, accuracy: 1e-6)

                // Device strings: from the capture status (fake backend) when it runs.
                t.equal(m("MeasureName").computeValue(), 0)
                t.equal(m("MeasureName").pluginString, "Fake Speakers")
                _ = m("MeasureID").computeValue()
                t.equal(m("MeasureID").pluginString, "FakeUID")
                t.equal(m("MeasureStatus").computeValue(), 1)
                _ = m("MeasureFormat").computeValue()
                t.equal(m("MeasureFormat").pluginString, "48000 Hz, 32-bit float, 2 channels")
                _ = m("MeasureList").computeValue()
                t.equal(m("MeasureList").pluginString,
                        "BuiltInSpeakerDevice: MacBook Pro Speakers\nUSB-DAC-1: USB DAC",
                        "output devices only, UID: Name per line")
                _ = m("MeasureMicList").computeValue()
                t.equal(m("MeasureMicList").pluginString, "BuiltInMicrophoneDevice: MacBook Pro Microphone")
                t.equal(m("MeasureMic").parentOptions?.port, .input)
                t.equal(m("MeasureMic").parentOptions?.deviceID, "MacBook Pro Microphone")
                _ = m("MeasureMic").computeValue()
                t.equal(m("MeasureMic").pluginString, "Fake Speakers", "a parent with Type answers itself")

                // Broken wiring reads 0 and does not crash.
                t.equal(m("MeasureOrphan").computeValue(), 0)
                t.equal(m("MeasureGrandchild").computeValue(), 0)

                // Without a running capture the device facts come from the device list.
                let offline = AudioLevelMeasure(name: "MeasureName", section: skin.document.section(named: "MeasureName")!,
                                                skin: skin, type: "audiolevel")
                offline.system = { fakeSnapshot() }
                offline.parentLookup = { n in
                    n.caseInsensitiveCompare("MeasureAudio") == .orderedSame ? measures["measureaudio"] : nil
                }
                let silentEngine = makeEngine { _ in nil }
                m("MeasureAudio").engine = silentEngine
                offline.engine = silentEngine
                offline.readOptions()
                _ = offline.computeValue()
                t.equal(offline.pluginString, "MacBook Pro Speakers")
                m("MeasureAudio").engine = engine

                // Releasing the measures unsubscribes: the captures stop.
                measures = [:]
                engine.drain()
                engine.drain()
                t.equal(backends.values.map(\.stops).reduce(0, +), 2)

                // Device matching for ID=.
                let snap = fakeSnapshot()
                t.equal(AudioLevelMeasure.device(for: AudioSourceKey(kind: .output, deviceID: "USB-DAC-1"), in: snap)?.id, 12)
                t.equal(AudioLevelMeasure.device(for: AudioSourceKey(kind: .output, deviceID: "usb dac"), in: snap)?.id, 12)
                t.equal(AudioLevelMeasure.device(
                    for: AudioSourceKey(kind: .output, deviceID: "{0.0.0.00000000}.{5c106e65-26b4-4d05-a9bf-b207a71e9eaa}"),
                    in: snap)?.id, 10, "a Windows ID falls back to the default output")
                t.equal(AudioLevelMeasure.device(for: AudioSourceKey(kind: .input, deviceID: nil), in: snap)?.id, 11)
                t.equal(AudioLevelMeasure.deviceList([]), "")
                t.equal(AudioHAL.describe(sampleRate: 44100, bitsPerChannel: 24, isFloat: false, channels: 1),
                        "44100 Hz, 24-bit integer, 1 channel")
                t.equal(AudioHAL.describe(sampleRate: 0, bitsPerChannel: 32, isFloat: true, channels: 2), "")
            }
        }
    }

    // MARK: Which skins capture

    static func captureScopeTests(_ t: AppTestRunner) {
        t.suite("App: Audio captures only in skin windows") {
            // Every skin here listens to a microphone of its own that nobody else uses, so the suite can see whether
            // that skin subscribed the shared engine (which never starts a backend in --self-test: `captureAllowed`).
            func microphone() -> (id: String, key: AudioSourceKey) {
                let id = "DesksetTestMic-\(UUID().uuidString)"
                return (id, AudioSourceKey(kind: .input, deviceID: id))
            }
            func subscribed(_ key: AudioSourceKey) -> Bool {
                AudioCaptureEngine.shared.activeSourceKeys().contains(key)
            }
            func write(_ id: String, config: String, in skins: URL) throws -> URL {
                let dir = skins.appendingPathComponent(config, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("Meter.ini")
                let ini = "[Rainmeter]\nUpdate=1000\n[MeasureAudio]\nMeasure=Plugin\nPlugin=AudioLevel\nPort=Input\n"
                    + "ID=\(id)\n[MeasureLevel]\nMeasure=Plugin\nPlugin=AudioLevel\nParent=MeasureAudio\nType=RMS\n"
                    + "[MeterLevel]\nMeter=Bar\nMeasureName=MeasureLevel\nW=10\nH=40\n"
                try ini.write(to: file, atomically: true, encoding: .utf8)
                return file
            }
            let root = t.temporaryDirectory("audio-scope")

            // The Manage window lists the compatibility notes of a skin that is not loaded: reading it records nothing.
            let checked = microphone()
            let checkedFile = try write(checked.id, config: "Checked", in: root)
            t.equal(ManageModel.dryRunIssues(config: "Checked", fileURL: checkedFile, skinsDirectory: root), [])
            t.check(!subscribed(checked.key), "the Manage window's check starts no capture")

            // A render has no skin window: its updates subscribe only to the demo signal.
            let rendered = microphone()
            let renderedFile = try write(rendered.id, config: "Rendered", in: root)
            let host = RenderHost()
            let render = Skin(config: "Rendered", fileURL: renderedFile, skinsDirectory: root,
                              system: SystemMonitor.shared, host: host)
            try render.load()
            render.update()
            render.update()
            t.equal(subscribed(rendered.key), AudioCaptureEngine.demoSignal, "a render captures only the demo signal")
            if !AudioCaptureEngine.demoSignal {
                t.check(host.logs.contains { $0.contains("no capture outside a skin window") }, "\(host.logs)")
            }
            t.check(!AudioPlugins.mayCapture(for: render, demo: false), "no skin window")
            t.check(AudioPlugins.mayCapture(for: render, demo: true), "the demo signal records nothing")

            // A skin window: loading reads the parent's options and captures nothing; the first update subscribes.
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let shown = microphone()
            _ = try write(shown.id, config: "Shown", in: app.skinsDirectory)
            let c = try SkinController(config: "Shown", file: "Meter.ini", app: app)
            guard let parent = c.skin.measure(named: "MeasureAudio") as? AudioLevelMeasure else {
                t.check(false, "AudioLevel parent")
                return
            }
            t.check(AudioPlugins.mayCapture(for: c.skin, demo: false), "a skin window may capture")
            t.check(parent.parentOptions != nil, "the options are read when the skin loads")
            t.check(!parent.subscribed && !subscribed(shown.key), "loading a skin window starts no capture")
            // A fake engine from here on (the shared one would really capture with DESKSET_AUDIO_CAPTURE=1).
            var backends: [AudioSourceKey: FakeBackend] = [:]
            let lock = NSLock()
            let engine = makeEngine { key in
                let b = FakeBackend()
                lock.lock(); backends[key] = b; lock.unlock()
                return b
            }
            parent.engine = engine
            parent.prepareSystem = {}
            c.start(fadeIn: false)
            engine.drain()
            t.check(parent.subscribed, "the first update of a skin window subscribes")
            t.equal(backends[shown.key]?.starts, 1, "and the capture starts")
            c.skin.update()
            engine.drain()
            t.equal(backends.count, 1, "once")
            c.stop()

            // AppVolume taps an app for its peak only in a skin window too.
            let peakSkin = try makeSkin(t, "[Apps]\nMeasure=Plugin\nPlugin=AppVolume\n[Peak]\nMeasure=Plugin\n"
                                        + "Plugin=AppVolume\nParent=Apps\nAppName=Spotify\nNumberType=Peak\n")
            guard let appsSection = peakSkin.document.section(named: "Apps"),
                  let peakSection = peakSkin.document.section(named: "Peak") else { return }
            let apps = AppVolumeMeasure(name: "Apps", section: appsSection, skin: peakSkin, type: "appvolume")
            let peak = AppVolumeMeasure(name: "Peak", section: peakSection, skin: peakSkin, type: "appvolume")
            let spotify = AudioApp(pid: 4242, fileName: "Spotify", filePath: "", bundleID: "com.spotify.client",
                                   isRegularApp: true, isPlaying: true)
            peak.parentLookup = { [weak apps] _ in apps }
            for m in [apps, peak] {
                m.catalog = { [spotify] }
                m.engine = engine
                m.readOptions()
            }
            let tap = AudioSourceKey(kind: .process(4242), deviceID: nil)
            t.equal(peak.computeValue(), 0)
            engine.drain()
            t.check(backends[tap] == nil, "no tap outside a skin window")
            peak.mayCapture = { _ in true }
            _ = peak.computeValue()
            engine.drain()
            t.equal(backends[tap]?.starts, 1, "a skin window taps the app")
            withExtendedLifetime(apps) {}
        }
    }

    // MARK: Win7Audio

    final class FakeOutput: AudioOutputControlling {
        var state = fakeSnapshot()
        var calls: [String] = []

        func snapshot() -> AudioSystemSnapshot { state }
        func setOutputVolume(_ volume: Double) {
            calls.append("volume \(volume)")
            state.output.volume = volume
            state.output.muted = false
        }
        func setOutputMuted(_ muted: Bool) {
            calls.append("mute \(muted)")
            state.output.muted = muted
        }
        func setDefaultOutput(_ device: AudioObjectID) {
            calls.append("device \(device)")
            state.defaultOutput = device
            state.output.deviceID = device
            state.output.name = state.device(device)?.name ?? ""
        }
    }

    static func win7AudioTests(_ t: AppTestRunner) {
        t.suite("App: Audio Win7Audio") {
            t.equal(Win7AudioCommand.parse("ToggleNext"), .toggleNext)
            t.equal(Win7AudioCommand.parse("  togglePREVIOUS "), .togglePrevious)
            t.equal(Win7AudioCommand.parse("SetOutputIndex 2"), .setOutputIndex(2))
            t.equal(Win7AudioCommand.parse("ToggleMute"), .toggleMute)
            t.equal(Win7AudioCommand.parse("Mute"), .mute)
            t.equal(Win7AudioCommand.parse("Unmute"), .unmute)
            t.equal(Win7AudioCommand.parse("SetVolume 50"), .setVolume(50))
            t.equal(Win7AudioCommand.parse("ChangeVolume +5"), .changeVolume(5))
            t.equal(Win7AudioCommand.parse("ChangeVolume -10"), .changeVolume(-10))
            t.equal(Win7AudioCommand.parse("ChangeVolume (2*5)"), .changeVolume(10))
            t.equal(Win7AudioCommand.parse("SetVolume"), nil, "a number is required")
            t.equal(Win7AudioCommand.parse("SetVolume loud"), nil)
            t.equal(Win7AudioCommand.parse("Louder"), nil)
            t.equal(Win7AudioCommand.parse(""), nil)

            var s = fakeSnapshot()
            t.equal(Win7AudioMeasure.values(s).number, 50)
            t.equal(Win7AudioMeasure.values(s).text, "MacBook Pro Speakers")
            s.output.volume = 0.4375
            t.equal(Win7AudioMeasure.values(s).number, 44, "whole percent")
            s.output.muted = true
            t.equal(Win7AudioMeasure.values(s).number, -1, "muted reads -1 (skins test < 0)")
            s.output.muted = false
            s.output.volume = nil
            t.equal(Win7AudioMeasure.values(s).number, 100, "no volume control: full level")
            s.output = AudioOutputState()
            t.equal(Win7AudioMeasure.values(s).text, "ERROR - Getting Default Device")
            t.equal(Win7AudioMeasure.values(AudioSystemSnapshot()).text, "", "not read yet")

            let fake = FakeOutput()
            func run(_ command: String) -> String? { Win7AudioCommand.parse(command)?.apply(to: fake) }
            t.equal(run("SetVolume 80"), nil)
            t.close(fake.state.output.volume ?? -1, 0.8)
            t.equal(run("ChangeVolume +10"), nil)
            t.close(fake.state.output.volume ?? -1, 0.9)
            _ = run("ChangeVolume 50")
            t.close(fake.state.output.volume ?? -1, 1, accuracy: 1e-9, "clamped at 100")
            _ = run("ChangeVolume -250")
            t.close(fake.state.output.volume ?? -1, 0, accuracy: 1e-9, "clamped at 0")
            _ = run("SetVolume 150")
            t.close(fake.state.output.volume ?? -1, 1, accuracy: 1e-9)
            _ = run("ToggleMute")
            t.check(fake.state.output.muted)
            _ = run("ChangeVolume -10")
            t.check(!fake.state.output.muted, "ChangeVolume unmutes (through setOutputVolume)")
            _ = run("Mute")
            _ = run("Mute")
            t.check(fake.state.output.muted)
            _ = run("Unmute")
            t.check(!fake.state.output.muted)

            // Devices: outputs are 10 (default) and 12; ToggleNext / TogglePrevious wrap.
            _ = run("ToggleNext")
            t.equal(fake.state.defaultOutput, 12)
            _ = run("ToggleNext")
            t.equal(fake.state.defaultOutput, 10, "wraps to the first")
            _ = run("TogglePrevious")
            t.equal(fake.state.defaultOutput, 12, "wraps to the last")
            _ = run("SetOutputIndex 1")
            t.equal(fake.state.defaultOutput, 10)
            t.check(run("SetOutputIndex 3")?.contains("2 output devices") == true, "out of range is refused")
            t.check(run("SetOutputIndex 0") != nil)
            t.equal(fake.state.defaultOutput, 10)

            // A device without volume control refuses volume commands but reads 100.
            fake.state.output.canSetVolume = false
            fake.state.output.canMute = false
            fake.state.output.volume = nil
            t.check(run("SetVolume 20") != nil)
            t.check(run("ToggleMute") != nil)
            fake.state.output.deviceID = nil
            t.check(run("Mute") != nil)
            fake.state.devices = []
            t.check(run("ToggleNext") != nil)

            // The measure: number, string (via pluginString) and commands.
            let skin = try makeSkin(t, "[W]\nMeasure=Plugin\nPlugin=Win7AudioPlugin\n")
            withExtendedLifetime(skin) {
                let w = Win7AudioMeasure(name: "W", section: skin.document.section(named: "W")!, skin: skin,
                                         type: "win7audioplugin")
                let controller = FakeOutput()
                w.system = controller
                w.readOptions()
                t.equal(w.computeValue(), 50)
                t.equal(w.pluginString, "MacBook Pro Speakers")
                t.equal(w.automaticMaxValue, 100)
                w.execute(command: "ChangeVolume -20")
                t.equal(w.computeValue(), 30)
                w.execute(command: "ToggleMute")
                t.equal(w.computeValue(), -1)
                w.execute(command: "Nonsense 3")
                t.equal(controller.calls, ["volume 0.3", "mute true"], "unknown commands do nothing")
            }
        }
    }

    // MARK: AudioSystem (fake HAL)

    /// A HAL with two outputs — speakers (10) with volume and mute controls, a USB DAC (12) with a volume control
    /// only — and a microphone (11). Written from the HAL queue, read from the test thread.
    final class FakeSystemHAL: AudioSystemHAL {
        private let lock = NSLock()
        private var _defaultOutput: AudioObjectID? = 10
        private var volumes: [AudioObjectID: Double] = [10: 0.4, 12: 0.7]
        private var mutes: [AudioObjectID: Bool] = [10: false]
        private var _writes: [String] = []
        /// Emulates the time the real first read of the devices takes.
        var readDelay: TimeInterval = 0

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var defaultOutput: AudioObjectID? { locked { _defaultOutput } }
        var writes: [String] { locked { _writes } }
        func volumeValue(_ d: AudioObjectID) -> Double? { locked { volumes[d] } }
        func mutedValue(_ d: AudioObjectID) -> Bool? { locked { mutes[d] } }
        func setHardwareMute(_ d: AudioObjectID, _ m: Bool) { locked { mutes[d] = m } }

        func devices() -> [AudioDeviceInfo] {
            if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
            return fakeSnapshot().devices
        }
        func defaultDevice(input: Bool) -> AudioObjectID? { input ? 11 : defaultOutput }
        func name(of device: AudioObjectID) -> String? { fakeSnapshot().device(device)?.name }
        func volume(of device: AudioObjectID) -> Double? { volumeValue(device) }
        func isMuted(_ device: AudioObjectID) -> Bool? { mutedValue(device) }
        func hasSettableVolume(_ device: AudioObjectID) -> Bool { volumeValue(device) != nil }
        func hasSettableMute(_ device: AudioObjectID) -> Bool { mutedValue(device) != nil }
        func setVolume(_ device: AudioObjectID, _ value: Double) {
            locked {
                volumes[device] = value
                _writes.append("volume \(device) \(value)")
            }
        }
        func setMute(_ device: AudioObjectID, _ muted: Bool) {
            locked {
                mutes[device] = muted
                _writes.append("mute \(device) \(muted)")
            }
        }
        func setDefaultOutputDevice(_ device: AudioObjectID) -> OSStatus {
            locked {
                _defaultOutput = device
                _writes.append("device \(device)")
            }
            return noErr
        }
        func listenToSystem(_ handler: @escaping () -> Void) -> [AudioListenerToken] { [] }
        func listenToOutput(_ device: AudioObjectID, _ handler: @escaping () -> Void) -> [AudioListenerToken] { [] }
    }

    /// Waits for the HAL queue twice: commands issued from HAL-queue work are carried out too.
    static func drainHAL() {
        AudioHAL.queue.sync {}
        AudioHAL.queue.sync {}
    }

    static func outputControlTests(_ t: AppTestRunner) {
        t.suite("App: Audio output control") {
            // The first reader waits for the first read of the devices (about 60 ms on a real Mac), so a volume
            // skin's first update already shows the device and its volume. The app waits at most 0.2 s; this system
            // up to 10 s, so a busy CI runner's late HAL queue still makes it (a reader that did not wait would find
            // nothing loaded).
            t.equal(AudioSystem.firstReadWait, 0.2)
            drainHAL()
            let slowHAL = FakeSystemHAL()
            slowHAL.readDelay = 0.06
            let slow = AudioSystem(hal: slowHAL, firstReadWait: 10)
            let first = Win7AudioMeasure.values(slow.snapshot())
            t.equal(first.number, 40, "first read waited for")
            t.equal(first.text, "MacBook Pro Speakers")
            drainHAL()

            let hal = FakeSystemHAL()
            let system = AudioSystem(hal: hal)
            system.activateIfNeeded(wait: 5)
            t.close(system.snapshot().output.volume ?? -1, 0.4)

            // A re-read of the device (volume listener, the once-a-second refresh) that was queued before a command's
            // write must not put the old volume back: a second scroll step in that moment would be computed from it.
            let gate = DispatchSemaphore(value: 0)
            AudioHAL.queue.async { gate.wait() }
            system.scheduleOutputRefresh()
            var seen: Double?
            AudioHAL.queue.async {
                seen = system.snapshot().output.volume
                _ = Win7AudioCommand.changeVolume(5).apply(to: system)
            }
            _ = Win7AudioCommand.changeVolume(5).apply(to: system)
            gate.signal()
            drainHAL()
            t.close(seen ?? -1, 0.45, accuracy: 1e-9, "the cache keeps the command's value while its write is queued")
            t.close(hal.volumeValue(10) ?? -1, 0.5, accuracy: 1e-9, "both steps reach the device")
            t.close(system.snapshot().output.volume ?? -1, 0.5, accuracy: 1e-9)

            // The same for switching the output device (ToggleNext twice quickly must not stay on one device).
            AudioHAL.queue.async { gate.wait() }
            system.scheduleOutputRefresh()
            var seenDevice: AudioObjectID?
            AudioHAL.queue.async { seenDevice = system.snapshot().defaultOutput }
            _ = Win7AudioCommand.toggleNext.apply(to: system)
            gate.signal()
            drainHAL()
            t.equal(seenDevice, 12)
            t.equal(hal.defaultOutput, 12)
            t.equal(system.snapshot().output.name, "USB DAC")
            t.close(system.snapshot().output.volume ?? -1, 0.7, accuracy: 1e-9, "the new device's own volume")

            // A device without a mute control (the DAC) is muted by volume: the device goes to 0, skins read -1 and
            // still see the volume to come back to.
            _ = Win7AudioCommand.mute.apply(to: system)
            drainHAL()
            t.equal(hal.volumeValue(12), 0)
            t.check(system.snapshot().output.muted)
            t.close(system.snapshot().output.volume ?? -1, 0.7, accuracy: 1e-9)
            t.equal(Win7AudioMeasure.values(system.snapshot()).number, -1)
            // ChangeVolume "disables mute" and counts from the volume before the mute.
            _ = Win7AudioCommand.changeVolume(-10).apply(to: system)
            drainHAL()
            t.close(hal.volumeValue(12) ?? -1, 0.6, accuracy: 1e-9)
            t.check(!system.snapshot().output.muted)
            _ = Win7AudioCommand.toggleMute.apply(to: system)
            drainHAL()
            _ = Win7AudioCommand.toggleMute.apply(to: system)
            drainHAL()
            t.close(hal.volumeValue(12) ?? -1, 0.6, accuracy: 1e-9, "unmute restores the volume")
            // Muted by volume, then the output changes: the DAC gets its volume back.
            _ = Win7AudioCommand.mute.apply(to: system)
            drainHAL()
            _ = Win7AudioCommand.toggleNext.apply(to: system)
            drainHAL()
            t.equal(hal.defaultOutput, 10)
            t.close(hal.volumeValue(12) ?? -1, 0.6, accuracy: 1e-9, "left device restored")
            t.check(!system.snapshot().output.muted)

            // Hardware mute (the speakers): SetVolume "disables mute".
            hal.setHardwareMute(10, true)
            system.scheduleOutputRefresh()
            drainHAL()
            t.equal(Win7AudioMeasure.values(system.snapshot()).number, -1)
            _ = Win7AudioCommand.setVolume(30).apply(to: system)
            t.equal(Win7AudioMeasure.values(system.snapshot()).number, 30, "the cache shows the command at once")
            drainHAL()
            t.equal(hal.mutedValue(10), false)
            t.close(hal.volumeValue(10) ?? -1, 0.3, accuracy: 1e-9)
            t.equal(Win7AudioMeasure.values(system.snapshot()).number, 30)
        }
    }

    static func tapAggregateTests(_ t: AppTestRunner) {
        t.suite("App: Audio tap aggregate device") {
            guard #available(macOS 14.2, *) else {
                print("    (skipped: process taps need macOS 14.2)")
                return
            }
            // An output-only device clocks the aggregate as its main sub-device.
            let usual = ProcessTapBackend.aggregateDescription(outputUID: "BuiltInSpeakerDevice", tapUUID: "TAP",
                                                               includeOutputDevice: true)
            t.equal(usual[kAudioAggregateDeviceMainSubDeviceKey] as? String, "BuiltInSpeakerDevice")
            t.equal((usual[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])?.first?[kAudioSubDeviceUIDKey]
                        as? String, "BuiltInSpeakerDevice")
            // A device with inputs (USB interface, headset, BlackHole) stays out: the aggregate holds only the tap.
            let tapOnly = ProcessTapBackend.aggregateDescription(outputUID: "BlackHole2ch_UID", tapUUID: "TAP",
                                                                 includeOutputDevice: false)
            t.check(tapOnly[kAudioAggregateDeviceMainSubDeviceKey] == nil)
            t.check(tapOnly[kAudioAggregateDeviceSubDeviceListKey] == nil)
            for d in [usual, tapOnly] {
                t.equal((d[kAudioAggregateDeviceTapListKey] as? [[String: Any]])?.first?[kAudioSubTapUIDKey] as? String,
                        "TAP")
                t.equal(d[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
                t.check((d[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix(AudioHAL.ownDevicePrefix) == true,
                        "Deskset's own device (hidden from device lists)")
            }
        }
    }

    // MARK: AppVolume

    static func appVolumeTests(_ t: AppTestRunner) {
        t.suite("App: Audio AppVolume") {
            let apps = [
                AudioApp(pid: 100, fileName: "Spotify", filePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
                         bundleID: "com.spotify.client", isRegularApp: true, isPlaying: true),
                AudioApp(pid: 101, fileName: "systemsoundserverd", filePath: "/usr/libexec/systemsoundserverd",
                         bundleID: "", isRegularApp: false, isPlaying: true),
                AudioApp(pid: 102, fileName: "Safari", filePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                         bundleID: "com.apple.Safari", isRegularApp: true, isPlaying: false),
                AudioApp(pid: 103, fileName: "coreaudiod-helper", filePath: "", bundleID: "", isRegularApp: false,
                         isPlaying: false),
            ]
            t.equal(AppVolumeMeasure.filter(apps, ignoreSystemSound: true, excluded: []).map(\.pid), [100, 102])
            t.equal(AppVolumeMeasure.filter(apps, ignoreSystemSound: false, excluded: []).map(\.pid), [100, 101, 102])
            t.equal(AppVolumeMeasure.filter(apps, ignoreSystemSound: true, excluded: ["spotify.exe", "x"]).map(\.pid),
                    [102])
            t.check(apps[0].matches("Spotify.exe") && apps[0].matches("SPOTIFY") && apps[0].matches("com.spotify.client"))
            t.check(!apps[0].matches("") && !apps[0].matches("Spot"))
            t.check(AppVolumeMeasure.parseCall("GetVolumeFromIndex(2)")! == ("GetVolumeFromIndex", "2"))
            t.check(AppVolumeMeasure.parseCall("GetPeakFromAppName( 'spotify.exe' )")! == ("GetPeakFromAppName", "spotify.exe"))
            t.check(AppVolumeMeasure.parseCall("Nope") == nil)

            // Mute bookkeeping (fake taps): a list refresh queued just before a Mute must not forget the app, or the
            // next ToggleMute would mute it again instead of unmuting it.
            if #available(macOS 14.2, *) {
                let catalog = AudioAppCatalog()
                let tapLock = NSLock()
                var liveApps = apps
                var made: [pid_t] = []
                var destroyed: [AudioObjectID] = []
                func locked<T>(_ body: () -> T) -> T { tapLock.lock(); defer { tapLock.unlock() }; return body() }
                catalog.readApps = { locked { liveApps } }
                catalog.makeMuteTap = { pid in locked { made.append(pid) }; return AudioObjectID(1000 + pid) }
                catalog.destroyTap = { tap in locked { destroyed.append(tap) } }
                catalog.captureAllowed = { true }
                let gate = DispatchSemaphore(value: 0)
                AudioHAL.queue.async { gate.wait() }
                t.equal(catalog.list(), [], "the first read runs in the background")
                t.equal(catalog.setMuted(100, true), nil)
                t.check(catalog.isMuted(100), "muted at once")
                gate.signal()
                drainHAL()
                t.check(catalog.isMuted(100), "still muted after the refresh that was queued first")
                t.equal(locked { made }, [100])
                t.equal(catalog.list().map(\.pid), apps.map(\.pid))
                _ = catalog.setMuted(100, !catalog.isMuted(100))
                drainHAL()
                t.check(!catalog.isMuted(100), "ToggleMute unmutes")
                t.equal(locked { destroyed }, [1100])
                // A muted app that quits: its tap goes and it no longer counts as muted.
                _ = catalog.setMuted(102, true)
                drainHAL()
                locked { liveApps.removeAll { $0.pid == 102 } }
                catalog.scheduleRefresh()
                drainHAL()
                t.check(!catalog.isMuted(102))
                t.equal(locked { destroyed }, [1100, 1102])
                // A refused tap (no permission, the app went away) does not leave the app marked muted.
                catalog.makeMuteTap = { _ in nil }
                _ = catalog.setMuted(101, true)
                drainHAL()
                t.check(!catalog.isMuted(101))
                // Command-line modes never create taps.
                catalog.captureAllowed = { false }
                t.check(catalog.setMuted(100, true) != nil)
                t.check(!catalog.isMuted(100))
            }

            let ini = """
            [Parent]
            Measure=Plugin
            Plugin=AppVolume
            ExcludeApp=Safari.exe

            [ChildIndex]
            Measure=Plugin
            Plugin=AppVolume
            Parent=Parent
            Index=1
            StringType=FilePath

            [ChildName]
            Measure=Plugin
            Plugin=AppVolume
            Parent=Parent
            AppName=Spotify.exe
            NumType=Volume

            [ChildMissing]
            Measure=Plugin
            Plugin=AppVolume
            Parent=Parent
            Index=5
            """
            let skin = try makeSkin(t, ini)
            withExtendedLifetime(skin) {
                var measures: [String: AppVolumeMeasure] = [:]
                for n in ["Parent", "ChildIndex", "ChildName", "ChildMissing"] {
                    let m = AppVolumeMeasure(name: n, section: skin.document.section(named: n)!, skin: skin,
                                             type: "appvolume")
                    m.catalog = { apps }
                    m.deviceName = { "MacBook Pro Speakers" }
                    m.engine = makeEngine { _ in nil }
                    m.parentLookup = { measures[$0.lowercased()] }
                    measures[n.lowercased()] = m
                    m.readOptions()
                }
                let parent = measures["parent"]!
                t.equal(parent.computeValue(), 1, "Safari excluded, system sounds ignored")
                t.equal(parent.pluginString, "MacBook Pro Speakers")
                let byIndex = measures["childindex"]!
                t.equal(byIndex.computeValue(), 1, "volume is 100 %")
                t.equal(byIndex.pluginString, "/Applications/Spotify.app/Contents/MacOS/Spotify")
                let byName = measures["childname"]!
                t.equal(byName.computeValue(), 1)
                t.equal(byName.pluginString, "Spotify")
                let missing = measures["childmissing"]!
                t.equal(missing.computeValue(), 0)
                t.equal(missing.pluginString, "")
                t.equal(parent.sectionVariableFunction("GetFileNameFromIndex(1)"), "Spotify")
                t.equal(parent.sectionVariableFunction("GetFilePathFromIndex(9)"), "")
                t.equal(parent.sectionVariableFunction("GetVolumeFromAppName(spotify.exe)"), "1")
                t.equal(parent.sectionVariableFunction("GetVolumeFromIndex(3)"), "0")
                t.equal(parent.sectionVariableFunction("GetPeakFromIndex(1)"), "0", "no child follows its peak")
                t.equal(parent.sectionVariableFunction("SomethingElse(1)"), nil)
            }
        }
    }

    // MARK: Registration

    static func registrationTests(_ t: AppTestRunner) {
        t.suite("App: Audio registration") {
            AudioPlugins.register()
            t.check(MeasureRegistry.plugin(named: "AudioLevel") == AudioLevelMeasure.self)
            t.check(MeasureRegistry.plugin(named: "audiolevel.dll") == AudioLevelMeasure.self)
            t.check(MeasureRegistry.plugin(named: "Plugins\\Win7AudioPlugin.dll") == Win7AudioMeasure.self)
            t.check(MeasureRegistry.plugin(named: "Win7Audio") == Win7AudioMeasure.self)
            t.check(MeasureRegistry.plugin(named: "AppVolume.dll") == AppVolumeMeasure.self)
        }
    }

    // MARK: Devices (read-only, this Mac)

    static func deviceTests(_ t: AppTestRunner) {
        t.suite("App: Audio devices (read-only)") {
            // Reads the real device list and output volume (no permission involved, nothing is changed).
            let system = AudioSystem()
            system.activateIfNeeded(wait: 5)
            let s = system.snapshot()
            t.check(s.loaded, "device list read")
            for d in s.devices {
                t.check(!d.uid.isEmpty && !d.name.isEmpty, "device \(d.id) has a UID and a name")
                t.check(!d.uid.hasPrefix(AudioHAL.ownDevicePrefix), "Deskset's own devices are hidden")
                t.check(d.inputChannels >= 0 && d.outputChannels >= 0)
            }
            if let out = s.defaultOutput {
                t.check(s.device(out) != nil || s.devices.isEmpty, "the default output is listed")
                t.equal(s.output.deviceID, out)
                if let v = s.output.volume { t.check(v >= 0 && v <= 1, "volume \(v)") }
                let values = Win7AudioMeasure.values(s)
                t.check(values.number == -1 || (values.number >= 0 && values.number <= 100))
            }
            t.check(s.outputDevices.allSatisfy { $0.outputChannels > 0 })
            let list = AudioLevelMeasure.deviceList(s.outputDevices)
            t.equal(list.split(separator: "\n").count, s.outputDevices.count)
        }
    }

    // MARK: Test skins

    static func testSkinTests(_ t: AppTestRunner) {
        t.suite("App: Audio test skins") {
            guard let folder = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Audio") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            for (config, file, meters) in [("Audio\\Visualizer", "Visualizer.ini", 20),
                                           ("Audio\\Volume", "Volume.ini", 8)] {
                let url = folder.appendingPathComponent(config.replacingOccurrences(of: "Audio\\", with: ""))
                    .appendingPathComponent(file)
                let skin = Skin(config: config, fileURL: url, skinsDirectory: folder.deletingLastPathComponent(),
                                system: SystemMonitor.shared, host: host)
                do {
                    try skin.load()
                } catch {
                    t.check(false, "\(config) loads: \(error)")
                    continue
                }
                skin.update()
                skin.update()
                t.check(skin.meters.count >= meters, "\(config): \(skin.meters.count) meters")
                t.check(skin.width > 0 && skin.height > 0, "\(config) has a size")
            }
        }
    }
}
