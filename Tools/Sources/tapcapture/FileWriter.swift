// FileWriter.swift
// Consumer thread: drains the ring buffer, applies attenuation-compensation
// gain and the post-rebuild fade-in, computes RMS / exact-zero silence
// detection (vDSP, off the realtime path), and appends to a CAF file via
// ExtAudioFile.

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import Darwin

final class FileWriter: @unchecked Sendable {
    private let ring: RingBuffer
    private let channels: Int
    private let sampleRate: Double
    private let compGain: Float
    private let rebuildGeneration: Atomic64

    // Published for the watchdog.
    let framesWritten = Atomic64(0)
    let lastNonZeroMach = Atomic64(0)
    let everHadAudio = Atomic64(0)
    private let rmsBits = Atomic64(0)      // Float bit pattern of smoothed post-gain RMS

    private var extFile: ExtAudioFileRef?
    private var thread: Thread?
    private var running = false

    private let blockFrames = 4096
    private let fadeFrames: Int          // ~10 ms

    private var scratch: UnsafeMutablePointer<Float>
    private var localGeneration: UInt64 = 0
    private var fadeRemaining = 0
    private var rmsSmoothed: Float = 0

    init(url: URL,
         channels: Int,
         sampleRate: Double,
         compGain: Float,
         ring: RingBuffer,
         rebuildGeneration: Atomic64) throws {
        self.ring = ring
        self.channels = channels
        self.sampleRate = sampleRate
        self.compGain = compGain
        self.rebuildGeneration = rebuildGeneration
        self.fadeFrames = max(1, Int(sampleRate * 0.010))
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * channels)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        var file: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(
                url as CFURL,
                kAudioFileCAFType,
                &asbd,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &file),
            "ExtAudioFileCreateWithURL(\(url.path))")
        guard let file else { throw TapError("ExtAudioFileCreateWithURL returned null") }
        self.extFile = file

        try check(
            ExtAudioFileSetProperty(
                file,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &asbd),
            "ExtAudioFileSetProperty(ClientDataFormat)")
        localGeneration = rebuildGeneration.load()
        lastNonZeroMach.store(MachClock.now())
    }

    deinit { scratch.deallocate() }

    // MARK: Lifecycle

    func start() {
        running = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "OpenAudio.FileWriter"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    /// Stops the loop, drains whatever remains, and finalizes the file.
    func stop() {
        running = false
        while thread?.isFinished == false {
            usleep(2000)
        }
        drainOnce(finalFlush: true)
        if let f = extFile {
            ExtAudioFileDispose(f)
            extFile = nil
        }
    }

    // MARK: Published readings (for watchdog / logging)

    func currentRMSdB() -> Float {
        let bits = UInt32(truncatingIfNeeded: rmsBits.load())
        let rms = Float(bitPattern: bits)
        return rms > 0 ? 20 * log10f(rms) : -Float.infinity
    }

    func secondsSinceLastNonZero() -> Double {
        MachClock.seconds(since: lastNonZeroMach.load())
    }

    func hasSeenAudio() -> Bool { everHadAudio.load() != 0 }

    // MARK: Worker

    private func run() {
        while running {
            let wrote = drainOnce(finalFlush: false)
            if wrote == 0 {
                usleep(3000) // 3 ms — ring empty, back off
            }
        }
    }

    /// Reads and writes at most one block (or loops to empty on final flush).
    @discardableResult
    private func drainOnce(finalFlush: Bool) -> Int {
        var total = 0
        repeat {
            let frames = ring.read(into: scratch, maxFrames: blockFrames)
            if frames == 0 { break }
            process(frames: frames)
            writeToFile(frames: frames)
            total += frames
        } while finalFlush
        return total
    }

    /// Applies gain + fade-in and performs silence detection on `frames`.
    private func process(frames: Int) {
        let count = vDSP_Length(frames * channels)

        // Exact bit-zero detection on the raw (pre-gain) block — gain never
        // changes zero-ness, so checking here is equivalent and cheap.
        var maxMag: Float = 0
        vDSP_maxmgv(scratch, 1, &maxMag, count)
        let now = MachClock.now()
        if maxMag != 0.0 {
            lastNonZeroMach.store(now)
            if everHadAudio.load() == 0 { everHadAudio.store(1) }
        }

        // Attenuation-compensation gain (constant).
        if compGain != 1.0 {
            var g = compGain
            vDSP_vsmul(scratch, 1, &g, scratch, 1, count)
        }

        // Detect a rebuild since last block -> arm a fresh fade-in.
        let gen = rebuildGeneration.load()
        if gen != localGeneration {
            localGeneration = gen
            fadeRemaining = fadeFrames
        }

        // Linear fade-in ramp across the first `fadeRemaining` frames.
        if fadeRemaining > 0 {
            let n = min(frames, fadeRemaining)
            let doneFrames = fadeFrames - fadeRemaining
            for i in 0..<n {
                let k = Float(doneFrames + i) / Float(fadeFrames)
                let base = (i * channels)
                for c in 0..<channels {
                    scratch[base + c] *= k
                }
            }
            fadeRemaining -= n
        }

        // Smoothed post-gain RMS for logging.
        var rms: Float = 0
        vDSP_rmsqv(scratch, 1, &rms, count)
        rmsSmoothed = rmsSmoothed * 0.8 + rms * 0.2
        rmsBits.store(UInt64(rmsSmoothed.bitPattern))
    }

    private func writeToFile(frames: Int) {
        guard let file = extFile else { return }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: scratch))
        let status = ExtAudioFileWrite(file, UInt32(frames), &abl)
        if status != noErr {
            Log.error("ExtAudioFileWrite failed: OSStatus \(osStatusString(status))")
        }
        framesWritten.add(UInt64(frames))
    }
}
