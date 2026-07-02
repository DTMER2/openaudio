// ProcessList.swift
// Enumeration of Core Audio process objects (`--list`) and PID -> AudioObjectID
// translation used when building taps for specific processes.

import Foundation
import CoreAudio
import AppKit

struct AudioProcessInfo {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var name: String
    var isRunningOutput: Bool
}

enum ProcessCatalog {
    /// All Core Audio process objects currently known to the HAL.
    static func allProcessObjects() throws -> [AudioObjectID] {
        try CAProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self
        )
    }

    static func info(for object: AudioObjectID) -> AudioProcessInfo {
        let pid: pid_t = (try? CAProperty.scalar(
            object, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
        let bundleID: String = (try? CAProperty.string(
            object, kAudioProcessPropertyBundleID)) ?? ""
        let runningOut: UInt32 = (try? CAProperty.scalar(
            object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

        var name = bundleID
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            name = app.localizedName ?? app.bundleIdentifier ?? bundleID
        }
        if name.isEmpty { name = "(pid \(pid))" }

        return AudioProcessInfo(
            objectID: object,
            pid: pid,
            bundleID: bundleID,
            name: name,
            isRunningOutput: runningOut != 0
        )
    }

    static func allInfos() throws -> [AudioProcessInfo] {
        try allProcessObjects().map(info(for:)).sorted { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            return a.pid < b.pid
        }
    }

    /// Translate a Unix PID into a Core Audio process AudioObjectID.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = CAProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = pid
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                UInt32(MemoryLayout<pid_t>.size), &inPID,
                &size, &obj),
            "TranslatePIDToProcessObject(pid: \(pid))"
        )
        if obj == 0 {
            throw TapError("No Core Audio process object for PID \(pid) (is it running / producing audio?)")
        }
        return obj
    }

    /// Prints the `--list` table to stdout.
    static func printList() throws {
        let infos = try allInfos()
        guard !infos.isEmpty else {
            print("No audio process objects found.")
            return
        }
        // Column widths
        let pidW = 7, outW = 8, nameW = 30
        // Truncate to w-1 then pad, so adjacent columns always keep a gap.
        func pad(_ s: String, _ w: Int) -> String {
            let t = s.count > w - 1 ? String(s.prefix(w - 1)) : s
            return t + String(repeating: " ", count: w - t.count)
        }
        print(pad("PID", pidW) + pad("OUTPUT", outW) + pad("NAME", nameW) + "BUNDLE ID")
        print(String(repeating: "-", count: pidW + outW + nameW + 20))
        for i in infos {
            let out = i.isRunningOutput ? "yes" : "-"
            print(pad(String(i.pid), pidW) + pad(out, outW) + pad(i.name, nameW) + i.bundleID)
        }
        let active = infos.filter { $0.isRunningOutput }.count
        FileHandle.standardError.write(Data(
            "\n\(infos.count) process objects, \(active) currently producing output.\n".utf8))
    }
}
