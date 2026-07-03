// CaptureAggregate.swift
// Builds ONE private aggregate (NF-S1): default output device as main
// sub-device + one process tap PER SOURCE LANE (a system-wide tap, or one tap
// per selected app) + optionally a real input device (drift-compensated inside
// the aggregate; NF-S2 — the app adds no second SRC). A single IOProc captures
// all source streams in one callback, applies per-lane gain/mute/pan + tap
// attenuation compensation + a short splice fade-in, sums to ONE stereo bus
// per routed bus, and pushes each bus into its bridge ring (audio-critical)
// and the full mix into a monitor ring (off-RT meters/recording).

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

public enum EngineTapMode {
    case system
    /// One tap lane per app; each lane mixes down ALL of that app's process
    /// objects (browsers emit audio from helper processes, so a lane is a
    /// responsible-PID group, not a single PID). An empty group is a silent
    /// placeholder lane that keeps gain/mute/meter indexing stable until the
    /// app's audio process appears.
    case processes([[AudioObjectID]])
}

/// POD context read/written by the RT capture callback only (single thread).
public struct CaptureCtx {
    // Source layout within the aggregate's input AudioBufferList.
    public var numTaps: Int            // >= 1 (a placeholder silent tap exists in input-only mode)
    public var tapBufIndices: UnsafeMutablePointer<Int32>   // numTaps entries
    public var tapChannels: UnsafeMutablePointer<Int32>     // numTaps entries
    public var inputBufIndex: Int      // -1 if no input device
    public var inputChannels: Int
    public var numSources: Int         // numTaps (+1 with input)
    public var compGain: Float         // tap attenuation compensation

    // Mix params: packed (L,R) gain words, one aligned 64-bit load each.
    // Index 0..<numTaps = tap lanes, index numTaps = input.
    public var gainWords: UnsafeMutablePointer<UInt64>

    // Monitor selection: packed (Int32 busIndex, Float linear-gain) word
    // (F-M1/M2). busIndex < 0 == off. Single aligned load in the callback.
    public var monitorWord: UnsafeMutablePointer<UInt64>

    // Scratch buffers (preallocated). srcScratch holds one stereo interleaved
    // lane per source, lane s at offset s * maxFrames * 2.
    public var srcScratch: UnsafeMutablePointer<Float>
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
    let numTaps = ctxPtr.pointee.numTaps
    let tapBufIndices = ctxPtr.pointee.tapBufIndices
    let tapChannels = ctxPtr.pointee.tapChannels

    // Frame count for this cycle: from the first resolvable tap buffer, else
    // the input buffer (per-lane reads clamp to their own buffer sizes below).
    let inputIdx = ctxPtr.pointee.inputBufIndex
    let inputChannels = ctxPtr.pointee.inputChannels
    var frames = 0
    var t = 0
    while t < numTaps {
        let bi = Int(tapBufIndices[t])
        let ch = Int(tapChannels[t])
        if bi >= 0 && bi < nbuf && ch > 0 {
            frames = Int(bufs[bi].mDataByteSize) / (ch * MemoryLayout<Float>.size)
            break
        }
        t += 1
    }
    if frames == 0, inputIdx >= 0 && inputIdx < nbuf, inputChannels > 0 {
        frames = Int(bufs[inputIdx].mDataByteSize) / (inputChannels * MemoryLayout<Float>.size)
    }
    let n = min(frames, ctxPtr.pointee.maxFrames)
    if n <= 0 { return }

    let comp = ctxPtr.pointee.compGain
    let gainWords = ctxPtr.pointee.gainWords
    let srcScratch = ctxPtr.pointee.srcScratch
    let busAccum = ctxPtr.pointee.busAccum
    let mon = ctxPtr.pointee.mon
    let monCh = ctxPtr.pointee.monChannels
    let numSources = ctxPtr.pointee.numSources
    let maxFrames = ctxPtr.pointee.maxFrames
    let laneStride = maxFrames * 2

    let fadeFrames = ctxPtr.pointee.fadeFrames
    let fadeRemaining = ctxPtr.pointee.fadeRemaining
    let fadeDone = fadeFrames - fadeRemaining

    @inline(__always)
    func fadeK(_ i: Int) -> Float {
        guard fadeRemaining > 0 else { return 1 }
        let idxInFade = fadeDone + i
        return idxInFade < fadeFrames ? Float(idxInFade) / Float(fadeFrames) : 1
    }

    // Pass 1: render each source's per-frame stereo into its scratch lane
    // (gain / comp / pan / fade). Lanes 0..<numTaps are taps; lane numTaps is
    // the input device (when present). Each lane clamps to its own buffer size.
    var s = 0
    while s < numTaps {
        let lane = srcScratch + s * laneStride
        let bi = Int(tapBufIndices[s])
        let ch = Int(tapChannels[s])
        var srcFrames = 0
        var sp: UnsafeMutablePointer<Float>? = nil
        if bi >= 0 && bi < nbuf, ch > 0, let data = bufs[bi].mData {
            sp = data.assumingMemoryBound(to: Float.self)
            srcFrames = Int(bufs[bi].mDataByteSize) / (ch * MemoryLayout<Float>.size)
        }
        let (gL0, gR0) = unpackGainPair(gainWords[s])
        let gL = gL0 * comp
        let gR = gR0 * comp
        var i = 0
        if let sp {
            let m = min(n, srcFrames)
            while i < m {
                let k = fadeK(i)
                lane[i * 2]     = sp[i * ch] * gL * k
                lane[i * 2 + 1] = sp[i * ch + (ch > 1 ? 1 : 0)] * gR * k
                i += 1
            }
        }
        while i < n { lane[i * 2] = 0; lane[i * 2 + 1] = 0; i += 1 }
        s += 1
    }
    if inputIdx >= 0 {
        let lane = srcScratch + numTaps * laneStride
        var srcFrames = 0
        var ip: UnsafeMutablePointer<Float>? = nil
        if inputIdx < nbuf, inputChannels > 0, let idata = bufs[inputIdx].mData {
            ip = idata.assumingMemoryBound(to: Float.self)
            srcFrames = Int(bufs[inputIdx].mDataByteSize) / (inputChannels * MemoryLayout<Float>.size)
        }
        let (gL, gR) = unpackGainPair(gainWords[numTaps])
        var i = 0
        if let ip {
            let m = min(n, srcFrames)
            while i < m {
                let k = fadeK(i)
                let l = ip[i * inputChannels]
                let r = inputChannels > 1 ? ip[i * inputChannels + 1] : l
                lane[i * 2]     = l * gL * k
                lane[i * 2 + 1] = r * gR * k
                i += 1
            }
        }
        while i < n { lane[i * 2] = 0; lane[i * 2 + 1] = 0; i += 1 }
    }
    if fadeRemaining > 0 {
        ctxPtr.pointee.fadeRemaining = max(0, fadeRemaining - n)
    }

    // Pass 1b: the routing-independent full mix + per-source columns into the
    // monitor ring (mon columns 0/1 == sum of all sources, then a stereo pair
    // per source). The monitor's mix column drives the silence watchdog, so
    // keeping it pre-routing means toggling a route never false-triggers a
    // capture rebuild.
    var i = 0
    while i < n {
        let mb = i * monCh
        var bL: Float = 0
        var bR: Float = 0
        var sc = 0
        while sc < numSources {
            let l = srcScratch[sc * laneStride + i * 2]
            let r = srcScratch[sc * laneStride + i * 2 + 1]
            bL += l
            bR += r
            mon[mb + 2 + sc * 2]     = l
            mon[mb + 2 + sc * 2 + 1] = r
            sc += 1
        }
        mon[mb] = bL
        mon[mb + 1] = bR
        i += 1
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

        var first = true
        var sc = 0
        while sc < numSources {
            if (routing & routeBit(source: sc, bus: b)) != 0 {
                let lane = srcScratch + sc * laneStride
                if first {
                    memcpy(busAccum, lane, n2 * MemoryLayout<Float>.size)
                    first = false
                } else {
                    var f = 0
                    while f < n2 { busAccum[f] += lane[f]; f += 1 }
                }
            }
            sc += 1
        }
        if first { memset(busAccum, 0, n2 * MemoryLayout<Float>.size) }

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

/// One live capture graph (taps + aggregate + IOProc). Rebuilt wholesale by the
/// watchdog / device-change handler; the bridge + monitor rings persist.
public final class CaptureGraph {
    public let tapIDs: [AudioObjectID]
    public let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    public let format: AudioStreamBasicDescription
    public let compGain: Float
    /// True when this graph's taps exclude our own process (feedback guard is
    /// active). False only in the rare degraded case where the HAL had not yet
    /// minted our process object at build time (system taps only). Per-PID taps
    /// are always safe (own process asserted absent) and report true.
    public let selfExcluded: Bool

    private let ctxPtr: UnsafeMutablePointer<CaptureCtx>
    private let tapBufIndices: UnsafeMutablePointer<Int32>
    private let tapChannelsPtr: UnsafeMutablePointer<Int32>
    private let srcScratch: UnsafeMutablePointer<Float>
    private let busAccum: UnsafeMutablePointer<Float>
    private let mon: UnsafeMutablePointer<Float>
    private var started = false
    private var tornDown = false

    private init(tapIDs: [AudioObjectID],
                 aggregateID: AudioObjectID,
                 ioProcID: AudioDeviceIOProcID,
                 format: AudioStreamBasicDescription,
                 compGain: Float,
                 selfExcluded: Bool,
                 ctxPtr: UnsafeMutablePointer<CaptureCtx>,
                 tapBufIndices: UnsafeMutablePointer<Int32>,
                 tapChannelsPtr: UnsafeMutablePointer<Int32>,
                 srcScratch: UnsafeMutablePointer<Float>,
                 busAccum: UnsafeMutablePointer<Float>,
                 mon: UnsafeMutablePointer<Float>) {
        self.tapIDs = tapIDs
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.format = format
        self.compGain = compGain
        self.selfExcluded = selfExcluded
        self.ctxPtr = ctxPtr
        self.tapBufIndices = tapBufIndices
        self.tapChannelsPtr = tapChannelsPtr
        self.srcScratch = srcScratch
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
        // 1. Tap descriptions — ONE TAP PER LANE. Feedback guard (docs/plan.md
        // Phase 3): every tap MUST exclude our own process so the monitor
        // pass-through we write to the output device is never re-captured into
        // a tap (howl loop).
        let ownProc = AudioProcessCatalog.ownProcessObject()
        var descriptions: [CATapDescription] = []
        var selfExcluded = false
        // Per-app lanes may fall back to a silent placeholder tap when one
        // process dies between snapshot and (re)build — a single dead app must
        // not take down the whole graph (or watchdog-rebuild-loop it).
        var allowPlaceholderFallback = false
        switch mode {
        case .system:
            // System-wide: use the exclude-list variant with our own process
            // object. If the HAL has not yet minted a process object for us
            // (ownProc == 0 — no audio produced yet), warn: this cycle cannot
            // self-exclude. In the normal Engine flow the bus consumer IOProcs
            // are already running before the tap is built, so ownProc resolves.
            if ownProc != 0 {
                descriptions.append(CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProc]))
                selfExcluded = true
                OALog.info("System tap excludes own process (pid \(getpid()), process object \(ownProc)) — monitor feedback guard active.")
            } else {
                OALog.warn("Own audio process object not yet available; system tap built WITHOUT self-exclusion this cycle (monitor feedback guard degraded).")
                descriptions.append(CATapDescription(stereoGlobalTapButExcludeProcesses: []))
            }
        case .processes(let lanes):
            // Per-app: assert our own process is never in the capture set.
            if ownProc != 0, lanes.contains(where: { $0.contains(ownProc) }) {
                throw OAError("Refusing to tap our own process (feedback guard).")
            }
            // Per-app taps never include our process, so they are feedback-safe.
            selfExcluded = true
            if lanes.isEmpty {
                // Input-only: a placeholder silent tap keeps the aggregate /
                // lane layout uniform (lane 0 delivers silence).
                descriptions.append(CATapDescription(stereoMixdownOfProcesses: []))
            } else {
                for objs in lanes {
                    // An empty group is a valid silent placeholder lane.
                    descriptions.append(CATapDescription(stereoMixdownOfProcesses: objs))
                }
                allowPlaceholderFallback = true
            }
        }
        let numTaps = descriptions.count
        guard numTaps == params.tapCount else {
            throw OAError("Tap lane count mismatch: \(numTaps) taps vs \(params.tapCount) param lanes")
        }

        // 2. Create the taps (destroy all created so far on any failure).
        var tapIDs: [AudioObjectID] = []
        func destroyTaps() { for id in tapIDs { AudioHardwareDestroyProcessTap(id) } }
        func createTap(_ description: CATapDescription, _ i: Int) -> AudioObjectID? {
            description.name = "OpenAudio-Engine-Tap-\(i + 1)"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tapID: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr, tapID != 0 else {
                OALog.warn("AudioHardwareCreateProcessTap failed for lane \(i + 1): OSStatus \(osStatusString(status)).")
                return nil
            }
            return tapID
        }
        for (i, description) in descriptions.enumerated() {
            var tapID = createTap(description, i)
            if tapID == nil, allowPlaceholderFallback {
                // The app behind this lane likely quit; keep the lane (and the
                // gain-word / meter indexing) alive with a silent placeholder.
                OALog.warn("Lane \(i + 1): falling back to a silent placeholder tap.")
                tapID = createTap(CATapDescription(stereoMixdownOfProcesses: []), i)
            }
            guard let tapID else {
                destroyTaps()
                throw OAError(
                    "AudioHardwareCreateProcessTap failed.\n" +
                    "System audio-capture permission (TCC) may be required for the hosting terminal.")
            }
            tapIDs.append(tapID)
        }

        var teardownOwns = false
        do {
            var tapUIDs: [String] = []
            var tapFormats: [AudioStreamBasicDescription] = []
            for tapID in tapIDs {
                let uid = try CAProperty.string(tapID, kAudioTapPropertyUID)
                let format: AudioStreamBasicDescription = try CAProperty.scalar(
                    tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
                guard format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
                    throw OAError("Tap reported invalid format (ch=\(format.mChannelsPerFrame), sr=\(format.mSampleRate))")
                }
                tapUIDs.append(uid)
                tapFormats.append(format)
            }

            // 3. Default output device (aggregate main / clock master).
            let outputDevice = DeviceUtil.defaultOutputDevice()
            guard outputDevice != 0 else { throw OAError("No default output device is set") }
            let outputUID = try CAProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)

            // Attenuation compensation from output device pair count.
            let outCh = DeviceUtil.channelCount(outputDevice, scope: kAudioObjectPropertyScopeOutput)
            let pairCount = max(1, (outCh + 1) / 2)
            let compGain: Float = pairCount > 1 ? Float(pairCount) : 1.0

            // 4. Optional real input device sub-device (drift-compensated).
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

            // 5. Build the private aggregate.
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
                kAudioAggregateDeviceTapListKey: tapUIDs.map { uid in
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: uid,
                    ]
                },
            ]

            var aggregateID: AudioObjectID = 0
            try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            guard aggregateID != 0 else { throw OAError("AudioHardwareCreateAggregateDevice returned null") }

            // 6. Determine the source buffer layout from the aggregate's input
            // streams. Convention observed on macOS (verified empirically for
            // the single-tap case): sub-device input streams precede the tap
            // streams, and taps appear in tap-list order — so the taps are the
            // LAST numTaps buffers and the input device (when present) is
            // buffer 0.
            let layout = DeviceUtil.streamChannelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)
            OALog.info("Aggregate input stream layout (channels per buffer): \(layout)")
            var inputBufIndex = -1
            var effInputChannels = 0
            let firstTapBuf = max(0, layout.count - numTaps)
            if inputUID != nil && inputChannels > 0 && firstTapBuf > 0 {
                inputBufIndex = 0
                effInputChannels = layout.first ?? inputChannels
            }
            let numSources = numTaps + (inputBufIndex >= 0 ? 1 : 0)
            // The monitor ring's channel count is authoritative for the RT
            // write stride: MonitorRing.write copies `ring.channels` floats per
            // frame. The ring is sized off the engine's configured source count
            // (numTaps + hasInput), which is >= the count actually resolved
            // here (an `--input` device can fail to resolve). Match `mon` to
            // the ring so the RT write can never overrun; unresolved input
            // columns stay zero (pre-initialized, never written).
            let monChannels = monRing.channels

            // 7. Preallocate scratch + RT context.
            let tapBufIndices = UnsafeMutablePointer<Int32>.allocate(capacity: numTaps)
            let tapChannelsPtr = UnsafeMutablePointer<Int32>.allocate(capacity: numTaps)
            for t in 0..<numTaps {
                let bufIdx = firstTapBuf + t
                tapBufIndices[t] = bufIdx < layout.count ? Int32(bufIdx) : -1
                tapChannelsPtr[t] = bufIdx < layout.count
                    ? Int32(layout[bufIdx])
                    : Int32(tapFormats[t].mChannelsPerFrame)
            }
            let laneCount = numTaps + 1   // input lane slot always allocated
            let srcScratch = UnsafeMutablePointer<Float>.allocate(capacity: laneCount * maxFrames * 2)
            srcScratch.initialize(repeating: 0, count: laneCount * maxFrames * 2)
            let busAccum = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            busAccum.initialize(repeating: 0, count: maxFrames * 2)
            let mon = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * monChannels)
            mon.initialize(repeating: 0, count: maxFrames * monChannels)

            func freeScratch() {
                tapBufIndices.deallocate(); tapChannelsPtr.deallocate()
                srcScratch.deallocate(); busAccum.deallocate(); mon.deallocate()
            }

            let ctxPtr = UnsafeMutablePointer<CaptureCtx>.allocate(capacity: 1)
            ctxPtr.initialize(to: CaptureCtx(
                numTaps: numTaps,
                tapBufIndices: tapBufIndices,
                tapChannels: tapChannelsPtr,
                inputBufIndex: inputBufIndex,
                inputChannels: effInputChannels,
                numSources: numSources,
                compGain: compGain,
                gainWords: params.wordsPointer,
                monitorWord: monitorWord,
                srcScratch: srcScratch,
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

            // 8. IOProc capturing all source streams in one callback.
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
                tapIDs: tapIDs, aggregateID: aggregateID, ioProcID: ioProcID,
                format: tapFormats[0], compGain: compGain, selfExcluded: selfExcluded,
                ctxPtr: ctxPtr,
                tapBufIndices: tapBufIndices, tapChannelsPtr: tapChannelsPtr,
                srcScratch: srcScratch, busAccum: busAccum, mon: mon)
            teardownOwns = true

            do {
                try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
                graph.started = true
            } catch {
                graph.teardown()
                throw error
            }
            let gainDB = 20 * log10(Double(compGain))
            OALog.info(String(format: "Capture graph: %d tap(s) @ %.0f Hz, %d source(s), comp x%.0f (%+.1f dB)",
                              numTaps, tapFormats[0].mSampleRate, numSources, compGain, gainDB))
            return graph
        } catch {
            if !teardownOwns { destroyTaps() }
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
        for tapID in tapIDs { AudioHardwareDestroyProcessTap(tapID) }
        ctxPtr.deinitialize(count: 1)
        ctxPtr.deallocate()
        tapBufIndices.deallocate()
        tapChannelsPtr.deallocate()
        srcScratch.deallocate()
        busAccum.deallocate()
        mon.deallocate()
    }
}
