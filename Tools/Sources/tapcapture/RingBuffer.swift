// RingBuffer.swift
// Single-producer / single-consumer lock-free ring buffer for interleaved
// Float32 audio. The producer is the realtime IOProc; the consumer is the
// writer thread. Monotonic 64-bit indices avoid empty/full ambiguity.
//
// Realtime discipline: the producer path (`RTContext.write`) performs no
// allocation, no locking, and no syscalls — only memcpy and barrier-guarded
// index publication through raw pointers captured in the IOProc block.

import Foundation
import CoreAudio
import Darwin

/// Plain-old-data view of the ring, captured by the realtime IOProc through a
/// single `UnsafeMutablePointer<RTContext>`. Trivial fields only, so the block
/// never triggers ARC.
struct RTContext {
    var storage: UnsafeMutablePointer<Float>
    var capacityFrames: Int
    var channels: Int
    var writeIndex: UnsafeMutablePointer<UInt64>   // producer-owned
    var readIndex: UnsafeMutablePointer<UInt64>    // consumer-owned
    var ioFrameCounter: UnsafeMutablePointer<UInt64>  // total frames seen by IOProc
    var overrunFrames: UnsafeMutablePointer<UInt64>   // frames dropped on full

    /// Realtime producer write. Copies up to `frames` interleaved frames from
    /// `src` (channels-interleaved Float32). Drops on overrun and records it.
    @inline(__always)
    func write(_ src: UnsafePointer<Float>, frames: Int) {
        if frames <= 0 { return }
        let w = writeIndex.pointee
        OSMemoryBarrier()
        let r = readIndex.pointee
        let used = Int(w &- r)
        let free = capacityFrames - used
        if free <= 0 {
            overrunFrames.pointee = overrunFrames.pointee &+ UInt64(frames)
            ioFrameCounter.pointee = ioFrameCounter.pointee &+ UInt64(frames)
            return
        }
        let toWrite = min(frames, free)
        if toWrite < frames {
            overrunFrames.pointee = overrunFrames.pointee &+ UInt64(frames - toWrite)
        }
        let startFrame = Int(w % UInt64(capacityFrames))
        let firstChunk = min(toWrite, capacityFrames - startFrame)
        let ch = channels
        memcpy(storage + startFrame * ch, src, firstChunk * ch * MemoryLayout<Float>.size)
        if toWrite > firstChunk {
            let secondChunk = toWrite - firstChunk
            memcpy(storage, src + firstChunk * ch, secondChunk * ch * MemoryLayout<Float>.size)
        }
        OSMemoryBarrier()
        writeIndex.pointee = w &+ UInt64(toWrite)
        ioFrameCounter.pointee = ioFrameCounter.pointee &+ UInt64(frames)
    }

    /// Realtime producer write from a scratch interleaving buffer. Same as
    /// `write` but takes a raw pointer already interleaved.
    @inline(__always)
    func writeRaw(_ src: UnsafeRawPointer, frames: Int) {
        write(src.assumingMemoryBound(to: Float.self), frames: frames)
    }
}

/// Owns all ring storage and index words for the session's lifetime. Survives
/// tap/aggregate rebuilds so the writer thread and crossfade state stay
/// continuous. Thread-safe by construction (SPSC): the producer only advances
/// `writeIndex`, the consumer only advances `readIndex`.
final class RingBuffer: @unchecked Sendable {
    let channels: Int
    let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>
    private let ioFrameCounter: UnsafeMutablePointer<UInt64>
    private let overrunFrames: UnsafeMutablePointer<UInt64>

    /// Stable context pointer handed to the realtime IOProc block.
    let contextPointer: UnsafeMutablePointer<RTContext>

    init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        let total = self.capacityFrames * self.channels

        storage = UnsafeMutablePointer<Float>.allocate(capacity: total)
        storage.initialize(repeating: 0, count: total)
        writeIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); writeIndex.pointee = 0
        readIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); readIndex.pointee = 0
        ioFrameCounter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); ioFrameCounter.pointee = 0
        overrunFrames = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); overrunFrames.pointee = 0

        contextPointer = UnsafeMutablePointer<RTContext>.allocate(capacity: 1)
        contextPointer.initialize(to: RTContext(
            storage: storage,
            capacityFrames: self.capacityFrames,
            channels: self.channels,
            writeIndex: writeIndex,
            readIndex: readIndex,
            ioFrameCounter: ioFrameCounter,
            overrunFrames: overrunFrames
        ))
    }

    deinit {
        contextPointer.deinitialize(count: 1)
        contextPointer.deallocate()
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
        ioFrameCounter.deallocate()
        overrunFrames.deallocate()
    }

    /// Total frames the IOProc has produced (advances even on overrun). Used by
    /// the watchdog to detect whether the IOProc is still firing.
    func ioFrameCount() -> UInt64 {
        OSMemoryBarrier()
        return ioFrameCounter.pointee
    }

    func overrunCount() -> UInt64 {
        OSMemoryBarrier()
        return overrunFrames.pointee
    }

    /// Consumer read. Copies up to `maxFrames` interleaved frames into `dst`,
    /// returns the number of frames copied. Called on the writer thread only.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let r = readIndex.pointee
        OSMemoryBarrier()
        let w = writeIndex.pointee
        let available = Int(w &- r)
        if available <= 0 { return 0 }
        let toRead = min(maxFrames, available)
        let startFrame = Int(r % UInt64(capacityFrames))
        let firstChunk = min(toRead, capacityFrames - startFrame)
        memcpy(dst, storage + startFrame * channels, firstChunk * channels * MemoryLayout<Float>.size)
        if toRead > firstChunk {
            let secondChunk = toRead - firstChunk
            memcpy(dst + firstChunk * channels, storage, secondChunk * channels * MemoryLayout<Float>.size)
        }
        OSMemoryBarrier()
        readIndex.pointee = r &+ UInt64(toRead)
        return toRead
    }
}
