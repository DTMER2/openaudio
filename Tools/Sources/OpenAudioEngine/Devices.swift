// Devices.swift
// Device discovery helpers: enumerate all audio devices, resolve the virtual
// device by UID, read default input/output, and inspect channel counts /
// buffer size / sample rate. All calls run on non-realtime threads.

import Foundation
import CoreAudio

public struct AudioDeviceInfo {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var inChannels: Int
    public var outChannels: Int
    public var sampleRate: Double
}

public enum DeviceUtil {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Sum of channels across all streams in the given scope.
    public static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = CAProperty.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var ch = 0
        for b in abl { ch += Int(b.mNumberChannels) }
        return ch
    }

    /// Per-buffer channel counts for the given scope (one entry per stream / buffer).
    public static func streamChannelLayout(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = CAProperty.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }
    }

    public static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        (try? CAProperty.scalar(device, kAudioDevicePropertyNominalSampleRate, default: Double(0))) ?? 0
    }

    public static func bufferFrameSize(_ device: AudioObjectID) -> Int {
        let v: UInt32 = (try? CAProperty.scalar(device, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))) ?? 0
        return Int(v)
    }

    public static func uid(_ device: AudioObjectID) -> String {
        (try? CAProperty.string(device, kAudioDevicePropertyDeviceUID)) ?? ""
    }

    public static func name(_ device: AudioObjectID) -> String {
        (try? CAProperty.string(device, kAudioObjectPropertyName)) ?? ""
    }

    public static func defaultOutputDevice() -> AudioObjectID {
        (try? CAProperty.scalar(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))) ?? 0
    }

    public static func defaultInputDevice() -> AudioObjectID {
        (try? CAProperty.scalar(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))) ?? 0
    }

    /// Resolve a device UID to its AudioObjectID (0 if not found).
    public static func device(forUID uid: String) -> AudioObjectID {
        var addr = CAProperty.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uidCF = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { p -> OSStatus in
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &deviceID)
        }
        if status != noErr || deviceID == AudioObjectID(kAudioObjectUnknown) { return 0 }
        return deviceID
    }

    public static func allDevices() -> [AudioDeviceInfo] {
        let ids = (try? CAProperty.array(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)) ?? []
        return ids.map { id in
            AudioDeviceInfo(
                id: id,
                uid: uid(id),
                name: name(id),
                inChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                sampleRate: nominalSampleRate(id))
        }
    }
}
