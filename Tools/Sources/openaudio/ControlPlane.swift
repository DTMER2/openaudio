// ControlPlane.swift
// App-side client for the OpenAudio control plane (docs/requirements.md §8,
// docs/plan.md Phase 2). Mirrors the FIXED ABI in Driver/Source/
// OpenAudioControl.h by value — do NOT edit the header. Resolves the plug-in
// object via kAudioHardwarePropertyTranslateBundleIDToPlugInObject, then gets/
// sets the device-count property 'OAdc'. Per the ABI, 'OAdc' is a
// CFPropertyList custom property carrying a CFNumber (coreaudiod only proxies
// plug-in custom properties that the driver declares via
// kAudioObjectPropertyCustomPropertyInfoList, and only with CFString/
// CFPropertyList data types): Get returns a +1-retained CFNumberRef that the
// caller releases; Set passes a CFNumberRef; the on-wire data size is one
// pointer (sizeof(CFPropertyListRef)). After a set this waits for the expected
// "OpenAudioDevice-n" UIDs to appear/disappear in the HAL. If the property is
// missing (an older driver is installed) every entry point fails with a clear,
// actionable message instead of crashing.

import Foundation
import CoreAudio
import OpenAudioEngine

/// Constants mirrored from Driver/Source/OpenAudioControl.h.
enum OpenAudioControl {
    static let bundleID = "com.openaudio.driver"
    static let deviceCountSelector: AudioObjectPropertySelector = 0x4F416463   // 'OAdc'
    static let maxDevices = 8

    static func deviceUID(_ n: Int) -> String { "OpenAudioDevice-\(n)" }
}

enum ControlPlane {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static var countAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: OpenAudioControl.deviceCountSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static let oldDriverMessage =
        "The installed OpenAudio driver does not support the device-count control " +
        "property ('OAdc'). This is the pre-Phase-2 driver. Rebuild and reinstall " +
        "the driver (make -C Driver && sudo scripts/install-driver.sh) to use " +
        "multiple buses."

    /// Resolve the plug-in object that carries the custom properties.
    static func plugInObject() throws -> AudioObjectID {
        // The SDK's non-deprecated selector is spelled ...ToPlugIn (the name in
        // docs/plan.md, ...ToPlugInObject, does not exist as a symbol). Same
        // semantics: bundle-ID CFString qualifier in, plug-in AudioObjectID out.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var bundleID = OpenAudioControl.bundleID as CFString
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { p -> OSStatus in
            AudioObjectGetPropertyData(system, &addr,
                                       UInt32(MemoryLayout<CFString>.size), p,
                                       &size, &obj)
        }
        guard status == noErr, obj != 0, obj != AudioObjectID(kAudioObjectUnknown) else {
            throw OAError(
                "Could not locate the OpenAudio plug-in object (bundle ID '\(OpenAudioControl.bundleID)'). " +
                "Is the OpenAudio driver installed? (OSStatus \(osStatusString(status)))")
        }
        return obj
    }

    /// True when the running driver exposes the device-count property.
    static func supportsDeviceCount(_ plugIn: AudioObjectID) -> Bool {
        var addr = countAddress
        return AudioObjectHasProperty(plugIn, &addr)
    }

    /// Read the current published device count. Throws the clear "driver too old"
    /// message when the property is absent.
    static func deviceCount() throws -> UInt32 {
        let plugIn = try plugInObject()
        guard supportsDeviceCount(plugIn) else { throw OAError(oldDriverMessage) }
        var addr = countAddress
        // 'OAdc' is a CFPropertyList property: the get fills one pointer-sized
        // CF object reference, returned at +1 (we own it -> takeRetainedValue).
        var ref: Unmanaged<CFPropertyList>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        try withUnsafeMutablePointer(to: &ref) { p -> Void in
            try check(AudioObjectGetPropertyData(plugIn, &addr, 0, nil, &size, p),
                      "AudioObjectGetPropertyData('OAdc')")
        }
        guard let obj = ref?.takeRetainedValue() else {
            throw OAError("'OAdc' get succeeded but returned no value")
        }
        guard CFGetTypeID(obj) == CFNumberGetTypeID() else {
            throw OAError("'OAdc' get returned an unexpected CF type (expected CFNumber)")
        }
        let num = obj as! CFNumber
        var value: Int32 = 0
        guard CFNumberGetValue(num, .sInt32Type, &value), value >= 0 else {
            throw OAError("'OAdc' CFNumber could not be read as an Int32")
        }
        return UInt32(value)
    }

    /// Set the device count (1...maxDevices) and wait (up to `timeout` s) for the
    /// HAL device list to reflect it. Throws "driver too old" if unsupported.
    @discardableResult
    static func setDeviceCount(_ count: Int, timeout: TimeInterval = 5.0) throws -> UInt32 {
        guard count >= 1 && count <= OpenAudioControl.maxDevices else {
            throw OAError("device count must be 1...\(OpenAudioControl.maxDevices), got \(count)")
        }
        let plugIn = try plugInObject()
        guard supportsDeviceCount(plugIn) else { throw OAError(oldDriverMessage) }

        var addr = countAddress
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(plugIn, &addr, &settable) == noErr, !settable.boolValue {
            throw OAError("The device-count property is present but not settable on this driver.")
        }

        // Set passes one pointer-sized CFNumberRef. We own our reference;
        // coreaudiod copies/retains the value during the call, and ARC drops
        // ours when it goes out of scope after the call returns.
        var count32 = Int32(count)
        guard let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &count32) else {
            throw OAError("CFNumberCreate failed for device count \(count)")
        }
        var ref: CFPropertyList? = num
        try withUnsafeMutablePointer(to: &ref) { p -> Void in
            try check(AudioObjectSetPropertyData(plugIn, &addr, 0, nil,
                                                 UInt32(MemoryLayout<CFPropertyList?>.size), p),
                      "AudioObjectSetPropertyData('OAdc' = \(count))")
        }

        // Wait for devices 1...count to appear and count+1...max to disappear.
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var ok = true
            for n in 1...OpenAudioControl.maxDevices {
                let present = DeviceUtil.device(forUID: OpenAudioControl.deviceUID(n)) != 0
                let expected = n <= count
                if present != expected { ok = false; break }
            }
            if ok { break }
            if Date() > deadline {
                throw OAError("Timed out after \(Int(timeout))s waiting for the HAL device list to reflect count=\(count). " +
                              "The driver accepted the set but devices did not settle.")
            }
            usleep(100_000)   // 100 ms
        }
        return UInt32(count)
    }
}
