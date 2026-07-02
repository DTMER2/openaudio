// CaptureAggregate.swift
// Builds ONE private aggregate (NF-S1): default output device as main
// sub-device + a process tap (system-wide or specific PIDs) + optionally a real
// input device (drift-compensated inside the aggregate; NF-S2 — the app adds no
// second SRC). A single IOProc captures all source streams in one callback,
// applies per-source gain/mute/pan + tap attenuation compensation + a short
// splice fade-in, sums to ONE stereo bus, and pushes the bus into the bridge
// ring (audio-critical) and a monitor ring (off-RT meters/recording).

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

public enum EngineTapMode {
    case system
    case processes([AudioObjectID])
}

/// POD context read/written by the RT capture callback only (single thread).
public struct CaptureCtx {
    // Source layout within the aggregate's input AudioBufferList.
    public var tapBufIndex: Int
    public var tapChannels: Int
    public var inputBufIndex: Int      // -1 if no input device
    public var inputChannels: Int
    public var numSources: Int         // 1 (tap) or 2 (tap + input)
    public var compGain: Float         // tap attenuation compensation

    // Mix params: packed (L,R) gain words, one atomic 64-bit load each.
    public var tapGainWord: UnsafeMutablePointer<UInt64>
    public var inputGainWord: UnsafeMutablePointer<UInt64>

    // Monitor selection: packed (Int32 busIndex, Float linear-gain) word
    // (F-M1/M2). busIndex < 0 == off. Single aligned load in the callback.
    public var monitorWord: UnsafeMutablePointer<UInt64>

    // Scratch buffers (preallocated, stereo interleaved).
    public var tapScratch: UnsafeMutablePointer<Float>    // per-frame source stereo
    public var inputScratch: UnsafeMutablePointer<Float>
    public var busAccum: UnsafeMutablePointer<Float>      // per-bus mix accumulator
    public var mon: UnsafeMutablePointer<Float>           // monChannels interleaved
    public var monChannels: Int
    public var maxFrames: Int

    // Routing matrix + bus fan-out (Phase 2).
    // Slot array of atomic pointers to BusRTContext (published/retired off-RT).
    public var busSlots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    public var maxBuses: Int
    // Routing matrix snapshot: bit (source * maxBuses + bus) enables the pair.
    public var routingWord: UnsafeMutablePointer<UInt64>
    // Producer cycle counter (one increment per callback) for the detach epoch
    // handshake — lets an off-RT retire know when the callback can no longer
    // observe a just-nulled slot pointer.
    public var captureCycles: UnsafeMutablePointer<UInt64>

    // Monitor ring producer.
    public var monRing: UnsafeMutablePointer<MonRTContext>

    // Splice fade-in (per graph instance).
    public var fadeFrames: Int
    public var fadeRemaining: Int
}

@inline(__always)
public func captureProcess(_ ctxPtr: UnsafeMutablePointer<CaptureCtx>,
                           _ inInputData: UnsafePointer<AudioBufferList>,
                           _ outOutputData: UnsafeMutablePointer<AudioBufferList>?) {
    // --- Monitoring (F-M1/M2). The aggregate's main sub-device IS the real
    // default output, so writing the selected bus mix into THIS callback's
    // output ABL passes it through on the same clock (no SRC, no extra IOProc).
    // Read the packed snapshot with a single aligned load; zero every output
    // buffer up front so we never leak stale samples into the output device
    // when monitoring is off or the selected bus is absent. The monitor mix (if
    // any) is written into channels 0/1 during the bus fan-out pass below.
    let (monBus, monGain) = unpackMonitor(ctxPtr.pointee.monitorWord.pointee)
    var outList: UnsafeMutableAudioBufferListPointer? = nil
    if let outOutputData {
        let ol = UnsafeMutableAudioBufferListPointer(outOutputData)
        var bi = 0
        while bi < ol.count {
            if let d = ol[bi].mData { memset(d, 0, Int(ol[bi].mDataByteSize)) }
            bi += 1
        }
        outList = ol
    }

    let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    let nbuf = bufs.count
    let tapIdx = ctxPtr.pointee.tapBufIndex
    if tapIdx >= nbuf { return }

    let tapChannels = ctxPtr.pointee.tapChannels
    let tapBuf = bufs[tapIdx]
    guard let tapData = tapBuf.mData else { return }
    let tp = tapData.assumingMemoryBound(to: Float.self)
    let frames = Int(tapBuf.mDataByteSize) / (tapChannels * MemoryLayout<Float>.size)
    let n = min(frames, ctxPtr.pointee.maxFrames)
    if n <= 0 { return }

    // Read the mix params: each (L,R) pair is one aligned 64-bit word, so a
    // single load can never observe a torn pair.
    let (tapL, tapR) = unpackGainPair(ctxPtr.pointee.tapGainWord.pointee)
    let (inLg, inRg) = unpackGainPair(ctxPtr.pointee.inputGainWord.pointee)

    let comp = ctxPtr.pointee.compGain
    let gLt = tapL * comp
    let gRt = tapR * comp
    let gLi = inLg
    let gRi = inRg

    // Input source pointer (optional). Frames clamped to the input buffer's
    // own size in case a cycle ever delivers fewer input than tap frames.
    let inputIdx = ctxPtr.pointee.inputBufIndex
    let inputChannels = ctxPtr.pointee.inputChannels
    var ip: UnsafeMutablePointer<Float>? = nil
    var inFrames = 0
    if inputIdx >= 0 && inputIdx < nbuf, inputChannels > 0, let idata = bufs[inputIdx].mData {
        ip = idata.assumingMemoryBound(to: Float.self)
        inFrames = Int(bufs[inputIdx].mDataByteSize) / (inputChannels * MemoryLayout<Float>.size)
    }

    let tapScratch = ctxPtr.pointee.tapScratch
    let inputScratch = ctxPtr.pointee.inputScratch
    let busAccum = ctxPtr.pointee.busAccum
    let mon = ctxPtr.pointee.mon
    let monCh = ctxPtr.pointee.monChannels
    let numSources = ctxPtr.pointee.numSources

    let fadeFrames = ctxPtr.pointee.fadeFrames
    var fadeRemaining = ctxPtr.pointee.fadeRemaining
    let fadeDone = fadeFrames - fadeRemaining

    // Pass 1: render each source's per-frame stereo into scratch (gain / comp /
    // pan / fade), and the routing-independent full mix into the monitor ring
    // (mon column 0/1 == tap + input). The monitor's bus column drives the
    // silence watchdog, so keeping it pre-routing means toggling a route never
    // false-triggers a capture rebuild.
    var i = 0
    while i < n {
        var k: Float = 1
        if fadeRemaining > 0 {
            let idxInFade = fadeDone + i
            k = idxInFade < fadeFrames ? Float(idxInFade) / Float(fadeFrames) : 1
        }

        // Tap (stereo interleaved), attenuation-compensated + gain/pan.
        let tL = tp[i * tapChannels] * gLt * k
        let tR = tp[i * tapChannels + 1] * gRt * k
        tapScratch[i * 2] = tL
        tapScratch[i * 2 + 1] = tR

        var iL: Float = 0
        var iR: Float = 0
        if let ip, i < inFrames {
            let l = ip[i * inputChannels]
            let r = inputChannels > 1 ? ip[i * inputChannels + 1] : l
            iL = l * gLi * k
            iR = r * gRi * k
        }
        inputScratch[i * 2] = iL
        inputScratch[i * 2 + 1] = iR

        // Full (pre-routing) mix for monitor / watchdog / recording.
        let bL = tL + iL
        let bR = tR + iR
        let mb = i * monCh
        mon[mb] = bL
        mon[mb + 1] = bR
        mon[mb + 2] = tL
        mon[mb + 3] = tR
        if numSources > 1 {
            mon[mb + 4] = iL
            mon[mb + 5] = iR
        }
        i += 1
    }
    if fadeRemaining > 0 {
        fadeRemaining = max(0, fadeRemaining - n)
        ctxPtr.pointee.fadeRemaining = fadeRemaining
    }

    // Pass 2: fan out to buses. Read one atomic routing snapshot, then per
    // published bus accumulate the enabled sources and push the stereo mix
    // into that bus's bridge ring. A bus with nothing routed still receives
    // silence (keeps the bridge fed — no underrun on a route toggle).
    let routing = ctxPtr.pointee.routingWord.pointee
    let slots = ctxPtr.pointee.busSlots
    let maxBuses = ctxPtr.pointee.maxBuses
    let n2 = n * 2
    var b = 0
    while b < maxBuses {
        // Acquire the slot pointer; the off-RT publisher fenced before the store.
        OSMemoryBarrier()
        guard let raw = slots[b] else { b += 1; continue }
        let bc = raw.assumingMemoryBound(to: BusRTContext.self)

        let tapOn = (routing & routeBit(source: 0, bus: b)) != 0
        let inOn = numSources > 1 && (routing & routeBit(source: 1, bus: b)) != 0

        if tapOn && inOn {
            var s = 0
            while s < n2 { busAccum[s] = tapScratch[s] + inputScratch[s]; s += 1 }
        } else if tapOn {
            memcpy(busAccum, tapScratch, n2 * MemoryLayout<Float>.size)
        } else if inOn {
            memcpy(busAccum, inputScratch, n2 * MemoryLayout<Float>.size)
        } else {
            memset(busAccum, 0, n2 * MemoryLayout<Float>.size)
        }

        bridgePush(storage: bc.pointee.storage,
                   capacityFrames: bc.pointee.capacityFrames,
                   writeIndex: bc.pointee.writeIndex,
                   producedFrames: bc.pointee.producedFrames,
                   src: busAccum,
                   frames: n)
        bc.pointee.producerCallbacks.pointee = bc.pointee.producerCallbacks.pointee &+ 1

        // Monitor pass-through: if this is the selected bus, write its stereo
        // mix (already fade/route-applied in busAccum) into the output device,
        // scaled by the monitor gain. Untouched channels keep the zero we wrote
        // up front. The tap excludes our own process, so this write is never
        // re-captured (no howl loop). Handles the two output ABL layouts
        // defensively: interleaved (buffer 0 with >=2 ch) and non-interleaved
        // (one mono buffer per channel); a genuinely mono device gets L+R.
        if monBus >= 0, Int(monBus) == b, let ol = outList, ol.count > 0, let od0 = ol[0].mData {
            let ch0 = Int(ol[0].mNumberChannels)
            if ch0 >= 2 {
                // Interleaved stereo (or more) in buffer 0.
                let outFrames = Int(ol[0].mDataByteSize) / (ch0 * MemoryLayout<Float>.size)
                let m = min(n, outFrames)
                let op = od0.assumingMemoryBound(to: Float.self)
                var f = 0
                while f < m {
                    op[f * ch0]     = busAccum[f * 2]     * monGain
                    op[f * ch0 + 1] = busAccum[f * 2 + 1] * monGain
                    f += 1
                }
            } else if ch0 == 1, ol.count >= 2, Int(ol[1].mNumberChannels) == 1, let od1 = ol[1].mData {
                // Non-interleaved stereo: L -> buffer 0, R -> buffer 1.
                let f0 = Int(ol[0].mDataByteSize) / MemoryLayout<Float>.size
                let f1 = Int(ol[1].mDataByteSize) / MemoryLayout<Float>.size
                let m = min(n, min(f0, f1))
                let lp = od0.assumingMemoryBound(to: Float.self)
                let rp = od1.assumingMemoryBound(to: Float.self)
                var f = 0
                while f < m {
                    lp[f] = busAccum[f * 2]     * monGain
                    rp[f] = busAccum[f * 2 + 1] * monGain
                    f += 1
                }
            } else if ch0 == 1 {
                // Genuinely mono output device: downmix L+R.
                let outFrames = Int(ol[0].mDataByteSize) / MemoryLayout<Float>.size
                let m = min(n, outFrames)
                let op = od0.assumingMemoryBound(to: Float.self)
                var f = 0
                while f < m {
                    op[f] = (busAccum[f * 2] + busAccum[f * 2 + 1]) * 0.5 * monGain
                    f += 1
                }
            }
        }
        b += 1
    }

    // Publish the producer cycle count for the detach epoch handshake.
    ctxPtr.pointee.captureCycles.pointee = ctxPtr.pointee.captureCycles.pointee &+ 1

    // Push [full mix + sources] into the off-RT monitor/recorder ring.
    ctxPtr.pointee.monRing.pointee.write(mon, frames: n)
}

/// One live capture graph (tap + aggregate + IOProc). Rebuilt wholesale by the
/// watchdog / device-change handler; the bridge + monitor rings persist.
public final class CaptureGraph {
    public let tapID: AudioObjectID
    public let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    public let format: AudioStreamBasicDescription
    public let compGain: Float
    /// True when this graph's tap excludes our own process (feedback guard is
    /// active). False only in the rare degraded case where the HAL had not yet
    /// minted our process object at build time (system taps only). Per-PID taps
    /// are always safe (own process asserted absent) and report true.
    public let selfExcluded: Bool

    private let ctxPtr: UnsafeMutablePointer<CaptureCtx>
    private let tapScratch: UnsafeMutablePointer<Float>
    private let inputScratch: UnsafeMutablePointer<Float>
    private let busAccum: UnsafeMutablePointer<Float>
    private let mon: UnsafeMutablePointer<Float>
    private var started = false
    private var tornDown = false

    private init(tapID: AudioObjectID,
                 aggregateID: AudioObjectID,
                 ioProcID: AudioDeviceIOProcID,
                 format: AudioStreamBasicDescription,
                 compGain: Float,
                 selfExcluded: Bool,
                 ctxPtr: UnsafeMutablePointer<CaptureCtx>,
                 tapScratch: UnsafeMutablePointer<Float>,
                 inputScratch: UnsafeMutablePointer<Float>,
                 busAccum: UnsafeMutablePointer<Float>,
                 mon: UnsafeMutablePointer<Float>) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.format = format
        self.compGain = compGain
        self.selfExcluded = selfExcluded
        self.ctxPtr = ctxPtr
        self.tapScratch = tapScratch
        self.inputScratch = inputScratch
        self.busAccum = busAccum
        self.mon = mon
    }

    // MARK: Build

    public static func build(mode: EngineTapMode,
                             inputDeviceUID: String?,
                             busSlots: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                             maxBuses: Int,
                             routingWord: UnsafeMutablePointer<UInt64>,
                             captureCycles: UnsafeMutablePointer<UInt64>,
                             monRing: MonitorRing,
                             params: MixParamsStore,
                             monitorWord: UnsafeMutablePointer<UInt64>,
                             maxFrames: Int,
                             fadeFrames: Int) throws -> CaptureGraph {
        // 1. Tap description. Feedback guard (docs/plan.md Phase 3): every tap
        // MUST exclude our own process so the monitor pass-through we write to
        // the output device is never re-captured into the tap (howl loop).
        let ownProc = AudioProcessCatalog.ownProcessObject()
        let description: CATapDescription
        var selfExcluded = false
        switch mode {
        case .system:
            // System-wide: use the exclude-list variant with our own process
            // object. If the HAL has not yet minted a process object for us
            // (ownProc == 0 — no audio produced yet), warn: this cycle cannot
            // self-exclude. In the normal Engine flow the bus consumer IOProcs
            // are already running before the tap is built, so ownProc resolves.
            if ownProc != 0 {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProc])
                selfExcluded = true
                OALog.info("System tap excludes own process (pid \(getpid()), process object \(ownProc)) — monitor feedback guard active.")
            } else {
                OALog.warn("Own audio process object not yet available; system tap built WITHOUT self-exclusion this cycle (monitor feedback guard degraded).")
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }
        case .processes(let objs):
            // Per-PID: assert our own process is never in the capture set.
            if ownProc != 0, objs.contains(ownProc) {
                throw OAError("Refusing to tap our own process (feedback guard).")
            }
            // Per-PID taps never include our process, so they are feedback-safe.
            selfExcluded = true
            description = CATapDescription(stereoMixdownOfProcesses: objs)
        }
        description.name = "OpenAudio-Engine-Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        if tapStatus != noErr {
            throw OAError(
                "AudioHardwareCreateProcessTap failed: OSStatus \(osStatusString(tapStatus)).\n" +
                "System audio-capture permission (TCC) may be required for the hosting terminal.")
        }
        guard tapID != 0 else { throw OAError("AudioHardwareCreateProcessTap returned a null tap") }

        var teardownOwns = false
        do {
            let tapUID = try CAProperty.string(tapID, kAudioTapPropertyUID)
            let format: AudioStreamBasicDescription = try CAProperty.scalar(
                tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
                throw OAError("Tap reported invalid format (ch=\(format.mChannelsPerFrame), sr=\(format.mSampleRate))")
            }
            let tapChannels = Int(format.mChannelsPerFrame)

            // 2. Default output device (aggregate main / clock master).
            let outputDevice = DeviceUtil.defaultOutputDevice()
            guard outputDevice != 0 else { throw OAError("No default output device is set") }
            let outputUID = try CAProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)

            // Attenuation compensation from output device pair count.
            let outCh = DeviceUtil.channelCount(outputDevice, scope: kAudioObjectPropertyScopeOutput)
            let pairCount = max(1, (outCh + 1) / 2)
            let compGain: Float = pairCount > 1 ? Float(pairCount) : 1.0

            // 3. Optional real input device sub-device (drift-compensated).
            var inputUID: String? = nil
            var inputChannels = 0
            if let req = inputDeviceUID {
                let inDev = (req == "default") ? DeviceUtil.defaultInputDevice() : DeviceUtil.device(forUID: req)
                if inDev != 0 {
                    inputChannels = DeviceUtil.channelCount(inDev, scope: kAudioObjectPropertyScopeInput)
                    if inputChannels > 0 {
                        inputUID = DeviceUtil.uid(inDev)
                    } else {
                        OALog.warn("Requested input device has no input channels; ignoring input source.")
                    }
                } else {
                    OALog.warn("Requested input device '\(req)' not found; ignoring input source.")
                }
            }

            // 4. Build the private aggregate.
            let aggUID = "OpenAudio-Engine-Agg-" + UUID().uuidString
            var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
            if let inputUID, inputUID != outputUID {
                subDevices.append([
                    kAudioSubDeviceUIDKey: inputUID,
                    kAudioSubDeviceDriftCompensationKey: true,
                ])
            }
            let desc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "OpenAudio-Engine",
                kAudioAggregateDeviceUIDKey: aggUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: subDevices,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]],
            ]

            var aggregateID: AudioObjectID = 0
            try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            guard aggregateID != 0 else { throw OAError("AudioHardwareCreateAggregateDevice returned null") }

            // 5. Determine the source buffer layout from the aggregate's input streams.
            let layout = DeviceUtil.streamChannelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)
            OALog.info("Aggregate input stream layout (channels per buffer): \(layout)")
            var tapBufIndex = 0
            var inputBufIndex = -1
            var effInputChannels = 0
            if inputUID == nil || inputChannels == 0 {
                // Tap only: pick the buffer matching the tap channel count, else buffer 0.
                tapBufIndex = layout.firstIndex(of: tapChannels) ?? 0
                inputBufIndex = -1
            } else {
                // Tap + input. Convention observed on macOS: sub-device input
                // streams precede the tap stream, so the tap is the last buffer
                // and the input device is buffer 0. Verified empirically.
                tapBufIndex = max(0, layout.count - 1)
                inputBufIndex = 0
                effInputChannels = layout.first ?? inputChannels
            }
            let numSources = inputBufIndex >= 0 ? 2 : 1
            // The monitor ring's channel count is authoritative for the RT
            // write stride: MonitorRing.write copies `ring.channels` floats per
            // frame. The ring is sized off the engine's configured source count
            // (hasInput), which is >= the count actually resolved here (an
            // `--input` device can fail to resolve). Match `mon` to the ring so
            // the RT write can never overrun; unresolved input columns stay
            // zero (pre-initialized, never written when numSources == 1).
            let monChannels = monRing.channels

            // 6. Preallocate scratch + RT context.
            let tapScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            tapScratch.initialize(repeating: 0, count: maxFrames * 2)
            let inputScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            inputScratch.initialize(repeating: 0, count: maxFrames * 2)
            let busAccum = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            busAccum.initialize(repeating: 0, count: maxFrames * 2)
            let mon = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * monChannels)
            mon.initialize(repeating: 0, count: maxFrames * monChannels)

            func freeScratch() {
                tapScratch.deallocate(); inputScratch.deallocate()
                busAccum.deallocate(); mon.deallocate()
            }

            let ctxPtr = UnsafeMutablePointer<CaptureCtx>.allocate(capacity: 1)
            ctxPtr.initialize(to: CaptureCtx(
                tapBufIndex: tapBufIndex,
                tapChannels: tapChannels,
                inputBufIndex: inputBufIndex,
                inputChannels: effInputChannels,
                numSources: numSources,
                compGain: compGain,
                tapGainWord: params.tapWordPointer,
                inputGainWord: params.inputWordPointer,
                monitorWord: monitorWord,
                tapScratch: tapScratch,
                inputScratch: inputScratch,
                busAccum: busAccum,
                mon: mon,
                monChannels: monChannels,
                maxFrames: maxFrames,
                busSlots: busSlots,
                maxBuses: maxBuses,
                routingWord: routingWord,
                captureCycles: captureCycles,
                monRing: monRing.contextPointer,
                fadeFrames: fadeFrames,
                fadeRemaining: fadeFrames))

            // 7. IOProc capturing all source streams in one callback.
            let block: AudioDeviceIOBlock = { (_, inInputData, _, outOutputData, _) in
                captureProcess(ctxPtr, inInputData, outOutputData)
            }
            var ioProcID: AudioDeviceIOProcID?
            do {
                try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block),
                          "AudioDeviceCreateIOProcIDWithBlock")
            } catch {
                ctxPtr.deinitialize(count: 1); ctxPtr.deallocate()
                freeScratch()
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw error
            }
            guard let ioProcID else {
                ctxPtr.deinitialize(count: 1); ctxPtr.deallocate()
                freeScratch()
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw OAError("AudioDeviceCreateIOProcIDWithBlock returned null")
            }

            let graph = CaptureGraph(
                tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID,
                format: format, compGain: compGain, selfExcluded: selfExcluded,
                ctxPtr: ctxPtr,
                tapScratch: tapScratch, inputScratch: inputScratch,
                busAccum: busAccum, mon: mon)
            teardownOwns = true

            do {
                try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
                graph.started = true
            } catch {
                graph.teardown()
                throw error
            }
            let gainDB = 20 * log10(Double(compGain))
            OALog.info(String(format: "Capture graph: tap %dch @ %.0f Hz, %d source(s), comp x%.0f (%+.1f dB)",
                              tapChannels, format.mSampleRate, numSources, compGain, gainDB))
            return graph
        } catch {
            if !teardownOwns { AudioHardwareDestroyProcessTap(tapID) }
            throw error
        }
    }

    // MARK: Teardown

    public func teardown() {
        if tornDown { return }
        tornDown = true
        // Safety contract: AudioDeviceStop / AudioDeviceDestroyIOProcID are
        // synchronous with respect to the HAL IO cycle — they do not return
        // while this IOProc is mid-callback, so freeing ctx/bus/mon below
        // cannot race an in-flight captureProcess. (Same ordering as the
        // Phase 0 tapcapture teardown, verified in long-running captures.)
        if started {
            AudioDeviceStop(aggregateID, ioProcID)
            started = false
        }
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        ctxPtr.deinitialize(count: 1)
        ctxPtr.deallocate()
        tapScratch.deallocate()
        inputScratch.deallocate()
        busAccum.deallocate()
        mon.deallocate()
    }
}
