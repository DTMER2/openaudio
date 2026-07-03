//
//  looptest — Phase 0(a) acceptance verifier for the OpenAudio virtual device.
//
//  Finds the "OpenAudio 16ch" device by its UID, installs one IOProc, writes a
//  deterministic 16-channel pattern to the output stream and reads it back from
//  the input stream. After accounting for the loopback priming delay it checks
//  that the read-back samples are BIT-EXACT (Float32 bit-pattern comparison)
//  against what was written, per channel, over roughly five seconds.
//
//  The pattern embeds an absolute frame counter in every frame so the
//  write->read offset can be discovered at runtime rather than hardcoded.
//
//  Exit code 0 = all 16 channels bit-exact; 1 = any failure / device missing.
//

import Foundation
import CoreAudio
import os

// MARK: - Configuration

let kDeviceUID          = "OpenAudioDevice-1"
let kExpectedChannels   = 16
let kRunSeconds         = 5.0
let kWarmupSeconds      = 1.0          // ignore output before the ring is primed
let kCounterModulo      = 65536        // frame counter wraps here (0.68 s @ 96 kHz)

// Pattern: for absolute frame index n and channel c (0..15),
//   value = Float32( (n mod kCounterModulo) * 16 + c )
// This is an exact integer-valued Float32 (max 1_048_575 < 2^24), so it
// survives the driver's raw memcpy loopback with an identical bit pattern and
// is trivially decodable to recover the frame counter from channel 0.
@inline(__always)
func patternValue(counter k: Int, channel c: Int) -> Float32 {
    return Float32(k * 16 + c)
}

// MARK: - Shared results (written on the IO thread, read on main)

final class Results {
    private var lock = os_unfair_lock_s()

    var deviceChannels = 0
    var firstInputSampleTime: Int64 = -1
    var ioLatencyFrames = 0            // outputTime - inputTime, informational
    var comparisonStarted = false
    var offsetRaw: Int64 = 0           // decodedCounter - fullSampleTime at start
    var comparedFrames = 0
    var perChannelFail = [Bool](repeating: false, count: kExpectedChannels)
    var sawAnyData = false
    var lastError: OSStatus = 0

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

let results = Results()

// MARK: - Core Audio helpers

func translateUIDToDevice(_ uid: String) -> AudioObjectID {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var uidCF = uid as CFString
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

    let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr -> OSStatus in
        AudioObjectGetPropertyData(systemObject,
                                   &address,
                                   UInt32(MemoryLayout<CFString>.size),
                                   uidPtr,
                                   &dataSize,
                                   &deviceID)
    }
    if status != noErr {
        return AudioObjectID(kAudioObjectUnknown)
    }
    return deviceID
}

func nominalSampleRate(_ device: AudioObjectID) -> Float64 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}

// MARK: - IOProc

func handleIO(inputData: UnsafePointer<AudioBufferList>,
              inputTime: UnsafePointer<AudioTimeStamp>,
              outputData: UnsafeMutablePointer<AudioBufferList>,
              outputTime: UnsafePointer<AudioTimeStamp>) {

    // ---- Write the deterministic pattern into the output stream. ----
    let outList = UnsafeMutableAudioBufferListPointer(outputData)
    if outList.count > 0, let raw = outList[0].mData {
        let channels = Int(outList[0].mNumberChannels)
        if channels > 0 {
            let frames = Int(outList[0].mDataByteSize) / (channels * MemoryLayout<Float32>.size)
            let ptr = raw.assumingMemoryBound(to: Float32.self)
            let baseT = Int64(outputTime.pointee.mSampleTime)
            for i in 0..<frames {
                let k = Int((baseT + Int64(i)) % Int64(kCounterModulo))
                let frameOffset = i * channels
                for c in 0..<channels {
                    ptr[frameOffset + c] = patternValue(counter: k, channel: c)
                }
            }
        }
    }

    // ---- Read the input stream and verify against the pattern. ----
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard inList.count > 0, let inRaw = inList[0].mData else { return }
    let channels = Int(inList[0].mNumberChannels)
    guard channels > 0 else { return }
    let frames = Int(inList[0].mDataByteSize) / (channels * MemoryLayout<Float32>.size)
    let inPtr = inRaw.assumingMemoryBound(to: Float32.self)
    let baseT = Int64(inputTime.pointee.mSampleTime)
    let outBaseT = Int64(outputTime.pointee.mSampleTime)

    results.withLock {
        results.deviceChannels = channels
        if results.firstInputSampleTime < 0 {
            results.firstInputSampleTime = baseT
            results.ioLatencyFrames = Int(outBaseT - baseT)
        }
        let warmupFrames = Int64(kWarmupSeconds * nominalRateForIO)

        for i in 0..<frames {
            let sampleTime = baseT + Int64(i)
            let sinceStart = sampleTime - results.firstInputSampleTime
            if sinceStart < warmupFrames { continue }   // still priming

            let frameOffset = i * channels
            let ch0 = inPtr[frameOffset]

            if !results.comparisonStarted {
                // Wait for the first structurally valid frame, then lock on.
                guard ch0.isFinite, ch0 >= 0, ch0 <= Float32((kCounterModulo - 1) * 16 + (channels - 1)),
                      ch0 == ch0.rounded(),
                      Int(ch0) % 16 == 0 else { continue }
                results.sawAnyData = true
                let decodedK = Int64(Int(ch0) / 16)
                results.offsetRaw = decodedK - (sampleTime % Int64(kCounterModulo))
                results.comparisonStarted = true
            }

            // Expected counter locked to the input sample time (plus the
            // detected offset, which is 0 for a correct loopback).
            let expectedK = Int(((sampleTime + results.offsetRaw) % Int64(kCounterModulo) + Int64(kCounterModulo)) % Int64(kCounterModulo))

            let compareCount = min(channels, kExpectedChannels)
            for c in 0..<compareCount {
                let expected = patternValue(counter: expectedK, channel: c)
                let got = inPtr[frameOffset + c]
                if got.bitPattern != expected.bitPattern {
                    results.perChannelFail[c] = true
                }
            }
            results.comparedFrames += 1
        }
    }
}

// The IO thread needs the sample rate to size the warmup window; publish it
// once before starting IO.
var nominalRateForIO: Float64 = 48000.0

// MARK: - Main

print("looptest — OpenAudio Phase 0(a) loopback verifier")

let device = translateUIDToDevice(kDeviceUID)
if device == AudioObjectID(kAudioObjectUnknown) || device == 0 {
    print("FAIL: device with UID \"\(kDeviceUID)\" not found.")
    print("      Is the OpenAudioDriver installed and coreaudiod restarted?")
    exit(1)
}
print("Device found: id=\(device), UID=\(kDeviceUID)")

let sampleRate = nominalSampleRate(device)
nominalRateForIO = sampleRate > 0 ? sampleRate : 48000.0
print("Nominal sample rate: \(sampleRate) Hz")

var ioProcID: AudioDeviceIOProcID?
let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil) {
    (_ inNow, inInputData, inInputTime, outOutputData, inOutputTime) in
    handleIO(inputData: inInputData,
             inputTime: inInputTime,
             outputData: outOutputData,
             outputTime: inOutputTime)
}
guard createStatus == noErr, let ioProc = ioProcID else {
    print("FAIL: AudioDeviceCreateIOProcIDWithBlock failed (status \(createStatus)).")
    exit(1)
}

let startStatus = AudioDeviceStart(device, ioProc)
guard startStatus == noErr else {
    print("FAIL: AudioDeviceStart failed (status \(startStatus)).")
    _ = AudioDeviceDestroyIOProcID(device, ioProc)
    exit(1)
}

print("Running loopback for \(kRunSeconds) s (warmup \(kWarmupSeconds) s)...")
Thread.sleep(forTimeInterval: kRunSeconds)

_ = AudioDeviceStop(device, ioProc)
_ = AudioDeviceDestroyIOProcID(device, ioProc)

// MARK: - Report

let snapshot = results.withLock { () -> (Int, Int, [Bool], Bool, Bool, Int64, Int) in
    (results.deviceChannels,
     results.comparedFrames,
     results.perChannelFail,
     results.sawAnyData,
     results.comparisonStarted,
     results.offsetRaw,
     results.ioLatencyFrames)
}

let (deviceChannels, comparedFrames, perChannelFail, sawAnyData, started, offsetRaw, ioLatency) = snapshot

print("")
print("Device channels observed: \(deviceChannels)")
print("IO latency (out - in) sample times: \(ioLatency) frames")

let normOffset = ((offsetRaw % Int64(kCounterModulo)) + Int64(kCounterModulo)) % Int64(kCounterModulo)
let signedOffset = normOffset > Int64(kCounterModulo / 2) ? normOffset - Int64(kCounterModulo) : normOffset
print("Detected write->read sample-time offset: \(signedOffset) frames (0 = perfect)")
print("Frames compared: \(comparedFrames)")
print("")

var allPass = true

if deviceChannels != kExpectedChannels {
    print("FAIL: device presented \(deviceChannels) channels, expected \(kExpectedChannels).")
    allPass = false
}
if !sawAnyData || !started {
    print("FAIL: never observed valid loopback data (device produced no primed samples).")
    allPass = false
}
if comparedFrames == 0 {
    print("FAIL: no frames were compared.")
    allPass = false
}

let channelsToReport = deviceChannels > 0 ? min(deviceChannels, kExpectedChannels) : kExpectedChannels
for c in 0..<channelsToReport {
    let pass = !perChannelFail[c] && comparedFrames > 0 && started
    print(String(format: "  channel %2d: %@", c, pass ? "PASS" : "FAIL"))
    if !pass { allPass = false }
}

print("")
if allPass {
    print("RESULT: PASS — output written and read back BIT-EXACT on all \(channelsToReport) channels.")
    exit(0)
} else {
    print("RESULT: FAIL")
    exit(1)
}
