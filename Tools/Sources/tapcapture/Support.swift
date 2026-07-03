// Support.swift
// Shared utilities: logging, mach-time helpers, Core Audio property access,
// and a small barrier-based atomic used off the realtime path.

import Foundation
import CoreAudio
import Darwin

// MARK: - Logging

/// Timestamped stderr logger. All diagnostics go to stderr so stdout stays
/// clean for machine-readable output (e.g. the `--list` table).
enum Log {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func line(_ message: String) {
        let ts = iso.string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
    }

    static func info(_ message: String)  { line("INFO  \(message)") }
    static func warn(_ message: String)  { line("WARN  \(message)") }
    static func error(_ message: String) { line("ERROR \(message)") }
    static func event(_ message: String) { line("EVENT \(message)") }
}

// MARK: - Errors

struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// Turns an OSStatus into a readable string, decoding the classic 4-char-code
/// form when the bytes are printable.
func osStatusString(_ status: OSStatus) -> String {
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
func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    if status != noErr {
        throw TapError("\(what) failed: OSStatus \(osStatusString(status))")
    }
    return status
}

// MARK: - Mach time

enum MachClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func seconds(since start: UInt64) -> Double {
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
/// This is used only for cross-thread coordination counters (frame counters,
/// timestamps, generation numbers) — not inside the realtime IOProc, which
/// touches the raw pointers directly to stay free of ARC and refcount traffic.
final class Atomic64: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<UInt64>

    init(_ value: UInt64 = 0) {
        ptr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        ptr.pointee = value
    }

    deinit { ptr.deallocate() }

    /// Raw pointer for use by the realtime path (single-writer semantics).
    var raw: UnsafeMutablePointer<UInt64> { ptr }

    func load() -> UInt64 {
        OSMemoryBarrier()
        return ptr.pointee
    }

    func store(_ value: UInt64) {
        ptr.pointee = value
        OSMemoryBarrier()
    }

    /// Read-modify-write. Only safe when called from a single writer thread.
    func add(_ value: UInt64) {
        OSMemoryBarrier()
        ptr.pointee = ptr.pointee &+ value
        OSMemoryBarrier()
    }
}

// MARK: - Core Audio property helpers (main / non-realtime threads only)

enum CAProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size scalar property (e.g. AudioObjectID, UInt32, pid_t).
    static func scalar<T>(
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
    static func array<T>(
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

    /// Reads a CFString property (e.g. UID / bundle ID) as a Swift String.
    static func string(
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

    static func hasProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(object, &addr)
    }
}

/// Renders a four-char-code selector for logging.
func fourCC(_ value: UInt32) -> String {
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
