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

/// Publishes effective per-source (L, R) gains as atomic packed words.
public final class MixParamsStore: @unchecked Sendable {
    private let tapWord: Atomic64
    private let inputWord: Atomic64

    // Off-RT authoritative source parameters.
    public var tap = SourceParams()
    public var input = SourceParams()

    public init() {
        tapWord = Atomic64(packGainPair(1, 1))
        inputWord = Atomic64(packGainPair(1, 1))
        publish()
    }

    /// Raw pointers handed to the RT capture context (read-only there).
    public var tapWordPointer: UnsafeMutablePointer<UInt64> { tapWord.raw }
    public var inputWordPointer: UnsafeMutablePointer<UInt64> { inputWord.raw }

    /// Recomputes effective gains and atomically publishes them. Off-RT only;
    /// callers serialize (Engine uses its control queue).
    public func publish() {
        let (tl, tr) = Self.lr(tap)
        let (il, ir) = Self.lr(input)
        tapWord.store(packGainPair(tl, tr))
        inputWord.store(packGainPair(il, ir))
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
