// OpenAudioControl.h
// Control-plane ABI between the OpenAudio app and the HAL driver (docs/plan.md
// Phase 2). This header is the single source of truth; the Swift side mirrors
// these constants by value. Do not change existing values — add new selectors
// instead.

#ifndef OPENAUDIO_CONTROL_H
#define OPENAUDIO_CONTROL_H

// Bundle ID used with kAudioHardwarePropertyTranslateBundleIDToPlugInObject to
// locate the plug-in object that carries the custom properties below.
#define kOpenAudioDriverBundleID "com.openaudio.driver"

// Number of published loopback devices.
//   Object:  plug-in object, global scope, main element
//   Type:    CFPropertyList carrying a CFNumber (1...kOpenAudioMaxDevices),
//            readable + settable. Get returns a +1-retained CFNumberRef the
//            caller releases; Set takes a CFNumberRef (any numeric type).
//   NOTE: coreaudiod only proxies plug-in custom properties to HAL clients if
//   the plug-in declares them via kAudioObjectPropertyCustomPropertyInfoList
//   ('cust') on the same object, and only with CFString/CFPropertyList data
//   types (AudioServerPlugIn.h). The driver therefore answers 'cust' with one
//   AudioServerPlugInCustomPropertyInfo { 'OAdc',
//   kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
//   kAudioServerPlugInCustomPropertyDataTypeNone }.
//   Side effects on set: devices are created/destroyed, the host is notified
//   via PropertiesChanged(kAudioPlugInPropertyDeviceList), and the value is
//   persisted to host storage. IO on surviving devices is not interrupted.
// FourCC 'OAdc'
#define kOpenAudioPropertyDeviceCount 0x4F416463

#define kOpenAudioMaxDevices 8

// Device identity scheme: device n (1-based) publishes UID "OpenAudioDevice-n".
// Device 1 is named "OpenAudio 16ch" (pre-Phase-2 compatibility); devices n>=2
// are named "OpenAudio 16ch n".

#endif /* OPENAUDIO_CONTROL_H */
