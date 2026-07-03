// TapGraph.swift
// Construction and teardown of the capture graph:
//   CATapDescription -> process tap -> private aggregate device (default output
//   as main sub-device + tap as sub-tap) -> IOProc reading the tap's input.
//
// One TapGraph instance == one live graph. The watchdog / device-change handler
// tears one down and builds a fresh one; the RingBuffer it feeds is external and
// persists across rebuilds.

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

enum TapMode {
    case system                     // all output, exclude nothing
    case processes([AudioObjectID]) // stereo mixdown of the given process objects
}

final class TapGraph {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    let format: AudioStreamBasicDescription
    let outputDeviceUID: String

    // Scratch buffer for de-interleaving in the (unlikely) non-interleaved case.
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private var started = false

    private init(
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        format: AudioStreamBasicDescription,
        outputDeviceUID: String,
        scratch: UnsafeMutablePointer<Float>,
        scratchFrames: Int
    ) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.format = format
        self.outputDeviceUID = outputDeviceUID
        self.scratch = scratch
        self.scratchFrames = scratchFrames
    }

    // MARK: Build

    static func build(mode: TapMode, ring: RingBuffer) throws -> TapGraph {
        let system = AudioObjectID(kAudioObjectSystemObject)

        // 1. Tap description
        let description: CATapDescription
        switch mode {
        case .system:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .processes(let objs):
            description = CATapDescription(stereoMixdownOfProcesses: objs)
        }
        description.name = "OpenAudio-Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // 2. Create the process tap
        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        if tapStatus != noErr {
            throw permissionAwareError(tapStatus)
        }
        guard tapID != 0 else {
            throw TapError("AudioHardwareCreateProcessTap returned a null tap object")
        }

        // Once a TapGraph instance exists, its teardown() owns destroying the
        // tap/aggregate/IOProc — the catch at the bottom must not destroy the
        // tap a second time.
        var teardownOwnsTap = false
        do {
            // 3. Tap UID + stream format
            let tapUID = try CAProperty.string(tapID, kAudioTapPropertyUID)
            let format: AudioStreamBasicDescription = try CAProperty.scalar(
                tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())

            guard format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
                throw TapError("Tap reported an invalid stream format (ch=\(format.mChannelsPerFrame), sr=\(format.mSampleRate))")
            }
            guard Int(format.mChannelsPerFrame) == ring.channels else {
                throw TapError(
                    "Tap channel count (\(format.mChannelsPerFrame)) does not match the capture ring " +
                    "(\(ring.channels) ch); cannot continue into the same output file")
            }

            // 4. Default output device UID (aggregate main sub-device)
            let outputDevice: AudioObjectID = try CAProperty.scalar(
                system, kAudioHardwarePropertyDefaultOutputDevice, default: 0)
            guard outputDevice != 0 else {
                throw TapError("No default output device is set")
            }
            let outputUID = try CAProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)

            // 5. Private aggregate device
            let aggUID = "OpenAudio-Agg-" + UUID().uuidString
            let desc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "OpenAudio-TapCapture",
                kAudioAggregateDeviceUIDKey: aggUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapUID,
                    ],
                ],
            ]

            var aggregateID: AudioObjectID = 0
            try check(
                AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice")
            guard aggregateID != 0 else {
                throw TapError("AudioHardwareCreateAggregateDevice returned a null device")
            }

            // 6. IOProc — realtime capture of the tap's input buffers.
            let channels = Int(format.mChannelsPerFrame)
            let interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let scratchFrames = 16384
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * channels)
            scratch.initialize(repeating: 0, count: scratchFrames * channels)
            let ctxPtr = ring.contextPointer

            let block: AudioDeviceIOBlock = { (_, inInputData, _, _, _) in
                let bufs = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData))
                let nbuf = bufs.count
                if nbuf == 0 { return }
                if interleaved {
                    let b = bufs[0]
                    guard let data = b.mData else { return }
                    let frames = Int(b.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                    ctxPtr.pointee.writeRaw(data, frames: frames)
                } else {
                    let ch = min(nbuf, channels)
                    let frames = Int(bufs[0].mDataByteSize) / MemoryLayout<Float>.size
                    let n = min(frames, scratchFrames)
                    if ch < channels {
                        // Missing channels: clear so stale samples never leak.
                        memset(scratch, 0, n * channels * MemoryLayout<Float>.size)
                    }
                    for c in 0..<ch {
                        guard let src = bufs[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        var i = 0
                        while i < n {
                            scratch[i * channels + c] = src[i]
                            i += 1
                        }
                    }
                    ctxPtr.pointee.write(scratch, frames: n)
                }
            }

            var ioProcID: AudioDeviceIOProcID?
            do {
                try check(
                    AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block),
                    "AudioDeviceCreateIOProcIDWithBlock")
            } catch {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                scratch.deallocate()
                throw error
            }
            guard let ioProcID else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                scratch.deallocate()
                throw TapError("AudioDeviceCreateIOProcIDWithBlock returned a null IOProc ID")
            }

            let graph = TapGraph(
                tapID: tapID,
                aggregateID: aggregateID,
                ioProcID: ioProcID,
                format: format,
                outputDeviceUID: outputUID,
                scratch: scratch,
                scratchFrames: scratchFrames)
            teardownOwnsTap = true

            // 7. Start (AutoStart also arms the tap, but be explicit).
            do {
                try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
                graph.started = true
            } catch {
                graph.teardown() // destroys IOProc, aggregate, and the tap
                throw error
            }
            return graph
        } catch {
            // Tap created but a later step failed before a TapGraph took
            // ownership: clean up the bare tap here.
            if !teardownOwnsTap {
                AudioHardwareDestroyProcessTap(tapID)
            }
            throw error
        }
    }

    // MARK: Teardown

    private var tornDown = false

    /// Fully stops and destroys the IOProc, aggregate, and tap. Idempotent —
    /// a second call is a no-op (guards against scratch double-free).
    func teardown() {
        if tornDown { return }
        tornDown = true
        if started {
            AudioDeviceStop(aggregateID, ioProcID)
            started = false
        }
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        scratch.deallocate()
    }

    // MARK: Permission handling

    /// Maps tap-creation failures to a clear, actionable error. A TCC denial
    /// typically surfaces as a generic failure on the create-tap call.
    private static func permissionAwareError(_ status: OSStatus) -> TapError {
        let base = "AudioHardwareCreateProcessTap failed: OSStatus \(osStatusString(status))"
        return TapError(
            base + "\n" +
            "This usually means system audio-capture permission was denied or not yet granted.\n" +
            "Grant it under System Settings > Privacy & Security > Audio Capture (or the\n" +
            "'Screen & System Audio Recording' section) for your terminal application, then retry.")
    }
}
