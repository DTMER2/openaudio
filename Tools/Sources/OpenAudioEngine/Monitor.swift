// Monitor.swift
// Off-RT monitor thread (NF-P3): drains the monitor ring ([bus + per-source
// stereo] interleaved), computes peak + RMS per column with vDSP, publishes an
// atomic snapshot, maintains the silence-watchdog signals (bus exact-zero +
// last-non-zero timestamp), and optionally records the stereo bus mix to a CAF
// file (F-E5) via ExtAudioFile. File I/O never touches the RT thread.

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import Darwin

public struct SourceMeter {
    public var name: String
    public var peakDB: Float
    public var rmsDB: Float

    public init(name: String, peakDB: Float, rmsDB: Float) {
        self.name = name; self.peakDB = peakDB; self.rmsDB = rmsDB
    }
}

/// Per-channel (L/R) meter (F-U4 / F-E4). All levels are dBFS (-inf allowed).
/// Keeps the deliberate max-hold-since-last-poll behaviour, now per channel.
public struct StereoMeter {
    public var name: String
    public var peakL: Float
    public var peakR: Float
    public var rmsL: Float
    public var rmsR: Float

    public init(name: String, peakL: Float, peakR: Float, rmsL: Float, rmsR: Float) {
        self.name = name
        self.peakL = peakL; self.peakR = peakR
        self.rmsL = rmsL; self.rmsR = rmsR
    }

    /// Mono summaries (max of the two channels) for backward-compatible display.
    public var peakDB: Float { max(peakL, peakR) }
    public var rmsDB: Float { max(rmsL, rmsR) }
    public var mono: SourceMeter { SourceMeter(name: name, peakDB: peakDB, rmsDB: rmsDB) }
}

public final class Monitor: @unchecked Sendable {
    private let ring: MonitorRing
    private let monChannels: Int
    private let sampleRate: Double
    private let sourceNames: [String]   // e.g. ["tap"] or ["tap","input"]

    // Published meters: index 0 = bus, then one per source. Peak/RMS as Float
    // bits, tracked PER CHANNEL (L/R) for F-U4. The smoothed values are the
    // fallback when no block arrived since the last poll.
    private let peakLBits: [Atomic64]
    private let peakRBits: [Atomic64]
    private let rmsLBits: [Atomic64]
    private let rmsRBits: [Atomic64]
    // Max-hold since the last stereoMeters() poll — the smoothed values decay
    // too fast (~16 dB/s) to be sampled at a 2 s stats interval without missing
    // bursts. Preserved per channel.
    private let holdPeakLBits: [Atomic64]
    private let holdPeakRBits: [Atomic64]
    private let holdRMSLBits: [Atomic64]
    private let holdRMSRBits: [Atomic64]

    // Watchdog signals (bus).
    public let lastNonZeroMach = Atomic64(0)
    public let everHadAudio = Atomic64(0)

    // Recording.
    private var extFile: ExtAudioFileRef?
    public let framesRecorded = Atomic64(0)

    private var thread: Thread?
    private let runFlag = Atomic64(0)   // cross-thread run signal (1 = running)
    private let blockFrames = 4096
    private var scratch: UnsafeMutablePointer<Float>
    private var stereoScratch: UnsafeMutablePointer<Float>
    private var smoothPeakL: [Float]
    private var smoothPeakR: [Float]
    private var smoothRMSL: [Float]
    private var smoothRMSR: [Float]

    /// - Parameter sourceNames: source columns after the bus (bus is implicit index 0).
    public init(ring: MonitorRing, sampleRate: Double, sourceNames: [String], recordURL: URL?) throws {
        self.ring = ring
        self.monChannels = ring.channels
        self.sampleRate = sampleRate
        self.sourceNames = sourceNames
        let meterCount = 1 + sourceNames.count       // bus + sources
        self.peakLBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.peakRBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.rmsLBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.rmsRBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.holdPeakLBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.holdPeakRBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.holdRMSLBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.holdRMSRBits = (0..<meterCount).map { _ in Atomic64(0) }
        self.smoothPeakL = [Float](repeating: 0, count: meterCount)
        self.smoothPeakR = [Float](repeating: 0, count: meterCount)
        self.smoothRMSL = [Float](repeating: 0, count: meterCount)
        self.smoothRMSR = [Float](repeating: 0, count: meterCount)
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * monChannels)
        self.stereoScratch = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * 2)
        lastNonZeroMach.store(MachClock.now())

        if let url = recordURL {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0)
            var file: ExtAudioFileRef?
            try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &asbd, nil,
                                                AudioFileFlags.eraseFile.rawValue, &file),
                      "ExtAudioFileCreateWithURL(\(url.path))")
            guard let file else { throw OAError("ExtAudioFileCreateWithURL returned null") }
            try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd),
                      "ExtAudioFileSetProperty(ClientDataFormat)")
            self.extFile = file
        }
    }

    deinit {
        // Safety net: normal shutdown goes through stop(); make sure the file
        // is not leaked if an owner drops the Monitor without stopping it.
        if let f = extFile { ExtAudioFileDispose(f); extFile = nil }
        scratch.deallocate()
        stereoScratch.deallocate()
    }

    public func start() {
        runFlag.store(1)
        let t = Thread { [weak self] in self?.run() }
        t.name = "OpenAudio.Monitor"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    public func stop() {
        runFlag.store(0)
        while thread?.isFinished == false { usleep(2000) }
        thread = nil
        drainOnce(finalFlush: true)
        if let f = extFile { ExtAudioFileDispose(f); extFile = nil }
    }

    // MARK: Published readings

    /// Per-channel (L/R) meters (F-U4). Reports the max-since-last-poll per
    /// channel, then resets the hold; falls back to the smoothed value when no
    /// block arrived since the last poll. The read-then-reset race with a
    /// concurrent analyze() block can drop at most one block from the hold —
    /// acceptable for display. Index 0 is the bus, then one per source.
    public func stereoMeters() -> (bus: StereoMeter, sources: [StereoMeter]) {
        func dB(_ v: Float) -> Float { v > 0 ? 20 * log10f(v) : -Float.infinity }
        func take(_ hold: Atomic64, _ smooth: Atomic64) -> Float {
            let h = hold.loadFloat()
            hold.storeFloat(0)
            return h > 0 ? h : smooth.loadFloat()
        }
        func meter(_ m: Int, _ name: String) -> StereoMeter {
            StereoMeter(
                name: name,
                peakL: dB(take(holdPeakLBits[m], peakLBits[m])),
                peakR: dB(take(holdPeakRBits[m], peakRBits[m])),
                rmsL: dB(take(holdRMSLBits[m], rmsLBits[m])),
                rmsR: dB(take(holdRMSRBits[m], rmsRBits[m])))
        }
        let bus = meter(0, "bus")
        var srcs: [StereoMeter] = []
        for (i, name) in sourceNames.enumerated() { srcs.append(meter(i + 1, name)) }
        return (bus, srcs)
    }

    /// Backward-compatible mono (max L/R) meters.
    public func meters() -> (bus: SourceMeter, sources: [SourceMeter]) {
        let (bus, srcs) = stereoMeters()
        return (bus.mono, srcs.map { $0.mono })
    }

    public func secondsSinceLastNonZero() -> Double { MachClock.seconds(since: lastNonZeroMach.load()) }
    public func hasSeenAudio() -> Bool { everHadAudio.load() != 0 }

    /// Reset the silence baseline (called after a capture rebuild).
    public func resetSilenceBaseline() { lastNonZeroMach.store(MachClock.now()) }

    // MARK: Worker

    private func run() {
        while runFlag.load() == 1 {
            let wrote = drainOnce(finalFlush: false)
            if wrote == 0 { usleep(3000) }
        }
    }

    @discardableResult
    private func drainOnce(finalFlush: Bool) -> Int {
        var total = 0
        repeat {
            let frames = ring.read(into: scratch, maxFrames: blockFrames)
            if frames == 0 { break }
            analyze(frames: frames)
            recordBus(frames: frames)
            total += frames
        } while finalFlush
        return total
    }

    private func analyze(frames: Int) {
        let meterCount = 1 + sourceNames.count
        // Bus exact-zero detection (column 0/1) for the silence watchdog.
        var busMax: Float = 0
        vDSP_maxmgv(scratch, monChannels, &busMax, vDSP_Length(frames))          // col 0 (L)
        var busMaxR: Float = 0
        vDSP_maxmgv(scratch + 1, monChannels, &busMaxR, vDSP_Length(frames))     // col 1 (R)
        if busMax != 0 || busMaxR != 0 {
            lastNonZeroMach.store(MachClock.now())
            if everHadAudio.load() == 0 { everHadAudio.store(1) }
        }

        // Peak + RMS per meter, per channel (each meter = a stereo pair of
        // columns). Smoothing/hold identical to before, now tracked per L/R.
        @inline(__always)
        func update(_ m: Int, col: Int,
                    smoothPeak: inout [Float], smoothRMS: inout [Float],
                    peakBits: [Atomic64], rmsBits: [Atomic64],
                    holdPeak: [Atomic64], holdRMS: [Atomic64]) {
            var pk: Float = 0, rms: Float = 0
            vDSP_maxmgv(scratch + col, monChannels, &pk, vDSP_Length(frames))
            vDSP_rmsqv(scratch + col, monChannels, &rms, vDSP_Length(frames))
            // Fast-attack / slow-release peak smoothing; RMS exponential smoothing.
            smoothPeak[m] = pk > smoothPeak[m] ? pk : (smoothPeak[m] * 0.85 + pk * 0.15)
            smoothRMS[m] = smoothRMS[m] * 0.8 + rms * 0.2
            // Flush denormal decay to zero so dB readouts don't run off to
            // absurd values (~-140 dBFS floor).
            if smoothPeak[m] < 1e-7 { smoothPeak[m] = 0 }
            if smoothRMS[m] < 1e-7 { smoothRMS[m] = 0 }
            peakBits[m].storeFloat(smoothPeak[m])
            rmsBits[m].storeFloat(smoothRMS[m])
            // Same 1e-7 floor as the smoothed values: resampler tails decay into
            // denormals and would otherwise read as -150..-600 dBFS.
            if pk >= 1e-7, pk > holdPeak[m].loadFloat() { holdPeak[m].storeFloat(pk) }
            if rms >= 1e-7, rms > holdRMS[m].loadFloat() { holdRMS[m].storeFloat(rms) }
        }
        for m in 0..<meterCount {
            update(m, col: m * 2, smoothPeak: &smoothPeakL, smoothRMS: &smoothRMSL,
                   peakBits: peakLBits, rmsBits: rmsLBits, holdPeak: holdPeakLBits, holdRMS: holdRMSLBits)
            update(m, col: m * 2 + 1, smoothPeak: &smoothPeakR, smoothRMS: &smoothRMSR,
                   peakBits: peakRBits, rmsBits: rmsRBits, holdPeak: holdPeakRBits, holdRMS: holdRMSRBits)
        }
    }

    private func recordBus(frames: Int) {
        guard let file = extFile else { return }
        // Extract stereo bus (columns 0/1) into a packed stereo buffer.
        for i in 0..<frames {
            stereoScratch[i * 2] = scratch[i * monChannels]
            stereoScratch[i * 2 + 1] = scratch[i * monChannels + 1]
        }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                mData: stereoScratch))
        let status = ExtAudioFileWrite(file, UInt32(frames), &abl)
        if status != noErr {
            OALog.error("ExtAudioFileWrite failed: OSStatus \(osStatusString(status))")
        } else {
            framesRecorded.add(UInt64(frames))
        }
    }
}
