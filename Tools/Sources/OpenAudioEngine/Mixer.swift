// Mixer.swift
// Per-source mix parameters (gain / mute / pan) delivered to the realtime
// capture callback as packed 64-bit words: each source's effective (L, R)
// linear gain pair is precomputed off-RT and published as ONE atomic 64-bit
// word, so the RT reader can never observe a torn pair — a single aligned
// 64-bit load is atomic on arm64/x86_64. (Tap and input words are separate;
// a momentary old-tap/new-input combination across a simultaneous update is
// benign for gains.) Setters run off the RT thread, serialized by the caller.

import Foundation
import Darwin

/// One source's user-facing parameters.
public struct SourceParams {
    public var gainDB: Float = 0
    public var pan: Float = 0        // -1 (L) .. +1 (R)
    public var muted: Bool = false

    public init() {}
}

@inline(__always)
public func packGainPair(_ l: Float, _ r: Float) -> UInt64 {
    (UInt64(l.bitPattern) << 32) | UInt64(r.bitPattern)
}

@inline(__always)
public func unpackGainPair(_ w: UInt64) -> (Float, Float) {
    (Float(bitPattern: UInt32(truncatingIfNeeded: w >> 32)),
     Float(bitPattern: UInt32(truncatingIfNeeded: w)))
}

/// Monitor selection snapshot (F-M1/M2): the selected bus index (Int32; < 0 =
/// monitoring off) and a LINEAR gain, packed into one aligned 64-bit word so
/// the RT capture callback reads the pair with a single non-torn load — same
/// discipline as the per-source gain words. High 32 bits = bus, low 32 = gain.
@inline(__always)
public func packMonitor(bus: Int32, gain: Float) -> UInt64 {
    (UInt64(UInt32(bitPattern: bus)) << 32) | UInt64(gain.bitPattern)
}

@inline(__always)
public func unpackMonitor(_ w: UInt64) -> (Int32, Float) {
    (Int32(bitPattern: UInt32(truncatingIfNeeded: w >> 32)),
     Float(bitPattern: UInt32(truncatingIfNeeded: w)))
}

/// Publishes effective per-source (L, R) gains as atomic packed words.
/// Sources are N tap lanes (one per tapped app, or one for the system tap)
/// followed by the optional input device; the input word always lives at index
/// `tapCount` so the RT context can index lanes without conditionals.
public final class MixParamsStore: @unchecked Sendable {
    public let tapCount: Int

    // Off-RT authoritative source parameters.
    public var taps: [SourceParams]
    public var input = SourceParams()

    // Contiguous packed (L,R) gain words: 0..<tapCount taps, tapCount = input.
    // Each is an aligned 64-bit word, so a plain load/store is never torn on
    // arm64/x86_64 (same discipline as Atomic64).
    private let words: UnsafeMutablePointer<UInt64>

    public init(tapCount: Int) {
        self.tapCount = max(0, tapCount)
        self.taps = Array(repeating: SourceParams(), count: self.tapCount)
        self.words = UnsafeMutablePointer<UInt64>.allocate(capacity: self.tapCount + 1)
        self.words.initialize(repeating: packGainPair(1, 1), count: self.tapCount + 1)
        publish()
    }

    deinit { words.deallocate() }

    /// Raw pointer handed to the RT capture context (read-only there).
    public var wordsPointer: UnsafeMutablePointer<UInt64> { words }

    /// Recomputes effective gains and atomically publishes them. Off-RT only;
    /// callers serialize (Engine uses its control queue).
    public func publish() {
        for i in 0..<tapCount {
            let (l, r) = Self.lr(taps[i])
            words[i] = packGainPair(l, r)
        }
        let (il, ir) = Self.lr(input)
        words[tapCount] = packGainPair(il, ir)
        OSMemoryBarrier()
    }

    /// Equal-power pan + gain + mute -> (leftGain, rightGain).
    static func lr(_ p: SourceParams) -> (Float, Float) {
        if p.muted { return (0, 0) }
        let g = powf(10, p.gainDB / 20)
        // Equal-power balance law: theta in [0, pi/2].
        let theta = (max(-1, min(1, p.pan)) + 1) * 0.5 * (Float.pi / 2)
        return (g * cosf(theta), g * sinf(theta))
    }
}
