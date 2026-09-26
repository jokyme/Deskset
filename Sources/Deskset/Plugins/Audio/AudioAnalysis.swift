import Accelerate
import Foundation

// Signal analysis behind `Plugin=AudioLevel` (clean-room, from the public manual only:
// https://docs.rainmeter.net/manual/plugins/audiolevel/). Pure DSP: no Core Audio, testable with synthetic buffers.
//
// Model (the manual gives the options, not the formulas; every formula here is a documented judgment call, see
// docs/compat/audio.md):
// - RMS: "the signal value is squared, averaged over a period of time, then the square root … is calculated". The
//   mean square of each 5 ms slice is followed by a one-pole filter whose time constant is RMSAttack while the level
//   rises and RMSDecay while it falls; the value is √(filtered mean square) × RMSGain, clipped to 0…1. With both
//   times 0 it is the RMS of the latest slice.
// - Peak: the largest |sample| of each slice, followed the same way with PeakAttack / PeakDecay, × PeakGain.
// - FFT: every FFTSize − FFTOverlap samples, the latest FFTSize samples are shaped with a Hann window and
//   transformed (vDSP). Bin power is normalised so that a full-scale sine centred on a bin is 0 dB. A power maps to
//   0…1 as `1 + (dB + 10) / Sensitivity` (so Sensitivity is the dB range shown, as the manual says),
//   then follows FFTAttack / FFTDecay in value space.
// - Bands: `Bands` log-spaced bands from FreqMin to FreqMax. A band's power is the integral of the power spectrum
//   (linear interpolation between bin centres, corrected for the Hann window's noise bandwidth) divided by the band
//   width in octaves, so pink noise draws a flat line whatever the number of bands. Mapped and smoothed like FFT.
// - Channels: rows 0…channels-1 are the stream's channels, the last row is Sum/Avg (average of the channels' mean
//   square / peak / power).

/// `Channel=` of AudioLevel child measures.
enum AudioChannel: Equatable {
    /// 0 FL, 1 FR, 2 C, 3 LFE, 4 BL, 5 BR, 6 SL, 7 SR (the manual's numbering).
    case index(Int)
    case sum

    /// Names and numbers from the manual (case-insensitive); nil for anything else.
    static func parse(_ raw: String) -> AudioChannel? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "fl", "0": return .index(0)
        case "r", "fr", "1": return .index(1)
        case "c", "2": return .index(2)
        case "lfe", "sub", "3": return .index(3)
        case "bl", "4": return .index(4)
        case "br", "5": return .index(5)
        case "sl", "6": return .index(6)
        case "sr", "7": return .index(7)
        case "sum", "avg", "": return .sum
        default: return nil
        }
    }

    /// Row of the analysis outputs for a stream of `channels` channels (the Sum row is `channels`), or nil when the
    /// stream has no such channel. A mono stream (microphones) answers L, R and C with its only channel; streams
    /// with more channels keep the device's channel order.
    func row(channels: Int) -> Int? {
        guard channels > 0 else { return nil }
        switch self {
        case .sum: return channels
        case .index(let i):
            if channels == 1 { return i <= 2 ? 0 : nil }
            return i >= 0 && i < channels ? i : nil
        }
    }
}

/// Parent measure options that shape the analysis. Read once: "Parent measure options may not be changed
/// dynamically".
struct AudioAnalysisSettings: Equatable {
    var rmsAttack = 300.0
    var rmsDecay = 300.0
    var rmsGain = 1.0
    var peakAttack = 50.0
    var peakDecay = 2500.0
    var peakGain = 1.0
    var fftSize = 0
    var fftOverlap = 0
    var fftAttack = 300.0
    var fftDecay = 300.0
    var bands = 0
    var freqMin = 20.0
    var freqMax = 20000.0
    var sensitivity = 35.0

    /// Guards against hostile values: a 1M-point FFT or a million bands would cost real CPU on every hop.
    static let maxFFTSize = 65_536
    static let maxBands = 1024
    static let maxTime = 3_600_000.0

    /// Clamped copy: times 0…1 h, gains finite and ≥ 0, FFTSize even (0 = off) up to 65536, overlap below the size,
    /// bands 0…1024, 1 Hz ≤ FreqMin < FreqMax, Sensitivity ≥ 1 dB.
    func normalized() -> AudioAnalysisSettings {
        func time(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), AudioAnalysisSettings.maxTime) : 0 }
        func gain(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1e6) : 1 }
        var s = self
        s.rmsAttack = time(rmsAttack)
        s.rmsDecay = time(rmsDecay)
        s.peakAttack = time(peakAttack)
        s.peakDecay = time(peakDecay)
        s.fftAttack = time(fftAttack)
        s.fftDecay = time(fftDecay)
        s.rmsGain = gain(rmsGain)
        s.peakGain = gain(peakGain)
        var size = min(max(fftSize, 0), AudioAnalysisSettings.maxFFTSize)
        if size % 2 == 1 { size += 1 }
        s.fftSize = size < 2 ? 0 : size
        s.fftOverlap = s.fftSize == 0 ? 0 : min(max(fftOverlap, 0), s.fftSize - 1)
        s.bands = min(max(bands, 0), AudioAnalysisSettings.maxBands)
        var lo = freqMin.isFinite ? max(freqMin, 1) : 20
        var hi = freqMax.isFinite ? max(freqMax, 1) : 20000
        if hi < lo { swap(&lo, &hi) }
        if hi <= lo { hi = lo * 2 }
        s.freqMin = lo
        s.freqMax = hi
        s.sensitivity = sensitivity.isFinite ? min(max(sensitivity, 1), 1000) : 35
        return s
    }
}

/// Values published by an analyzer (rows: channels, then Sum).
struct AudioAnalysisOutput {
    var channels = 0
    var sampleRate = 0.0
    /// Filtered mean square per row (before the square root and the gain).
    var meanSquare: [Double] = []
    var peak: [Double] = []
    /// Smoothed 0…1 values, `fftSize / 2 + 1` per row.
    var fft: [[Float]] = []
    /// Smoothed 0…1 values, `bands` per row.
    var bands: [[Float]] = []
}

enum AudioMath {
    /// dB added to the normalised power before mapping: value 1.0 is reached by a band holding, per octave, the
    /// energy of a sine at −10 dBFS (or an FFT bin holding such a sine). Calibrated with pink noise and typical
    /// streaming loudness (−14…−10 dBFS RMS) so that music fills roughly the upper half of the range at the
    /// Sensitivity values visualizer skins use (25…35), with bass peaks reaching the top.
    static let referenceOffsetDB = 10.0

    /// One-pole follower step: moves `value` towards `target` over `seconds`, with the attack time constant (ms)
    /// while rising and the decay one while falling; a time of 0 jumps.
    @inline(__always)
    static func follow(_ value: inout Double, target: Double, seconds: Double, attack: Double, decay: Double) {
        let tau = target > value ? attack : decay
        if tau <= 0 || !value.isFinite {
            value = target
        } else {
            value = target + (value - target) * exp(-seconds * 1000 / tau)
        }
    }

    /// Power (normalised, 1 = full-scale sine) → 0…1.
    @inline(__always)
    static func level(power: Double, sensitivity: Double) -> Double {
        guard power > 1e-30, power.isFinite else { return 0 }
        let v = 1 + (10 * log10(power) + referenceOffsetDB) / sensitivity
        return min(max(v, 0), 1)
    }

    /// Smallest FFT length vDSP's real DFT accepts that is ≥ `n` (f × 2^k with f ∈ {1, 3, 5, 15}).
    static func supportedDFTSize(atLeast n: Int) -> Int {
        var best = Int.max
        for f in [1, 3, 5, 15] {
            var m = f * 16
            while m < n { m *= 2 }
            best = min(best, m)
        }
        return best
    }
}

/// Band edges and integration weights for one (FFT size, sample rate, bands, FreqMin, FreqMax).
struct AudioBandLayout {
    /// `bands + 1` edges in Hz, log-spaced from FreqMin to FreqMax.
    let edges: [Double]
    /// Per band: first bin and the weights of the following bins (power → band power per octave).
    let weights: [(start: Int, values: [Float])]

    var count: Int { max(edges.count - 1, 0) }

    /// Geometric centre of band `i` (BandFreq).
    func centerFrequency(_ i: Int) -> Double {
        guard i >= 0, i < count else { return 0 }
        return (edges[i] * edges[i + 1]).squareRoot()
    }

    static func edges(bands: Int, freqMin: Double, freqMax: Double) -> [Double] {
        guard bands > 0 else { return [] }
        let ratio = log(freqMax / freqMin)
        return (0...bands).map { freqMin * exp(ratio * Double($0) / Double(bands)) }
    }

    /// `enbw` is the window's equivalent noise bandwidth in bins (1.5 for Hann).
    init(bands: Int, freqMin: Double, freqMax: Double, fftSize: Int, sampleRate: Double, enbw: Double) {
        let e = AudioBandLayout.edges(bands: bands, freqMin: freqMin, freqMax: freqMax)
        edges = e
        guard bands > 0, fftSize >= 2, sampleRate > 0 else {
            weights = []
            return
        }
        let bins = fftSize / 2 + 1
        let delta = sampleRate / Double(fftSize)
        var result: [(Int, [Float])] = []
        result.reserveCapacity(bands)
        for b in 0..<bands {
            let lo = e[b], hi = e[b + 1]
            var w: [Int: Double] = [:]
            // The spectrum is taken as linear between bin centres (k·Δ); ∫ over [lo, hi] gives each bin a weight.
            var k = max(Int((lo / delta).rounded(.down)), 0)
            while k < bins - 1 {
                let fk = Double(k) * delta
                if fk >= hi { break }
                let a = max(lo, fk), bEnd = min(hi, fk + delta)
                if bEnd > a {
                    let ua = (a - fk) / delta, ub = (bEnd - fk) / delta
                    let half = (ub * ub - ua * ua) / 2
                    w[k, default: 0] += (ub - ua) - half
                    w[k + 1, default: 0] += half
                }
                k += 1
            }
            let octaves = log2(hi / lo)
            let norm = 1 / (enbw * max(octaves, 1e-9))
            if let first = w.keys.min(), let last = w.keys.max() {
                var values = [Float](repeating: 0, count: last - first + 1)
                for (bin, weight) in w { values[bin - first] = Float(weight * norm) }
                result.append((first, values))
            } else {
                result.append((0, []))
            }
        }
        weights = result
    }
}

/// Windowed FFT of the latest `size` samples of every channel, every `hop` samples, with smoothed 0…1 values per
/// bin and per band. Runs on the analysis thread only.
final class AudioSpectrum {
    let size: Int
    let hop: Int
    let bins: Int
    let channels: Int
    let sampleRate: Double
    let layout: AudioBandLayout
    private let dftSize: Int
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private let windowSum: Double
    /// Per channel ring of the last `size` samples.
    private var history: [[Float]]
    private var position = 0
    private var sinceHop = 0
    private var frame: [Float]
    private var packedReal: [Float]
    private var packedImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var dftPower: [Double]
    /// Power per row (channels + Sum) of the latest transform.
    private(set) var power: [[Double]]
    /// Smoothed 0…1 values per row.
    private(set) var fftValues: [[Float]]
    private(set) var bandValues: [[Float]]

    init?(settings s: AudioAnalysisSettings, channels: Int, sampleRate: Double) {
        guard s.fftSize >= 2, channels > 0, sampleRate > 0 else { return nil }
        size = s.fftSize
        hop = max(1, s.fftSize - s.fftOverlap)
        bins = size / 2 + 1
        self.channels = channels
        self.sampleRate = sampleRate
        var m = size >= 16 ? size : 16
        var created = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(m), .FORWARD)
        if created == nil {
            m = AudioMath.supportedDFTSize(atLeast: m)
            created = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(m), .FORWARD)
        }
        guard let setup = created else { return nil }
        self.setup = setup
        dftSize = m
        // Periodic Hann window: the manual's "Hann function is used to shape the data".
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(s.fftSize)) }
        let sum = window.reduce(0.0) { $0 + Double($1) }
        let sumSquares = window.reduce(0.0) { $0 + Double($1) * Double($1) }
        windowSum = max(sum, 1e-12)
        let enbw = Double(size) * sumSquares / (windowSum * windowSum)
        layout = AudioBandLayout(bands: s.bands, freqMin: s.freqMin, freqMax: s.freqMax, fftSize: size,
                                 sampleRate: sampleRate, enbw: enbw)
        history = Array(repeating: [Float](repeating: 0, count: size), count: channels)
        frame = [Float](repeating: 0, count: m)
        packedReal = [Float](repeating: 0, count: m / 2)
        packedImag = [Float](repeating: 0, count: m / 2)
        outReal = [Float](repeating: 0, count: m / 2)
        outImag = [Float](repeating: 0, count: m / 2)
        dftPower = [Double](repeating: 0, count: m / 2 + 1)
        power = Array(repeating: [Double](repeating: 0, count: bins), count: channels + 1)
        fftValues = Array(repeating: [Float](repeating: 0, count: bins), count: channels + 1)
        bandValues = Array(repeating: [Float](repeating: 0, count: layout.count), count: channels + 1)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// Frequency of FFT point `index` (FFTFreq).
    func frequency(ofBin index: Int) -> Double { Double(index) * sampleRate / Double(size) }

    /// Samples of pure digital silence at the end of the history (a silent window needs no transform).
    private(set) var silentSamples = 0
    /// All values are 0 after a silent stretch: decaying further is skipped.
    private var settled = true

    /// True when the whole window is digital silence.
    var isSilent: Bool { silentSamples >= size }

    /// Appends interleaved frames (`stride` floats apart); returns the hops completed, if any. `silent` says the
    /// frames are all exactly 0 (the capture delivers zeros while nothing plays).
    func append(_ samples: UnsafePointer<Float>, stride: Int, frames: Int, silent: Bool = false) -> Int {
        guard frames > 0 else { return 0 }
        silentSamples = silent ? min(silentSamples + frames, Int.max / 2) : 0
        for c in 0..<channels {
            history[c].withUnsafeMutableBufferPointer { ring in
                var p = position
                for f in 0..<frames {
                    ring[p] = samples[f * stride + c]
                    p += 1
                    if p == size { p = 0 }
                }
            }
        }
        position = (position + frames) % size
        sinceHop += frames
        let hops = sinceHop / hop
        sinceHop -= hops * hop
        return hops
    }

    /// Whether per-bin values are computed (only once a measure asked for `Type=FFT`: most skins use bands only,
    /// and mapping every bin costs a logarithm per bin and channel).
    var computesBinValues = false

    /// Transforms the latest window of every channel and updates the smoothed values; `seconds` is the time since
    /// the previous transform.
    func analyze(seconds: Double, settings s: AudioAnalysisSettings) {
        for r in 0..<bins { power[channels][r] = 0 }
        for c in 0..<channels {
            transform(channel: c)
            for k in 0..<bins {
                power[c][k] = binPower(k)
                power[channels][k] += power[c][k]
            }
        }
        let n = Double(channels)
        for k in 0..<bins { power[channels][k] /= n }
        settled = false
        smooth(seconds: seconds, settings: s, silence: false)
    }

    /// Lets every value fall towards 0 (no audio arrives, or only silence): no transform, and nothing at all once
    /// every value reached 0.
    func decay(seconds: Double, settings s: AudioAnalysisSettings) {
        guard !settled else { return }
        smooth(seconds: seconds, settings: s, silence: true)
        var largest: Float = 0
        for r in 0...channels {
            if computesBinValues { for v in fftValues[r] { largest = max(largest, v) } }
            for v in bandValues[r] { largest = max(largest, v) }
        }
        if largest < 1e-4 {
            for r in 0...channels {
                for k in 0..<bins { fftValues[r][k] = 0 }
                for b in 0..<layout.count { bandValues[r][b] = 0 }
            }
            settled = true
        }
    }

    private func smooth(seconds: Double, settings s: AudioAnalysisSettings, silence: Bool) {
        let attackFactor = s.fftAttack <= 0 ? 0 : exp(-seconds * 1000 / s.fftAttack)
        let decayFactor = s.fftDecay <= 0 ? 0 : exp(-seconds * 1000 / s.fftDecay)
        func step(_ old: Float, _ target: Double) -> Float {
            let o = Double(old)
            let f = target > o ? attackFactor : decayFactor
            return Float(target + (o - target) * f)
        }
        for r in 0...channels {
            if computesBinValues {
                for k in 0..<bins {
                    let target = silence ? 0 : AudioMath.level(power: power[r][k], sensitivity: s.sensitivity)
                    fftValues[r][k] = step(fftValues[r][k], target)
                }
            }
            for (b, w) in layout.weights.enumerated() {
                var target = 0.0
                if !silence {
                    var p = 0.0
                    for (i, weight) in w.values.enumerated() where w.start + i < bins {
                        p += Double(weight) * power[r][w.start + i]
                    }
                    target = AudioMath.level(power: p, sensitivity: s.sensitivity)
                }
                bandValues[r][b] = step(bandValues[r][b], target)
            }
        }
    }

    /// Normalised power of bin k (N-grid) from the last transform (interpolated when the DFT was zero-padded).
    private func binPower(_ k: Int) -> Double {
        if dftSize == size { return dftPower[k] }
        let x = Double(k) * Double(dftSize) / Double(size)
        let i = min(Int(x), dftSize / 2)
        let j = min(i + 1, dftSize / 2)
        let t = x - Double(i)
        return dftPower[i] * (1 - t) + dftPower[j] * t
    }

    private func transform(channel c: Int) {
        let m = dftSize
        // Oldest sample first; zero-padded up to the DFT length.
        history[c].withUnsafeBufferPointer { ring in
            frame.withUnsafeMutableBufferPointer { out in
                var p = position
                for i in 0..<size {
                    out[i] = ring[p] * window[i]
                    p += 1
                    if p == size { p = 0 }
                }
                for i in size..<m { out[i] = 0 }
            }
        }
        for i in 0..<(m / 2) {
            packedReal[i] = frame[2 * i]
            packedImag[i] = frame[2 * i + 1]
        }
        vDSP_DFT_Execute(setup, packedReal, packedImag, &outReal, &outImag)
        // vDSP's real DFT returns 2·X[k]; X[0] and X[m/2] are packed in the first element.
        let norm = 1 / (windowSum * windowSum)
        dftPower[0] = Double(outReal[0]) * Double(outReal[0]) * norm / 4
        dftPower[m / 2] = Double(outImag[0]) * Double(outImag[0]) * norm / 4
        for k in 1..<(m / 2) {
            let re = Double(outReal[k]), im = Double(outImag[k])
            dftPower[k] = (re * re + im * im) * norm
        }
    }
}

/// Analysis of one AudioLevel parent measure: level followers per channel and the optional spectrum. Fed on the
/// capture engine's analysis thread; the published values are read from any thread.
final class AudioAnalyzer {
    let settings: AudioAnalysisSettings
    static let maxChannels = 8
    /// Length of one level-follower step.
    static let sliceSeconds = 0.005

    private var channels = 0
    private var sampleRate = 0.0
    private var meanSquare: [Double] = []
    private var peak: [Double] = []
    private var spectrum: AudioSpectrum?
    private var secondsSinceTransform = 0.0

    private let lock = NSLock()
    private var output = AudioAnalysisOutput()
    /// Set by `requestBinValues()` or the first `fft(_:index:)` read (under `lock`).
    private var fftRequested = false

    init(settings: AudioAnalysisSettings) {
        self.settings = settings.normalized()
    }

    /// Feeds interleaved Float32 frames (`stride` floats per frame, `channels` of them used).
    func process(_ samples: UnsafePointer<Float>, stride: Int, frames: Int, channels ch: Int, sampleRate sr: Double) {
        guard frames > 0, ch > 0, stride >= ch, sr > 0, sr.isFinite else { return }
        let ch = min(ch, AudioAnalyzer.maxChannels)
        if ch != channels || sr != sampleRate { configure(channels: ch, sampleRate: sr) }
        let s = settings
        let slice = max(1, Int(sr * AudioAnalyzer.sliceSeconds))
        var start = 0
        var hops = 0
        while start < frames {
            let n = min(slice, frames - start)
            let seconds = Double(n) / sr
            let base = samples + start * stride
            var msTotal = 0.0, peakTotal = 0.0
            var loudest: Float = 0
            for c in 0..<ch {
                var ms: Float = 0, pk: Float = 0
                vDSP_measqv(base + c, vDSP_Stride(stride), &ms, vDSP_Length(n))
                vDSP_maxmgv(base + c, vDSP_Stride(stride), &pk, vDSP_Length(n))
                let msD = ms.isFinite ? Double(ms) : 0, pkD = pk.isFinite ? Double(pk) : 0
                loudest = max(loudest, pk.isFinite ? pk : 1)
                AudioMath.follow(&meanSquare[c], target: msD, seconds: seconds, attack: s.rmsAttack, decay: s.rmsDecay)
                AudioMath.follow(&peak[c], target: pkD, seconds: seconds, attack: s.peakAttack, decay: s.peakDecay)
                msTotal += msD
                peakTotal += pkD
            }
            AudioMath.follow(&meanSquare[ch], target: msTotal / Double(ch), seconds: seconds,
                             attack: s.rmsAttack, decay: s.rmsDecay)
            AudioMath.follow(&peak[ch], target: peakTotal / Double(ch), seconds: seconds,
                             attack: s.peakAttack, decay: s.peakDecay)
            if let spectrum { hops += spectrum.append(base, stride: stride, frames: n, silent: loudest == 0) }
            secondsSinceTransform += seconds
            start += n
        }
        if let spectrum, hops > 0 {
            lock.lock()
            spectrum.computesBinValues = fftRequested
            lock.unlock()
            // Only the latest window is transformed; the smoothing covers the whole time since the previous one.
            if spectrum.isSilent {
                spectrum.decay(seconds: secondsSinceTransform, settings: s)
            } else {
                spectrum.analyze(seconds: secondsSinceTransform, settings: s)
            }
            secondsSinceTransform = 0
        }
        publish()
    }

    /// No audio for `seconds` (device stopped, capture interrupted): every value falls with its decay time, so
    /// meters never freeze on the last sound.
    func decay(seconds: Double) {
        guard channels > 0, seconds > 0 else { return }
        let s = settings
        for r in 0...channels {
            AudioMath.follow(&meanSquare[r], target: 0, seconds: seconds, attack: s.rmsAttack, decay: s.rmsDecay)
            AudioMath.follow(&peak[r], target: 0, seconds: seconds, attack: s.peakAttack, decay: s.peakDecay)
        }
        spectrum?.decay(seconds: seconds, settings: s)
        publish()
    }

    /// Back to silence (capture stopped).
    func reset() {
        channels = 0
        sampleRate = 0
        meanSquare = []
        peak = []
        spectrum = nil
        lock.lock()
        output = AudioAnalysisOutput()
        lock.unlock()
    }

    private func configure(channels ch: Int, sampleRate sr: Double) {
        channels = ch
        sampleRate = sr
        meanSquare = [Double](repeating: 0, count: ch + 1)
        peak = [Double](repeating: 0, count: ch + 1)
        spectrum = AudioSpectrum(settings: settings, channels: ch, sampleRate: sr)
        secondsSinceTransform = 0
        lock.lock()
        output = AudioAnalysisOutput(channels: ch, sampleRate: sr, meanSquare: meanSquare, peak: peak,
                                     fft: spectrum?.fftValues ?? [], bands: spectrum?.bandValues ?? [])
        lock.unlock()
    }

    private func publish() {
        lock.lock()
        defer { lock.unlock() }
        guard output.channels == channels else { return }
        for r in 0..<meanSquare.count {
            output.meanSquare[r] = meanSquare[r]
            output.peak[r] = peak[r]
        }
        if let spectrum {
            for r in 0..<output.fft.count {
                spectrum.fftValues[r].withUnsafeBufferPointer { src in
                    output.fft[r].withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress?.update(from: src.baseAddress!, count: min(src.count, dst.count))
                    }
                }
                spectrum.bandValues[r].withUnsafeBufferPointer { src in
                    guard let from = src.baseAddress else { return }
                    output.bands[r].withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress?.update(from: from, count: min(src.count, dst.count))
                    }
                }
            }
        }
    }

    // MARK: Reading (any thread)

    /// Channel count and sample rate of the stream analysed (0 before the first audio arrives).
    var format: (channels: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        return (output.channels, output.sampleRate)
    }

    func rms(_ channel: AudioChannel) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = channel.row(channels: output.channels), r < output.meanSquare.count else { return 0 }
        return min(max(output.meanSquare[r], 0).squareRoot() * settings.rmsGain, 1)
    }

    func peak(_ channel: AudioChannel) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = channel.row(channels: output.channels), r < output.peak.count else { return 0 }
        return min(max(output.peak[r], 0) * settings.peakGain, 1)
    }

    /// Per-bin values are computed from now on (a measure with `Type=FFT` reads this analyzer).
    func requestBinValues() {
        lock.lock()
        fftRequested = true
        lock.unlock()
    }

    func fft(_ channel: AudioChannel, index: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        fftRequested = true
        guard let r = channel.row(channels: output.channels), r < output.fft.count,
              index >= 0, index < output.fft[r].count else { return 0 }
        return Double(output.fft[r][index])
    }

    func band(_ channel: AudioChannel, index: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = channel.row(channels: output.channels), r < output.bands.count,
              index >= 0, index < output.bands[r].count else { return 0 }
        return Double(output.bands[r][index])
    }

    /// FFTFreq: frequency of FFT point `index` at `sampleRate` (the stream's rate once audio arrives).
    func fftFrequency(index: Int, sampleRate fallback: Double) -> Double {
        let size = settings.fftSize
        guard size > 0, index >= 0, index <= size / 2 else { return 0 }
        let sr = format.sampleRate > 0 ? format.sampleRate : fallback
        return Double(index) * sr / Double(size)
    }

    /// BandFreq: geometric centre of band `index` (independent of the stream).
    func bandFrequency(index: Int) -> Double {
        guard settings.fftSize > 0, index >= 0, index < settings.bands else { return 0 }
        let e = AudioBandLayout.edges(bands: settings.bands, freqMin: settings.freqMin, freqMax: settings.freqMax)
        return (e[index] * e[index + 1]).squareRoot()
    }
}
