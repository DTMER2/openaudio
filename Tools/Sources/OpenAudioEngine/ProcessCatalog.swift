// ProcessCatalog.swift
// Public enumeration of Core Audio process objects (F-U3) plus PID -> process
// AudioObjectID translation. Ported from the Phase 0 tapcapture spike's
// ProcessList (which is left untouched as an independent probe). All calls run
// on non-realtime threads.

import Foundation
import CoreAudio
import AppKit

/// One audio-capable process known to the HAL.
public struct AudioProcessInfo {
    public var objectID: AudioObjectID
    public var pid: pid_t
    /// Best-effort display name (localized app name, else bundle ID, else pid).
    public var name: String
    public var bundleID: String?
    public var isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, name: String,
                bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public enum AudioProcessCatalog {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// All Core Audio process objects currently known to the HAL.
    public static func allProcessObjects() throws -> [AudioObjectID] {
        try CAProperty.array(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    /// Resolve one process object into display info (best-effort; never throws).
    public static func info(for object: AudioObjectID) -> AudioProcessInfo {
        let pid: pid_t = (try? CAProperty.scalar(
            object, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
        let rawBundle: String = (try? CAProperty.string(
            object, kAudioProcessPropertyBundleID)) ?? ""
        let bundleID: String? = rawBundle.isEmpty ? nil : rawBundle
        let runningOut: UInt32 = (try? CAProperty.scalar(
            object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

        var name = bundleID ?? ""
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            name = app.localizedName ?? app.bundleIdentifier ?? name
        }
        if name.isEmpty { name = "(pid \(pid))" }

        return AudioProcessInfo(
            objectID: object, pid: pid, name: name,
            bundleID: bundleID, isRunningOutput: runningOut != 0)
    }

    /// List audio-capable processes (F-U3), output-active first, then by PID.
    public static func listAudioProcesses() throws -> [AudioProcessInfo] {
        try allProcessObjects().map(info(for:)).sorted { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            return a.pid < b.pid
        }
    }

    /// Translate a Unix PID into a Core Audio process AudioObjectID (throws if
    /// the process has no audio process object — e.g. not producing audio).
    public static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = CAProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = pid
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(system, &addr,
                                       UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &obj),
            "TranslatePIDToProcessObject(pid: \(pid))")
        if obj == 0 {
            throw OAError("No Core Audio process object for PID \(pid) (is it running / producing audio?)")
        }
        return obj
    }

    /// responsibility_get_pid_responsible_for_pid: maps helper processes
    /// (browser audio services, WebKit GPU processes, XPC services) to the app
    /// responsible for them. Private but long-stable libsystem symbol; resolved
    /// dynamically so a removal degrades to identity instead of a link failure.
    private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePIDFn: ResponsiblePIDFn? = {
        // RTLD_DEFAULT (-2): search the global symbol scope.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsiblePIDFn.self)
    }()

    /// The PID of the app responsible for `pid` (the app itself for regular
    /// processes, the owning browser/app for its helpers). Falls back to `pid`.
    public static func responsiblePID(for pid: pid_t) -> pid_t {
        guard pid > 0, let fn = responsiblePIDFn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    /// All HAL process objects grouped by responsible PID. Browsers emit audio
    /// from helper processes, so capturing "an app" means tapping every process
    /// object in its group, not just the main PID's. Our own process is never a
    /// member of any group (feedback guard) — when launched from a terminal our
    /// responsible PID is the terminal's, so a leader-level check is not enough.
    public static func audioObjectsByResponsiblePID() throws -> [pid_t: [AudioObjectID]] {
        var out: [pid_t: [AudioObjectID]] = [:]
        let ownPid = getpid()
        for obj in try allProcessObjects() {
            let pid: pid_t = (try? CAProperty.scalar(
                obj, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
            guard pid > 0, pid != ownPid else { continue }
            out[responsiblePID(for: pid), default: []].append(obj)
        }
        return out
    }

    /// Best-effort resolution of THIS process's Core Audio process object, used
    /// to exclude ourselves from taps (feedback guard). Returns 0 if the HAL
    /// has not yet minted a process object for us (no audio produced yet).
    public static func ownProcessObject() -> AudioObjectID {
        var addr = CAProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = getpid()
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &obj)
        return st == noErr ? obj : 0
    }
}
