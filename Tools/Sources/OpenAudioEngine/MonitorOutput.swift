// MonitorOutput.swift
// Monitor pass-through (F-M1/M2) on its own clock. The capture aggregate is
// clocked by OpenAudio's virtual device (a fixed, Bluetooth-independent rate),
// so the real default output — which may be a Bluetooth headset that drops to
// a 16/24 kHz hands-free profile whenever its mic is open — is fed through a
// ClockBridge + consumer IOProc, exactly like a bus feeds a virtual device.
// Only this monitor feed is resampled to the headset's rate; the mix, the
// buses and the recording stay at the capture rate.
//
// Producer: the capture callback pushes the selected bus's stereo mix (monitor
// gain applied) into the bridge ring through a one-entry atomic slot (same
// publish / retire / epoch-handshake contract as Bus). Consumer: this IOProc
// on the output device pulls at the device rate and writes L/R into the
// device's first two channels (interleaved, non-interleaved, or a mono
// downmix), zeroing everything else.

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

public final class MonitorOutput: @unchecked Sendable {
    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let deviceRate: Double
    public let bridge: ClockBridge

    private var procID: AudioDeviceIOProcID?
    private let rtCtx: UnsafeMutablePointer<BusRTContext>
    private let scratch: UnsafeMutablePointer<Float>
    private var started = false
    private var freed = false

    private init(deviceID: AudioObjectID, uid: String, deviceRate: Double, bridge: ClockBridge,
                 rtCtx: UnsafeMutablePointer<BusRTContext>, scratch: UnsafeMutablePointer<Float>) {
        self.deviceID = deviceID
        self.deviceUID = uid
        self.deviceRate = deviceRate
        self.bridge = bridge
        self.rtCtx = rtCtx
        self.scratch = scratch
    }

    /// Start a monitor feed on the current default output device.
    public static func attach(captureRate: Double, captureBufferFrames: Int,
                              maxFrames: Int) throws -> MonitorOutput {
        let dev = DeviceUtil.defaultOutputDevice()
        guard dev != 0 else { throw OAError("No default output device to monitor on") }
        let dr = DeviceUtil.nominalSampleRate(dev)
        let deviceRate = dr > 0 ? dr : 48000
        let ratio = captureRate / deviceRate          // capture frames per output frame
        let outBuf = max(64, DeviceUtil.bufferFrameSize(dev))
        // Cushion (capture-rate frames) covering one producer push plus one
        // consumer pull, with headroom for bursty Bluetooth delivery.
        let worst = Double(max(64, captureBufferFrames)) + Double(outBuf) * ratio
        let target = max(512, Int((worst * 1.5).rounded()))
        let capacity = max(Int(captureRate), target * 16)
        let bridge = ClockBridge(capacityFrames: capacity, targetFrames: target,
                                 baseRatio: ratio, deviceSampleRate: deviceRate,
                                 kpPPM: 300, kiPPM: 40, maxPPM: 500)

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
        let ctx = bridge.consumerCtxPointer
        let block: AudioDeviceIOBlock = { (_, _, _, outOutputData, _) in
            let ol = UnsafeMutableAudioBufferListPointer(outOutputData)
            var bi = 0
            while bi < ol.count {
                if let d = ol[bi].mData { memset(d, 0, Int(ol[bi].mDataByteSize)) }
                bi += 1
            }
            guard ol.count > 0, let d0 = ol[0].mData else { return }
            let ch0 = Int(ol[0].mNumberChannels)
            guard ch0 > 0 else { return }
            let frames = min(maxFrames, Int(ol[0].mDataByteSize) / (ch0 * MemoryLayout<Float>.size))
            bridgeConsume(ctx, out: scratch, frames: frames, channels: 2)
            let p0 = d0.assumingMemoryBound(to: Float.self)
            if ch0 >= 2 {
                // Interleaved stereo (or wider) in buffer 0.
                var f = 0
                while f < frames {
                    p0[f * ch0] = scratch[f * 2]
                    p0[f * ch0 + 1] = scratch[f * 2 + 1]
                    f += 1
                }
            } else if ol.count >= 2, Int(ol[1].mNumberChannels) == 1, let d1 = ol[1].mData {
                // Non-interleaved: L -> buffer 0, R -> buffer 1.
                let p1 = d1.assumingMemoryBound(to: Float.self)
                let m = min(frames, Int(ol[1].mDataByteSize) / MemoryLayout<Float>.size)
                var f = 0
                while f < m {
                    p0[f] = scratch[f * 2]
                    p1[f] = scratch[f * 2 + 1]
                    f += 1
                }
            } else {
                // Genuinely mono device: downmix.
                var f = 0
                while f < frames {
                    p0[f] = (scratch[f * 2] + scratch[f * 2 + 1]) * 0.5
                    f += 1
                }
            }
        }

        var pid: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, nil, block)
        guard created == noErr, let pid else {
            scratch.deallocate()
            throw OAError("Monitor IOProc creation failed: OSStatus \(osStatusString(created))")
        }
        let rtCtx = UnsafeMutablePointer<BusRTContext>.allocate(capacity: 1)
        rtCtx.initialize(to: BusRTContext(
            storage: bridge.storagePointer,
            capacityFrames: bridge.capacityFrames,
            writeIndex: bridge.writeIndexPointer,
            producedFrames: bridge.producedFramesPointer,
            producerCallbacks: bridge.producerCallbacksPointer,
            busIndex: -1))
        let mo = MonitorOutput(deviceID: dev, uid: DeviceUtil.uid(dev), deviceRate: deviceRate,
                               bridge: bridge, rtCtx: rtCtx, scratch: scratch)
        let st = AudioDeviceStart(dev, pid)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(dev, pid)
            rtCtx.deinitialize(count: 1); rtCtx.deallocate()
            scratch.deallocate()
            throw OAError("Monitor AudioDeviceStart failed: OSStatus \(osStatusString(st))")
        }
        mo.procID = pid
        mo.started = true
        OALog.info(String(format: "Monitor output '%@' @ %.0f Hz (capture %.0f Hz, base ratio %.6f)",
                          DeviceUtil.name(dev), deviceRate, captureRate, ratio))
        return mo
    }

    /// Make the producer start pushing into this monitor feed.
    public func publish(into slot: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
        publishBusSlot(slot, 0, rtCtx)
    }

    /// Retire and free (off-RT). Same contract as Bus.detach: null the slot,
    /// wait until the capture callback can no longer hold the pointer (skip
    /// when the producer is already stopped), then stop the IOProc and free.
    public func detach(from slot: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                       captureCycles: Atomic64, producerStopped: Bool = false) {
        if freed { return }
        freed = true
        retireBusSlot(slot, 0)
        if !producerStopped {
            let start = captureCycles.load()
            let deadline = Date().addingTimeInterval(0.3)
            while captureCycles.load() < start &+ 2 {
                if Date() > deadline { break }
                usleep(1000)
            }
        }
        if started, let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
            started = false
            procID = nil
        }
        rtCtx.deinitialize(count: 1)
        rtCtx.deallocate()
        scratch.deallocate()
        OALog.info("Monitor output detached.")
    }
}
