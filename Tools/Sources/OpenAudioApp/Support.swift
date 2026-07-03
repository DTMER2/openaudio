// Support.swift
// Small value types, formatting, and the meter dB→geometry mapping shared across
// the OpenAudio SwiftUI app. No engine or UI dependencies beyond SwiftUI's Color.

import SwiftUI
import CoreAudio

// MARK: - Source / routing model

/// A UI-facing mix source: the system-wide tap, one tapped app, or the input
/// device. Mapped onto engine tap lanes (OpenAudioEngine.EngineSource) by
/// AppModel using the lane order of the running engine.
enum SourceKind: Hashable {
    case system
    case app(pid_t)
    case input
}

/// A single (source, bus) routing cell. Bus index is 0-based.
struct RouteKey: Hashable {
    var source: SourceKind
    var bus: Int
}

/// Per-app (or per-lane) desired mix parameters, kept across engine restarts.
struct AppLaneParams: Hashable {
    var gainDB: Float = 0
    var pan: Float = 0
    var muted = false
}

/// Real input-device selection for the optional microphone / interface lane.
enum InputSelection: Hashable {
    case none
    case systemDefault
    case device(uid: String, name: String)

    /// The value handed to EngineConfig.inputDeviceUID (nil == no input lane).
    var configUID: String? {
        switch self {
        case .none:           return nil
        case .systemDefault:  return "default"
        case .device(let u, _): return u
        }
    }

    var isActive: Bool { configUID != nil }

    var label: String {
        switch self {
        case .none:           return "None"
        case .systemDefault:  return "Default input"
        case .device(_, let n): return n
        }
    }
}

/// A refreshable snapshot row for the running-process list (F-U3).
struct ProcRow: Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var objectID: AudioObjectID
    var name: String
    var bundleID: String?
    var isRunningOutput: Bool
    /// True for regular user-facing apps (used to sort them above daemons).
    var isUserApp: Bool = false

    /// Human-friendly name: when the catalog only knows a bundle ID
    /// ("com.apple.mediaremoted"), show its last component instead.
    var displayName: String {
        if name.contains(" ") || !name.contains(".") { return name }
        return name.split(separator: ".").last.map(String.init) ?? name
    }
}

// MARK: - Formatting

enum Fmt {
    /// dBFS with a graceful -∞ for silence.
    static func dB(_ v: Float) -> String {
        v.isFinite ? String(format: "%+.1f dB", v) : "−∞ dB"
    }

    static func dBShort(_ v: Float) -> String {
        v.isFinite ? String(format: "%.0f", v) : "−∞"
    }

    /// mm:ss elapsed clock.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// A decaying max-hold for a stereo meter — the "peak line" that rides the
/// maximum level then slowly falls. Advanced at the meter poll cadence by
/// AppModel (so it keeps decaying during silence, which value-change
/// observation alone could not drive). Values are dBFS with a -∞ floor.
struct PeakHold: Equatable {
    var l: Float = -.infinity
    var r: Float = -.infinity
    var lTicks: Int = 0
    var rTicks: Int = 0
}

// MARK: - Meter geometry / zones

enum Meter {
    static let minDB: Float = -60
    static let maxDB: Float = 0

    /// Map a dBFS reading to a 0…1 fill fraction. -∞ and NaN fall to 0.
    static func fraction(_ db: Float) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(minDB, min(maxDB, db))
        return CGFloat((clamped - minDB) / (maxDB - minDB))
    }

    /// Zone color for a peak reading (green / yellow / red).
    static func color(_ db: Float) -> Color {
        if !db.isFinite { return .green }
        if db >= -3 { return .red }
        if db >= -12 { return .yellow }
        return .green
    }

    /// The green→yellow→red gradient used to paint a filled meter.
    static let gradient = LinearGradient(
        stops: [
            .init(color: .green, location: 0.0),
            .init(color: .green, location: 0.72),   // up to ~ -12 dB
            .init(color: .yellow, location: 0.80),  // ~ -12 dB
            .init(color: .orange, location: 0.94),  // ~ -3 dB
            .init(color: .red, location: 1.0),
        ],
        startPoint: .bottom, endPoint: .top)

    static let gradientH = LinearGradient(
        stops: [
            .init(color: .green, location: 0.0),
            .init(color: .green, location: 0.72),
            .init(color: .yellow, location: 0.80),
            .init(color: .orange, location: 0.94),
            .init(color: .red, location: 1.0),
        ],
        startPoint: .leading, endPoint: .trailing)
}
