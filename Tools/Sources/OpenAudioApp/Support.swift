// Support.swift
// Small value types, formatting, and the meter dB→geometry mapping shared across
// the OpenAudio SwiftUI app. No engine or UI dependencies beyond SwiftUI's Color.

import SwiftUI
import CoreAudio

// MARK: - Source / routing model

/// The two engine source lanes (mirrors OpenAudioEngine.EngineSource without
/// importing it into value types used by the views).
enum SourceKind: Hashable {
    case tap
    case input
}

/// A single (source, bus) routing cell. Bus index is 0-based.
struct RouteKey: Hashable {
    var source: SourceKind
    var bus: Int
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
