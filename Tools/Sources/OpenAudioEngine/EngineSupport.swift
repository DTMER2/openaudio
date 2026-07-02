// EngineSupport.swift
// Shared, non-realtime utilities for the OpenAudio engine: logging, errors,
// OSStatus formatting, mach-time helpers, barrier-based atomics (used only for
// cross-thread coordination, never inside the RT IOProcs), and Core Audio
// property helpers. Adapted from the Phase 0 tapcapture spike.

import Foundation
import CoreAudio
import Darwin

// MARK: - Logging

/// Timestamped stderr logger. All diagnostics go to stderr so stdout stays
/// clean for machine-readable output.
public enum OALog {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func line(_ message: String) {
        let ts = iso.string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
    }

    public static func info(_ message: String)  { line("INFO  \(message)") }
    public static func warn(_ message: String)  { line("WARN  \(message)") }
    public static func error(_ message: String) { line("ERROR \(message)") }
    public static func event(_ message: String) { line("EVENT \(message)") }
}

// MARK: - Errors

public struct OAError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { self.description = message }
}

/// Turns an OSStatus into a readable string, decoding the classic 4-char-code
/// form when the bytes are printable.
public func osStatusString(_ status: OSStatus) -> String {
    let code = UInt32(bitPattern: status)
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return "\(status) ('\(s)')"
    }
    return "\(status)"
}

@discardableResult
public func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    if status != noErr {
        throw OAError("\(what) failed: OSStatus \(osStatusString(status))")
    }
    return status
}

/// Renders a four-char-code selector for logging.
public func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
    return "\(value)"
}

// MARK: - Mach time

public enum MachClock {
    public static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(since start: UInt64) -> Double {
        let now = mach_absolute_time()
        guard now > start else { return 0 }
        let deltaNanos = (now - start) &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return Double(deltaNanos) / 1_000_000_000.0
    }
}

// MARK: - Barrier-based atomic (non-realtime coordination only)

/// A minimal 64-bit "atomic" built on a naturally-aligned heap word plus full
/// memory barriers. On arm64/x86_64 an aligned 64-bit load/store is atomic at
/// the hardware level; the barriers guard against compiler/CPU reordering.
///
/// Used only for cross-thread coordination (counters, timestamps, generation
/// numbers, published Float/Double snapshots). The RT IOProcs touch the raw
/// index/state pointers directly to stay free of ARC and refcount traffic.
public final class Atomic64: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<UInt64>

    public init(_ value: UInt64 = 0) {
        ptr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        ptr.pointee = value
    }

    deinit { ptr.deallocate() }

    /// Raw pointer for use by an RT path (single-writer semantics).
    public var raw: UnsafeMutablePointer<UInt64> { ptr }

    public func load() -> UInt64 {
        OSMemoryBarrier()
        return ptr.pointee
    }

    public func store(_ value: UInt64) {
        ptr.pointee = value
        OSMemoryBarrier()
    }

    /// Read-modify-write. Only safe when called from a single writer thread.
    public func add(_ value: UInt64) {
        OSMemoryBarrier()
        ptr.pointee = ptr.pointee &+ value
        OSMemoryBarrier()
    }

    // Float / Double convenience (stored as bit patterns).
    public func storeFloat(_ v: Float)  { store(UInt64(v.bitPattern)) }
    public func loadFloat() -> Float     { Float(bitPattern: UInt32(truncatingIfNeeded: load())) }
    public func storeDouble(_ v: Double) { store(v.bitPattern) }
    public func loadDouble() -> Double   { Double(bitPattern: load()) }
}

// MARK: - Core Audio property helpers (main / non-realtime threads only)

public enum CAProperty {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size scalar property (AudioObjectID, UInt32, pid_t, ...).
    public static func scalar<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        default defaultValue: T
    ) throws -> T {
        var addr = address(selector, scope, element)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { rawBuffer -> Void in
            try check(
                AudioObjectGetPropertyData(object, &addr, 0, nil, &size, rawBuffer.baseAddress!),
                "AudioObjectGetPropertyData(selector: \(fourCC(selector)))"
            )
        }
        return value
    }

    /// Reads a variable-size property into an array of fixed-size elements.
    public static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        of type: T.Type
    ) throws -> [T] {
        var addr = address(selector, scope, element)
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &dataSize),
            "AudioObjectGetPropertyDataSize(selector: \(fourCC(selector)))"
        )
        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return Array<T>(unsafeUninitializedCapacity: count) { buffer, initialized in
            var size = dataSize
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? count : 0
        }
    }

    /// Reads a CFString property (UID / bundle ID / name) as a Swift String.
    public static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var addr = address(selector, scope, element)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        try check(
            withUnsafeMutablePointer(to: &value) { ptr in
                AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
            },
            "AudioObjectGetPropertyData(string, selector: \(fourCC(selector)))"
        )
        return value as String? ?? ""
    }
}
