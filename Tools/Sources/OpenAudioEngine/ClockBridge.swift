// ClockBridge.swift
// The Phase 1 clock boundary (NF-S2/S3): a preallocated SPSC ring between the
// capture IOProc (producer, hardware clock) and the virtual-device IOProc
// (consumer, driver clock). Both run near 48 kHz but drift by ~ppm.
//
// The consumer runs a variable-ratio Catmull-Rom resampler whose ratio is
// steered by a PI controller on the ring fill level (target ~= a few IO
// buffers). All consumer math is plain arithmetic executed in the RT callback;
// no allocation, locks, ObjC, or syscalls. Statistics are published through
// barrier-guarded 64-bit words the CLI reads off-thread.
//
// Overflow discipline: the producer only advances the write index (never the
// reader's), so on ring overrun the consumer detects that the oldest frames
// were overwritten and drops them (drop-oldest), keeping latency current. In
// steady state the PI keeps fill far below capacity so this never triggers.

import Foundation
import CoreAudio
import Darwin

/// POD state for the consumer resampler + PI controller. Mutated only by the
/// virtual-device IOProc (single thread); read via published atomics elsewhere.
public struct ConsumerCtx {
    // Ring storage (stereo interleaved).
    public var storage: UnsafeMutablePointer<Float>
    public var capacityFrames: Int
    public var writeIndex: UnsafeMutablePointer<UInt64>   // producer-owned
    public var readIndex: UnsafeMutablePointer<UInt64>    // consumer-owned

    // Resampler / controller state.
    public var readPos: Double        // absolute fractional frame index
    public var ratio: Double          // input frames consumed per output frame
    public var integral: Double       // PI integral term (unitless * seconds)
    public var prefilled: Bool

    // Constants / off-RT-updatable.
    // baseRatio = captureRate / deviceRate (≈1). Published as a Double bit
    // pattern in an atomic word so a capture rebuild onto a device with a
    // different nominal rate can retune the bridge without tearing.
    public var baseRatioBits: UnsafeMutablePointer<UInt64>
    public var targetFrames: Double
    public var kpPPM: Double
    public var kiPPM: Double
    public var maxPPM: Double
    public var sampleRate: Double     // device (consumer) rate

    // Published stats (barrier-guarded words).
    public var underrunFrames: UnsafeMutablePointer<UInt64>
    public var overrunFrames: UnsafeMutablePointer<UInt64>
    public var consumerCallbacks: UnsafeMutablePointer<UInt64>
    public var fillFrames: UnsafeMutablePointer<UInt64>
    public var ratioPPMBits: UnsafeMutablePointer<UInt64>   // Double bit pattern
}

@inline(__always)
private func catmullRom(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
    // Interpolates between y1 (t=0) and y2 (t=1).
    let c0 = y1
    let c1 = 0.5 * (y2 - y0)
    let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
    let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
    return ((c3 * t + c2) * t + c1) * t + c0
}

/// Consumer RT entry point: fills `frames` of interleaved `channels` output
/// (bus into channels 0/1, rest zeroed) from the bridge ring. Pure arithmetic.
/// `channels` MUST be the actual buffer's channel count (the same value used
/// to derive `frames` from the byte size) so memset and stride can never
/// overrun the device buffer, even if the device layout differs from the
/// init-time property.
@inline(__always)
public func bridgeConsume(_ ctxPtr: UnsafeMutablePointer<ConsumerCtx>,
                          out: UnsafeMutablePointer<Float>,
                          frames: Int,
                          channels: Int) {
    let outCh = channels
    if outCh < 2 || frames <= 0 { return }
    // Zero the whole output block up front; unfilled frames stay silent.
    memset(out, 0, frames * outCh * MemoryLayout<Float>.size)

    let w = ctxPtr.pointee.writeIndex.pointee
    // Acquire: order all payload (storage) reads after the writeIndex load, so
    // we never read frames the producer's release barrier hasn't published.
    OSMemoryBarrier()
    var r = ctxPtr.pointee.readIndex.pointee
    let capacity = UInt64(ctxPtr.pointee.capacityFrames)

    // Drop-oldest on overrun: consumer lost the frames beyond capacity.
    let used = w &- r
    if used > capacity {
        let drop = used - capacity
        r = w &- capacity
        ctxPtr.pointee.readIndex.pointee = r
        // Recovery policy: jump the read position to `target` behind the
        // writer (not to the oldest surviving frame — that would pin latency
        // at ~capacity and take the PI ages to unwind at ±maxPPM). Frames
        // skipped by the jump are counted as overrun drops too.
        let target = ctxPtr.pointee.targetFrames
        var pos = Double(w) - target
        let floorPos = Double(r) + 1
        if pos < floorPos { pos = floorPos }
        var totalDrop = drop
        if ctxPtr.pointee.readPos < pos {
            totalDrop &+= UInt64(pos - ctxPtr.pointee.readPos)
            ctxPtr.pointee.readPos = pos
        }
        ctxPtr.pointee.overrunFrames.pointee = ctxPtr.pointee.overrunFrames.pointee &+ totalDrop
        ctxPtr.pointee.integral = 0   // stale wind-up no longer meaningful
    }

    ctxPtr.pointee.consumerCallbacks.pointee = ctxPtr.pointee.consumerCallbacks.pointee &+ 1

    // Full starvation (producer down, e.g. capture rebuild): re-arm the
    // prefill so playback resumes with the target cushion instead of
    // drip-feeding, and reset the integrator that wound up while draining.
    if ctxPtr.pointee.prefilled && Double(w) - ctxPtr.pointee.readPos < 4 {
        ctxPtr.pointee.prefilled = false
        ctxPtr.pointee.integral = 0
    }

    // Startup / restart: hold silence until the ring is prefilled to target.
    if !ctxPtr.pointee.prefilled {
        let avail = w &- r
        if Double(avail) < ctxPtr.pointee.targetFrames {
            ctxPtr.pointee.fillFrames.pointee = avail
            return
        }
        ctxPtr.pointee.prefilled = true
        ctxPtr.pointee.readPos = Double(r) + 1   // keep one history sample behind
        ctxPtr.pointee.integral = 0
    }

    // PI controller on fill error (normalized by target).
    let fill = Double(w) - ctxPtr.pointee.readPos
    let target = ctxPtr.pointee.targetFrames
    let e = (fill - target) / target
    let dt = Double(frames) / ctxPtr.pointee.sampleRate
    var integral = ctxPtr.pointee.integral + e * dt
    // Clamp integral so its contribution alone can't exceed maxPPM.
    let ki = ctxPtr.pointee.kiPPM
    if ki > 0 {
        let bound = ctxPtr.pointee.maxPPM / ki
        if integral > bound { integral = bound }
        if integral < -bound { integral = -bound }
    } else {
        integral = 0   // no integral action configured; don't accumulate
    }
    ctxPtr.pointee.integral = integral
    var ppm = ctxPtr.pointee.kpPPM * e + ki * integral
    if ppm > ctxPtr.pointee.maxPPM { ppm = ctxPtr.pointee.maxPPM }
    if ppm < -ctxPtr.pointee.maxPPM { ppm = -ctxPtr.pointee.maxPPM }
    let baseRatio = Double(bitPattern: ctxPtr.pointee.baseRatioBits.pointee)
    let ratio = baseRatio * (1.0 + ppm * 1e-6)
    ctxPtr.pointee.ratio = ratio
    ctxPtr.pointee.ratioPPMBits.pointee = ppm.bitPattern

    let storage = ctxPtr.pointee.storage
    var readPos = ctxPtr.pointee.readPos
    var producedUnderrun: UInt64 = 0

    var j = 0
    while j < frames {
        let i0 = UInt64(readPos.rounded(.down))
        // Need history sample i0-1 and forward sample i0+2 to be present.
        if !(i0 >= r &+ 1 && i0 &+ 2 < w) {
            producedUnderrun += UInt64(frames - j)   // rest of block stays silent
            break
        }
        let t = Float(readPos - Double(i0))
        let im1 = Int((i0 &- 1) % capacity) * 2
        let i0i = Int(i0 % capacity) * 2
        let ip1 = Int((i0 &+ 1) % capacity) * 2
        let ip2 = Int((i0 &+ 2) % capacity) * 2
        let base = j * outCh
        // Left
        out[base] = catmullRom(storage[im1], storage[i0i], storage[ip1], storage[ip2], t)
        // Right
        out[base + 1] = catmullRom(storage[im1 + 1], storage[i0i + 1], storage[ip1 + 1], storage[ip2 + 1], t)
        readPos += ratio
        j += 1
    }

    ctxPtr.pointee.readPos = readPos
    if producedUnderrun > 0 {
        ctxPtr.pointee.underrunFrames.pointee = ctxPtr.pointee.underrunFrames.pointee &+ producedUnderrun
    }

    // Free consumed frames: keep one history sample behind readPos.
    let newR = UInt64(readPos.rounded(.down)) &- 1
    if newR > r { ctxPtr.pointee.readIndex.pointee = newR; r = newR }

    ctxPtr.pointee.fillFrames.pointee = w &- r
}

/// Owns the bridge ring storage and the consumer context. Survives capture
/// rebuilds (the producer side is torn down/rebuilt independently).
public final class ClockBridge: @unchecked Sendable {
    public let capacityFrames: Int
    public let targetFrames: Int

    private let storage: UnsafeMutablePointer<Float>   // stereo interleaved
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>
    private let producedFrames = Atomic64(0)
    private let producerCallbacks = Atomic64(0)

    // Consumer stats words.
    private let underrunFrames = Atomic64(0)
    private let overrunFrames = Atomic64(0)
    private let consumerCallbacks = Atomic64(0)
    private let fillFrames = Atomic64(0)
    private let ratioPPMBits = Atomic64(0)
    private let baseRatioBits: Atomic64

    public let consumerCtxPointer: UnsafeMutablePointer<ConsumerCtx>

    public init(capacityFrames: Int,
                targetFrames: Int,
                baseRatio: Double,
                deviceSampleRate: Double,
                kpPPM: Double,
                kiPPM: Double,
                maxPPM: Double) {
        self.capacityFrames = max(1024, capacityFrames)
        self.targetFrames = max(64, targetFrames)   // guard against div-by-zero/NaN in the PI
        self.baseRatioBits = Atomic64(baseRatio.bitPattern)
        let total = self.capacityFrames * 2
        storage = UnsafeMutablePointer<Float>.allocate(capacity: total)
        storage.initialize(repeating: 0, count: total)
        writeIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); writeIndex.pointee = 0
        readIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); readIndex.pointee = 0

        consumerCtxPointer = UnsafeMutablePointer<ConsumerCtx>.allocate(capacity: 1)
        consumerCtxPointer.initialize(to: ConsumerCtx(
            storage: storage,
            capacityFrames: self.capacityFrames,
            writeIndex: writeIndex,
            readIndex: readIndex,
            readPos: 0,
            ratio: baseRatio,
            integral: 0,
            prefilled: false,
            baseRatioBits: baseRatioBits.raw,
            targetFrames: Double(self.targetFrames),
            kpPPM: kpPPM,
            kiPPM: kiPPM,
            maxPPM: maxPPM,
            sampleRate: deviceSampleRate,
            underrunFrames: underrunFrames.raw,
            overrunFrames: overrunFrames.raw,
            consumerCallbacks: consumerCallbacks.raw,
            fillFrames: fillFrames.raw,
            ratioPPMBits: ratioPPMBits.raw))
    }

    deinit {
        consumerCtxPointer.deinitialize(count: 1)
        consumerCtxPointer.deallocate()
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    // MARK: Producer (RT capture callback)

    /// Raw fields the capture context needs to push stereo frames.
    public var storagePointer: UnsafeMutablePointer<Float> { storage }
    public var writeIndexPointer: UnsafeMutablePointer<UInt64> { writeIndex }
    public var producedFramesPointer: UnsafeMutablePointer<UInt64> { producedFrames.raw }
    public var producerCallbacksPointer: UnsafeMutablePointer<UInt64> { producerCallbacks.raw }

    /// Retunes the nominal capture/device rate ratio (off-RT; e.g. after a
    /// capture rebuild onto a default output device with a different rate).
    /// The consumer picks it up atomically on its next callback.
    public func setBaseRatio(_ ratio: Double) {
        baseRatioBits.storeDouble(ratio)
    }

    public func currentBaseRatio() -> Double { baseRatioBits.loadDouble() }

    // MARK: Stats (off-RT)

    public struct Stats {
        public var fillFrames: Int
        public var fillPct: Double
        public var ratioPPM: Double
        public var underruns: UInt64
        public var overruns: UInt64
        public var producedFrames: UInt64
        public var producerCallbacks: UInt64
        public var consumerCallbacks: UInt64
    }

    public func stats() -> Stats {
        let fill = Int(fillFrames.load())
        return Stats(
            fillFrames: fill,
            fillPct: targetFrames > 0 ? Double(fill) / Double(targetFrames) * 100.0 : 0,
            ratioPPM: ratioPPMBits.loadDouble(),
            underruns: underrunFrames.load(),
            overruns: overrunFrames.load(),
            producedFrames: producedFrames.load(),
            producerCallbacks: producerCallbacks.load(),
            consumerCallbacks: consumerCallbacks.load())
    }
}

/// RT producer push of stereo interleaved frames into the bridge ring.
/// Advances only the write index; the consumer handles drop-oldest.
@inline(__always)
public func bridgePush(storage: UnsafeMutablePointer<Float>,
                       capacityFrames: Int,
                       writeIndex: UnsafeMutablePointer<UInt64>,
                       producedFrames: UnsafeMutablePointer<UInt64>,
                       src: UnsafePointer<Float>,
                       frames: Int) {
    if frames <= 0 { return }
    let w = writeIndex.pointee
    let start = Int(w % UInt64(capacityFrames))
    let firstChunk = min(frames, capacityFrames - start)
    memcpy(storage + start * 2, src, firstChunk * 2 * MemoryLayout<Float>.size)
    if frames > firstChunk {
        memcpy(storage, src + firstChunk * 2, (frames - firstChunk) * 2 * MemoryLayout<Float>.size)
    }
    OSMemoryBarrier()
    writeIndex.pointee = w &+ UInt64(frames)
    producedFrames.pointee = producedFrames.pointee &+ UInt64(frames)
}
