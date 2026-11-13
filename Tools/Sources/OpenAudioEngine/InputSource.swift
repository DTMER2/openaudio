// InputSource.swift
// A real input device (microphone / interface) captured on ITS OWN IOProc and
// clock, then resampled into the capture clock domain by a ClockBridge. This is
// what lets sources with different sample rates be mixed and recorded together
// (e.g. a 24 kHz Bluetooth/HFP mic or a 44.1 kHz built-in mic alongside a
// 48 kHz output): the old design put the mic into the capture aggregate as a
// drift-compensated sub-device, which cannot reconcile differing nominal rates
// (the HAL may refuse to retune the mic, or the mic stream ends up silent).
//
// Producer: this IOProc (input device clock) pushes stereo frames at the input
// rate into the bridge ring. Consumer: the capture callback pulls `n` frames at
// the capture rate with bridgeConsume (Catmull-Rom, PI-steered, base ratio =
// inputRate / captureRate). Survives capture-graph rebuilds; owned by Engine.

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

public final class InputSource: @unchecked Sendable {
    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let name: String
    public private(set) var inputRate: Double
    public let bridge: ClockBridge

    private var procID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    private var started = false

    private init(deviceID: AudioObjectID, uid: String, name: String, inputRate: Double,
                 bridge: ClockBridge, scratch: UnsafeMutablePointer<Float>) {
        self.deviceID = deviceID
        self.deviceUID = uid
        self.name = name
        self.inputRate = inputRate
        self.bridge = bridge
        self.scratch = scratch
    }

    /// Resolve `request` ("default" or a device UID) and start capturing.
    /// Returns nil (after logging) if the device is missing or has no input.
    public static func start(request: String, captureRate: Double,
                             captureBufferFrames: Int, maxFrames: Int) -> InputSource? {
        let dev = request == "default" ? DeviceUtil.defaultInputDevice() : DeviceUtil.device(forUID: request)
        guard dev != 0 else {
            OALog.warn("Requested input device '\(request)' not found; ignoring input source.")
            return nil
        }
        guard DeviceUtil.channelCount(dev, scope: kAudioObjectPropertyScopeInput) > 0 else {
            OALog.warn("Requested input device has no input channels; ignoring input source.")
            return nil
        }
        let nr = DeviceUtil.nominalSampleRate(dev)
        let inRate = nr > 0 ? nr : captureRate
        let ratio = inRate / captureRate
        let inBuf = max(64, DeviceUtil.bufferFrameSize(dev))
        // Cushion (in INPUT frames) covering one input buffer plus one capture
        // buffer's worth of input, with headroom for bursty (Bluetooth) delivery.
        let worst = max(Double(inBuf), Double(max(64, captureBufferFrames)) * ratio)
        let target = max(512, Int((worst * 3).rounded()))
        let capacity = max(Int(inRate), target * 16)
        let bridge = ClockBridge(capacityFrames: capacity, targetFrames: target,
                                 baseRatio: ratio, deviceSampleRate: captureRate,
                                 kpPPM: 300, kiPPM: 40, maxPPM: 500)

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
        let storage = bridge.storagePointer
        let cap = bridge.capacityFrames
        let widx = bridge.writeIndexPointer
        let produced = bridge.producedFramesPointer
        let producerCalls = bridge.producerCallbacksPointer

        let block: AudioDeviceIOBlock = { (_, inInputData, _, _, _) in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var bi = 0
            while bi < list.count {
                let ch = Int(list[bi].mNumberChannels)
                if ch > 0, let raw = list[bi].mData {
                    let src = raw.assumingMemoryBound(to: Float.self)
                    let frames = min(maxFrames, Int(list[bi].mDataByteSize) / (ch * MemoryLayout<Float>.size))
                    var i = 0
                    while i < frames {
                        let l = src[i * ch]
                        scratch[i * 2] = l
                        scratch[i * 2 + 1] = ch > 1 ? src[i * ch + 1] : l
                        i += 1
                    }
                    bridgePush(storage: storage, capacityFrames: cap, writeIndex: widx,
                               producedFrames: produced, src: scratch, frames: frames)
                    producerCalls.pointee = producerCalls.pointee &+ 1
                    return
                }
                bi += 1
            }
        }

        var pid: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, nil, block)
        guard created == noErr, let pid else {
            OALog.warn("Input IOProc creation failed: OSStatus \(osStatusString(created)); ignoring input source.")
            scratch.deallocate()
            return nil
        }
        let src = InputSource(deviceID: dev, uid: DeviceUtil.uid(dev), name: DeviceUtil.name(dev),
                              inputRate: inRate, bridge: bridge, scratch: scratch)
        let st = AudioDeviceStart(dev, pid)
        guard st == noErr else {
            OALog.warn("Input AudioDeviceStart failed: OSStatus \(osStatusString(st)) " +
                       "(microphone permission may be required); ignoring input source.")
            AudioDeviceDestroyIOProcID(dev, pid)
            scratch.deallocate()
            return nil
        }
        src.procID = pid
        src.started = true
        OALog.info(String(format: "Input '%@' @ %.0f Hz -> capture %.0f Hz (base ratio %.6f)",
                          src.name, inRate, captureRate, ratio))
        return src
    }

    /// Retune after the capture rate or the input device's own rate changed
    /// (off-RT). Safe to call repeatedly.
    public func retune(captureRate: Double) {
        let nr = DeviceUtil.nominalSampleRate(deviceID)
        if nr > 0 { inputRate = nr }
        let base = inputRate / captureRate
        // The PI controller's dt is frames / sampleRate of the CONSUMER (the
        // capture clock). An aligned Double store is never torn; the consumer
        // reads it once per cycle.
        if abs(bridge.consumerCtxPointer.pointee.sampleRate - captureRate) > 0.5 {
            bridge.consumerCtxPointer.pointee.sampleRate = captureRate
        }
        if abs(base - bridge.currentBaseRatio()) > 1e-9 {
            bridge.setBaseRatio(base)
            OALog.event(String(format: "Input '%@': %.0f Hz -> capture %.0f Hz, base ratio retuned to %.6f",
                               name, inputRate, captureRate, base))
        }
    }

    /// Stop the IOProc (synchronous w.r.t. the HAL cycle). Call only after the
    /// capture graph (the ring's consumer) has been torn down.
    public func stop() {
        guard started, let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        started = false
        procID = nil
        scratch.deallocate()
    }
}
