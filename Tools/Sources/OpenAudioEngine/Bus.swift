// Bus.swift
// Phase 2 routing target (F-E1). One bus = one ClockBridge + one consumer
// IOProc on a virtual device "OpenAudioDevice-n" (stereo into ch0/1, rest
// zeroed — identical to the Phase 1 single-bus consumer). Buses are created
// and retired OFF the RT thread; they are published to the capture (producer)
// callback through an atomic slot array so attach/detach never blocks or
// allocates on the audio thread.
//
// Memory-reclamation scheme (documented contract):
//   Attach:  build bridge -> start consumer IOProc -> atomically publish the
//            bus RT context pointer into slot[index]. The producer only starts
//            pushing once it observes the non-null slot.
//   Detach:  atomically null slot[index] (release), then wait via an epoch
//            handshake for the capture callback to advance its cycle counter
//            past the store (so no in-flight callback can still hold the old
//            pointer), THEN stop/destroy the consumer IOProc and free the
//            bridge + RT context. If the producer is idle (no capture graph
//            running, e.g. during stop), the counter never advances and a
//            short timeout lets us proceed — safe, because an idle producer
//            cannot observe the pointer. This is a bounded, race-free reclaim
//            (no leak-until-stop arena needed).

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

/// Maximum number of buses / virtual devices (mirrors kOpenAudioMaxDevices in
/// Driver/Source/OpenAudioControl.h).
public let kOpenAudioMaxBuses = 8

/// POD the RT capture callback reads (through an atomic slot pointer) to push a
/// mixed stereo bus into this bus's bridge ring. Written once at attach; the
/// pointed-to counters are the bridge's producer-side stats words.
public struct BusRTContext {
    public var storage: UnsafeMutablePointer<Float>       // stereo interleaved ring
    public var capacityFrames: Int
    public var writeIndex: UnsafeMutablePointer<UInt64>
    public var producedFrames: UnsafeMutablePointer<UInt64>
    public var producerCallbacks: UnsafeMutablePointer<UInt64>
    public var busIndex: Int
}

/// Routing matrix bit index for (source, bus). sources <= 2, buses <= 8, so the
/// whole matrix fits in the low 16 bits of a UInt64 (single atomic snapshot).
@inline(__always)
public func routeBit(source: Int, bus: Int) -> UInt64 {
    UInt64(1) << UInt64(source * kOpenAudioMaxBuses + bus)
}

/// Atomic publish of a bus RT context into the shared slot array. The barrier
/// before the store orders the context initialization ahead of the pointer
/// becoming visible to the RT producer.
@inline(__always)
public func publishBusSlot(_ slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                           _ index: Int,
                           _ ctx: UnsafeMutablePointer<BusRTContext>) {
    OSMemoryBarrier()
    slots[index] = UnsafeMutableRawPointer(ctx)
    OSMemoryBarrier()
}

@inline(__always)
public func retireBusSlot(_ slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                          _ index: Int) {
    slots[index] = nil
    OSMemoryBarrier()
}

/// Off-RT owner of one bus: bridge + consumer IOProc on a virtual device.
public final class Bus: @unchecked Sendable {
    public let index: Int               // 0-based
    public let deviceUID: String
    public let vdevID: AudioObjectID
    public let deviceRate: Double
    public let bridge: ClockBridge

    private var consumerProcID: AudioDeviceIOProcID?
    private let rtCtx: UnsafeMutablePointer<BusRTContext>
    private var started = false
    private var freed = false

    private init(index: Int, deviceUID: String, vdevID: AudioObjectID,
                 deviceRate: Double, bridge: ClockBridge,
                 rtCtx: UnsafeMutablePointer<BusRTContext>) {
        self.index = index
        self.deviceUID = deviceUID
        self.vdevID = vdevID
        self.deviceRate = deviceRate
        self.bridge = bridge
        self.rtCtx = rtCtx
    }

    /// Build and start a bus for `index` (0-based). Resolves virtual device
    /// "OpenAudioDevice-(index+1)". Throws a clear error if the device is
    /// absent (e.g. the driver has not published that many devices yet).
    public static func attach(index: Int, captureRate: Double) throws -> Bus {
        precondition(index >= 0 && index < kOpenAudioMaxBuses)
        let uid = "OpenAudioDevice-\(index + 1)"
        let vdev = DeviceUtil.device(forUID: uid)
        guard vdev != 0 else {
            throw OAError("Virtual device '\(uid)' (bus \(index + 1)) not found. " +
                          "The OpenAudio driver may not publish that many devices — " +
                          "set the device count with `openaudio buses \(index + 1)` " +
                          "(requires the Phase 2 driver), or attach fewer buses.")
        }
        let dr = DeviceUtil.nominalSampleRate(vdev)
        let deviceRate = dr > 0 ? dr : 48000

        // Bridge sizing identical to the Phase 1 single-bus path.
        let bufFrames = max(64, DeviceUtil.bufferFrameSize(vdev))
        let target = Int((Double(bufFrames) * 2.5).rounded())
        let capacity = max(Int(deviceRate), target * 16)
        let baseRatio = captureRate / deviceRate
        let bridge = ClockBridge(
            capacityFrames: capacity,
            targetFrames: target,
            baseRatio: baseRatio,
            deviceSampleRate: deviceRate,
            kpPPM: 300.0, kiPPM: 40.0, maxPPM: 500.0)

        // Consumer IOProc (driver clock) — same block as Phase 1.
        let ctx = bridge.consumerCtxPointer
        let block: AudioDeviceIOBlock = { (_, _, _, outOutputData, _) in
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outList.count > 0, let raw = outList[0].mData else { return }
            let ch = Int(outList[0].mNumberChannels)
            if ch <= 0 { return }
            let frames = Int(outList[0].mDataByteSize) / (ch * MemoryLayout<Float>.size)
            bridgeConsume(ctx, out: raw.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
        }
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, vdev, nil, block),
                  "AudioDeviceCreateIOProcIDWithBlock(bus \(index + 1))")
        guard let procID else { throw OAError("Consumer IOProc creation returned null for bus \(index + 1)") }

        let rtCtx = UnsafeMutablePointer<BusRTContext>.allocate(capacity: 1)
        rtCtx.initialize(to: BusRTContext(
            storage: bridge.storagePointer,
            capacityFrames: bridge.capacityFrames,
            writeIndex: bridge.writeIndexPointer,
            producedFrames: bridge.producedFramesPointer,
            producerCallbacks: bridge.producerCallbacksPointer,
            busIndex: index))

        let bus = Bus(index: index, deviceUID: uid, vdevID: vdev,
                      deviceRate: deviceRate, bridge: bridge, rtCtx: rtCtx)
        do {
            try check(AudioDeviceStart(vdev, procID), "AudioDeviceStart(bus \(index + 1))")
            bus.consumerProcID = procID
            bus.started = true
        } catch {
            AudioDeviceDestroyIOProcID(vdev, procID)
            rtCtx.deinitialize(count: 1); rtCtx.deallocate()
            throw error
        }
        OALog.info(String(format: "Bus %d attached: device '%@' id=%d @ %.0f Hz, baseRatio=%.6f",
                          index + 1, uid, vdev, deviceRate, baseRatio))
        return bus
    }

    /// Publish this bus's RT context into the shared slot array so the producer
    /// begins pushing. Call after the capture graph exists (or before — the
    /// producer simply starts feeding as soon as it observes the slot).
    public func publish(into slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
        publishBusSlot(slots, index, rtCtx)
    }

    /// Retire and free. Nulls the slot, waits (epoch handshake) until the
    /// capture callback can no longer observe the pointer, then stops the
    /// consumer IOProc and frees. Off-RT only.
    ///
    /// - Parameter producerStopped: pass true when the capture graph has
    ///   already been torn down (e.g. during Engine.stop), so no in-flight
    ///   callback can hold the slot pointer and the handshake can be skipped —
    ///   avoids a per-bus timeout stall at shutdown.
    public func detach(from slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                       captureCycles: Atomic64,
                       producerStopped: Bool = false) {
        if freed { return }
        freed = true
        retireBusSlot(slots, index)

        // Epoch handshake: wait for the producer to run at least two full
        // cycles past the store, or bail after a short timeout if it is idle.
        if !producerStopped {
            let start = captureCycles.load()
            let deadline = Date().addingTimeInterval(0.3)
            while captureCycles.load() < start &+ 2 {
                if Date() > deadline { break }
                usleep(1000)
            }
        }

        if started, let procID = consumerProcID {
            AudioDeviceStop(vdevID, procID)
            AudioDeviceDestroyIOProcID(vdevID, procID)
            started = false
            consumerProcID = nil
        }
        rtCtx.deinitialize(count: 1)
        rtCtx.deallocate()
        OALog.info("Bus \(index + 1) detached.")
    }
}
