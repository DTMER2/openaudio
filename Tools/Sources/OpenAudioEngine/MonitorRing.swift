// MonitorRing.swift
// Single-producer / single-consumer lock-free ring for interleaved Float32.
// Producer is the realtime capture IOProc; consumer is the monitor/recorder
// thread. Drops the *newest* frames on overflow (never blocks, never touches
// the reader's index) — matching the proven Phase 0 writer ring. Used for
// off-RT metering and optional file recording, not the audio-critical bridge.

import Foundation
import Darwin

/// POD view captured by the RT producer through a single pointer.
public struct MonRTContext {
    public var storage: UnsafeMutablePointer<Float>
    public var capacityFrames: Int
    public var channels: Int
    public var writeIndex: UnsafeMutablePointer<UInt64>
    public var readIndex: UnsafeMutablePointer<UInt64>
    public var overrunFrames: UnsafeMutablePointer<UInt64>

    /// RT producer write. Drops newest on full; records the drop count.
    @inline(__always)
    public func write(_ src: UnsafePointer<Float>, frames: Int) {
        if frames <= 0 { return }
        let w = writeIndex.pointee
        let r = readIndex.pointee
        // Fence after the index loads. (A stale `r` only under-estimates free
        // space, which is safe; the fence keeps ordering strict regardless.)
        OSMemoryBarrier()
        let used = Int(w &- r)
        let free = capacityFrames - used
        if free <= 0 {
            overrunFrames.pointee = overrunFrames.pointee &+ UInt64(frames)
            return
        }
        let toWrite = min(frames, free)
        if toWrite < frames {
            overrunFrames.pointee = overrunFrames.pointee &+ UInt64(frames - toWrite)
        }
        let start = Int(w % UInt64(capacityFrames))
        let firstChunk = min(toWrite, capacityFrames - start)
        let ch = channels
        memcpy(storage + start * ch, src, firstChunk * ch * MemoryLayout<Float>.size)
        if toWrite > firstChunk {
            memcpy(storage, src + firstChunk * ch, (toWrite - firstChunk) * ch * MemoryLayout<Float>.size)
        }
        OSMemoryBarrier()
        writeIndex.pointee = w &+ UInt64(toWrite)
    }
}

public final class MonitorRing: @unchecked Sendable {
    public let channels: Int
    public let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>
    private let overrunFrames: UnsafeMutablePointer<UInt64>

    public let contextPointer: UnsafeMutablePointer<MonRTContext>

    public init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        let total = self.capacityFrames * self.channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: total)
        storage.initialize(repeating: 0, count: total)
        writeIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); writeIndex.pointee = 0
        readIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); readIndex.pointee = 0
        overrunFrames = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); overrunFrames.pointee = 0
        contextPointer = UnsafeMutablePointer<MonRTContext>.allocate(capacity: 1)
        contextPointer.initialize(to: MonRTContext(
            storage: storage,
            capacityFrames: self.capacityFrames,
            channels: self.channels,
            writeIndex: writeIndex,
            readIndex: readIndex,
            overrunFrames: overrunFrames))
    }

    deinit {
        contextPointer.deinitialize(count: 1)
        contextPointer.deallocate()
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
        overrunFrames.deallocate()
    }

    public func overrunCount() -> UInt64 {
        OSMemoryBarrier()
        return overrunFrames.pointee
    }

    /// Consumer read of up to `maxFrames` interleaved frames. Monitor thread only.
    public func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let r = readIndex.pointee
        let w = writeIndex.pointee
        // Acquire: order the storage reads below after the writeIndex load so
        // we never copy frames the producer's release hasn't published.
        OSMemoryBarrier()
        let available = Int(w &- r)
        if available <= 0 { return 0 }
        let toRead = min(maxFrames, available)
        let start = Int(r % UInt64(capacityFrames))
        let firstChunk = min(toRead, capacityFrames - start)
        memcpy(dst, storage + start * channels, firstChunk * channels * MemoryLayout<Float>.size)
        if toRead > firstChunk {
            memcpy(dst + firstChunk * channels, storage, (toRead - firstChunk) * channels * MemoryLayout<Float>.size)
        }
        OSMemoryBarrier()
        readIndex.pointee = r &+ UInt64(toRead)
        return toRead
    }
}
