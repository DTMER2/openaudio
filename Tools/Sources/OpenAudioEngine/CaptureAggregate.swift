// CaptureAggregate.swift
// Builds ONE private aggregate (NF-S1): a CLOCK device as main sub-device
// (OpenAudio's own virtual device, so the mix never follows a Bluetooth
// headset down to its 16/24 kHz hands-free rate; the default output only as a
// fallback when the driver is absent) + one process tap PER SOURCE LANE (a system-wide tap, or one tap
// per selected app). Real input devices (microphones / interfaces, including
// Bluetooth headsets) are NOT sub-devices: each runs on its own IOProc/clock
// and is resampled into this clock through its own ClockBridge (InputSource),
// so any input rate mixes cleanly. A single IOProc captures all tap streams
// in one callback, pulls every input lane, applies per-lane gain/mute/pan + tap
// attenuation compensation + a short splice fade-in, sums to ONE stereo bus
// per routed bus, and pushes each bus into its bridge ring (audio-critical),
// the monitored bus into the MonitorOutput bridge (real output, own clock),
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
    /// Input-device lanes (numInputs entries): each is the consumer side of
    /// that input's own ClockBridge (the input runs on its own IOProc/clock and
    /// is resampled to the capture rate), or nil when the device could not be
    /// opened (the lane then stays silent so lane indexing is stable).
    public var inputBridges: UnsafeMutablePointer<UnsafeMutablePointer<ConsumerCtx>?>
    public var numInputs: Int
    public var numSources: Int         // numTaps + numInputs
    /// Aggregate IO buffer size, the last-resort cycle length when no tap
    /// buffer is resolvable (input-only engine on a silent placeholder tap).
    public var ioBufferFrames: Int
    public var compGain: Float         // tap attenuation compensation

    // Mix params: packed (L,R) gain words, one aligned 64-bit load each.
    // Index 0..<numTaps = tap lanes, numTaps + j = input lane j.
    public var gainWords: UnsafeMutablePointer<UInt64>

    // Monitor selection: packed (Int32 busIndex, Float linear-gain) word
    // (F-M1/M2). busIndex < 0 == off. Single aligned load in the callback.
    public var monitorWord: UnsafeMutablePointer<UInt64>
    // One-entry slot: BusRTContext of the MonitorOutput bridge (nil == no
    // monitor feed attached). Published/retired off-RT like bus slots.
    public var monitorSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    public var monScratch: UnsafeMutablePointer<Float>    // stereo, gain-applied
    // Non-zero == the monitor feed also carries the input (mic) lanes. Off by
    // default: hearing a headset's own mic back in that headset is delayed
    // self-echo at best and an acoustic feedback loop at worst.
    public var monitorInputsWord: UnsafeMutablePointer<UInt64>

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
    // --- Monitoring (F-M1/M2) goes to the MonitorOutput bridge (the real
    // output runs on its own clock). This aggregate's own output streams are
    // the clock device's; zero them so nothing stale is ever played there.
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

    // Frame count for this cycle: from the first resolvable tap buffer (tap
    // lanes clamp to their own buffer sizes below; input lanes are resampled
    // to exactly this count).
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
    if frames == 0, let ol = outList, ol.count > 0 {
        let ch = Int(ol[0].mNumberChannels)
        if ch > 0 { frames = Int(ol[0].mDataByteSize) / (ch * MemoryLayout<Float>.size) }
    }
    if frames == 0 { frames = ctxPtr.pointee.ioBufferFrames }
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
    // (gain / comp / pan / fade). Lanes 0..<numTaps are taps, then one lane per
    // input device. Each tap lane clamps to its own buffer size.
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
    let numInputs = ctxPtr.pointee.numInputs
    let inputBridges = ctxPtr.pointee.inputBridges
    var j = 0
    while j < numInputs {
        let lane = srcScratch + (numTaps + j) * laneStride
        if let bridge = inputBridges[j] {
            // Pull n frames at the capture rate from this input's own bridge
            // (variable-ratio resample: any input rate -> capture rate).
            bridgeConsume(bridge, out: lane, frames: n, channels: 2)
            let (gL, gR) = unpackGainPair(gainWords[numTaps + j])
            var i = 0
            while i < n {
                let k = fadeK(i)
                lane[i * 2]     *= gL * k
                lane[i * 2 + 1] *= gR * k
                i += 1
            }
        } else {
            memset(lane, 0, n * 2 * MemoryLayout<Float>.size)
        }
        j += 1
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

        // Monitor feed: the selected bus's mix (fade/route already applied),
        // scaled by the monitor gain, into the MonitorOutput bridge. The tap
        // excludes our own process, so the monitor is never re-captured.
        if monBus >= 0, Int(monBus) == b {
            OSMemoryBarrier()
            if let mraw = ctxPtr.pointee.monitorSlot[0] {
                let mc = mraw.assumingMemoryBound(to: BusRTContext.self)
                let ms = ctxPtr.pointee.monScratch
                if numInputs == 0 || ctxPtr.pointee.monitorInputsWord.pointee != 0 {
                    var f = 0
                    while f < n2 { ms[f] = busAccum[f] * monGain; f += 1 }
                } else {
                    // The bus mix minus its input lanes: re-sum the routed taps.
                    memset(ms, 0, n2 * MemoryLayout<Float>.size)
                    var tc = 0
                    while tc < numTaps {
                        if (routing & routeBit(source: tc, bus: b)) != 0 {
                            let lane = srcScratch + tc * laneStride
                            var f = 0
                            while f < n2 { ms[f] += lane[f]; f += 1 }
                        }
                        tc += 1
                    }
                    var f = 0
                    while f < n2 { ms[f] *= monGain; f += 1 }
                }
                bridgePush(storage: mc.pointee.storage,
                           capacityFrames: mc.pointee.capacityFrames,
                           writeIndex: mc.pointee.writeIndex,
                           producedFrames: mc.pointee.producedFrames,
                           src: ms, frames: n)
                mc.pointee.producerCallbacks.pointee = mc.pointee.producerCallbacks.pointee &+ 1
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
    private let tapDescriptions: [CATapDescription]
    /// Bit t set == lane t's direct playback is muted while tapped.
    public private(set) var tapMuteMask: UInt64
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
    private let monScratch: UnsafeMutablePointer<Float>
    private var started = false
    private var tornDown = false

    private init(tapIDs: [AudioObjectID],
                 tapDescriptions: [CATapDescription],
                 tapMuteMask: UInt64,
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
                 mon: UnsafeMutablePointer<Float>,
                 monScratch: UnsafeMutablePointer<Float>) {
        self.tapIDs = tapIDs
        self.tapDescriptions = tapDescriptions
        self.tapMuteMask = tapMuteMask
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
        self.monScratch = monScratch
    }

    // MARK: Build

    public static func build(mode: EngineTapMode,
                             clockDeviceUID: String,
                             monitorSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                             monitorInputsWord: UnsafeMutablePointer<UInt64>,
                             tapMuteMask: UInt64,
                             inputBridges: UnsafeMutablePointer<UnsafeMutablePointer<ConsumerCtx>?>,
                             numInputs: Int,
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
        guard numInputs == params.inputCount,
              monRing.channels >= 2 + 2 * (numTaps + numInputs) else {
            throw OAError("Lane layout mismatch: \(numTaps) tap(s) + \(numInputs) input(s) vs " +
                          "\(params.inputCount) input param lane(s), \(monRing.channels) monitor ch")
        }

        // 2. Create the taps (destroy all created so far on any failure).
        var tapIDs: [AudioObjectID] = []
        var usedDescriptions: [CATapDescription] = []
        func destroyTaps() { for id in tapIDs { AudioHardwareDestroyProcessTap(id) } }
        func createTap(_ description: CATapDescription, _ i: Int) -> AudioObjectID? {
            description.name = "OpenAudio-Engine-Tap-\(i + 1)"
            description.isPrivate = true
            // Lanes heard through the monitor have their direct playback
            // muted (only while our IOProc reads the tap), so the listener
            // hears the mix once instead of original + delayed copy.
            description.muteBehavior = (tapMuteMask >> UInt64(i)) & 1 != 0 ? .mutedWhenTapped : .unmuted
            var tapID: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr, tapID != 0 else {
                OALog.warn("AudioHardwareCreateProcessTap failed for lane \(i + 1): OSStatus \(osStatusString(status)).")
                return nil
            }
            return tapID
        }
        for (i, description) in descriptions.enumerated() {
            var used = description
            var tapID = createTap(description, i)
            if tapID == nil, allowPlaceholderFallback {
                // The app behind this lane likely quit; keep the lane (and the
                // gain-word / meter indexing) alive with a silent placeholder.
                OALog.warn("Lane \(i + 1): falling back to a silent placeholder tap.")
                used = CATapDescription(stereoMixdownOfProcesses: [])
                tapID = createTap(used, i)
            }
            guard let tapID else {
                destroyTaps()
                throw OAError(
                    "AudioHardwareCreateProcessTap failed.\n" +
                    "System audio-capture permission (TCC) may be required for the hosting terminal.")
            }
            tapIDs.append(tapID)
            usedDescriptions.append(used)
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

            // 3. Clock device (aggregate main / clock master).
            let clockDevice = DeviceUtil.device(forUID: clockDeviceUID)
            guard clockDevice != 0 else { throw OAError("Clock device '\(clockDeviceUID)' not found") }
            let outputUID = clockDeviceUID

            // Attenuation compensation from the DEFAULT OUTPUT device's pair
            // count (unchanged basis from the Phase 0 spike; independent of
            // which device clocks the aggregate).
            let outputDevice = DeviceUtil.defaultOutputDevice()
            let outCh = outputDevice != 0
                ? DeviceUtil.channelCount(outputDevice, scope: kAudioObjectPropertyScopeOutput) : 2
            let pairCount = max(1, (outCh + 1) / 2)
            let compGain: Float = pairCount > 1 ? Float(pairCount) : 1.0

            // 5. Build the private aggregate.
            let aggUID = "OpenAudio-Engine-Agg-" + UUID().uuidString
            // Input devices are NOT sub-devices: each runs on its own IOProc
            // and is resampled into this clock (InputSource), so they may have
            // any sample rate and never pull a Bluetooth headset's mic into
            // this aggregate implicitly.
            let subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
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

            // 6. Source buffer layout: the aggregate's input streams are the
            // main sub-device's own input streams (if any) followed by the tap
            // streams in tap-list order, so the taps are the LAST numTaps buffers.
            let layout = DeviceUtil.streamChannelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)
            OALog.info("Aggregate input stream layout (channels per buffer): \(layout)")
            // Taps start right after the clock device's own input streams (the
            // virtual device's loopback). Index from that count — never from
            // the end — so a tap stream missing from the layout can only leave
            // its lane silent, never alias it onto the loopback (= a bus
            // feeding itself back).
            let mainInputStreams = DeviceUtil.streamChannelLayout(clockDevice, scope: kAudioObjectPropertyScopeInput).count
            let firstTapBuf = min(mainInputStreams, layout.count)
            if layout.count != mainInputStreams + numTaps {
                OALog.warn("Aggregate exposes \(layout.count - firstTapBuf) tap stream(s) for \(numTaps) tap(s); missing lanes stay silent.")
            }
            let numSources = numTaps + numInputs
            // The monitor ring's channel count is authoritative for the RT
            // write stride: MonitorRing.write copies `ring.channels` floats per
            // frame. It is sized off the engine's configured source count
            // (numTaps + numInputs); unresolved inputs are silent lanes, so
            // the layouts match. Guard anyway so the RT write never overruns.
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
            let laneCount = max(1, numSources)
            let srcScratch = UnsafeMutablePointer<Float>.allocate(capacity: laneCount * maxFrames * 2)
            srcScratch.initialize(repeating: 0, count: laneCount * maxFrames * 2)
            let busAccum = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            busAccum.initialize(repeating: 0, count: maxFrames * 2)
            let mon = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * monChannels)
            mon.initialize(repeating: 0, count: maxFrames * monChannels)
            let monScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            monScratch.initialize(repeating: 0, count: maxFrames * 2)

            func freeScratch() {
                tapBufIndices.deallocate(); tapChannelsPtr.deallocate()
                srcScratch.deallocate(); busAccum.deallocate(); mon.deallocate()
                monScratch.deallocate()
            }

            let ctxPtr = UnsafeMutablePointer<CaptureCtx>.allocate(capacity: 1)
            ctxPtr.initialize(to: CaptureCtx(
                numTaps: numTaps,
                tapBufIndices: tapBufIndices,
                tapChannels: tapChannelsPtr,
                inputBridges: inputBridges,
                numInputs: numInputs,
                numSources: numSources,
                ioBufferFrames: DeviceUtil.bufferFrameSize(aggregateID),
                compGain: compGain,
                gainWords: params.wordsPointer,
                monitorWord: monitorWord,
                monitorSlot: monitorSlot,
                monScratch: monScratch,
                monitorInputsWord: monitorInputsWord,
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
                tapIDs: tapIDs, tapDescriptions: usedDescriptions, tapMuteMask: tapMuteMask,
                aggregateID: aggregateID, ioProcID: ioProcID,
                format: tapFormats[0], compGain: compGain, selfExcluded: selfExcluded,
                ctxPtr: ctxPtr,
                tapBufIndices: tapBufIndices, tapChannelsPtr: tapChannelsPtr,
                srcScratch: srcScratch, busAccum: busAccum, mon: mon, monScratch: monScratch)
            teardownOwns = true

            do {
                try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
                graph.started = true
            } catch {
                graph.teardown()
                throw error
            }
            let gainDB = 20 * log10(Double(compGain))
            OALog.info(String(format: "Capture graph: clock '%@' @ %.0f Hz, %d tap(s) (native %.0f Hz), %d source(s), comp x%.0f (%+.1f dB)",
                              clockDeviceUID, DeviceUtil.nominalSampleRate(aggregateID),
                              numTaps, tapFormats[0].mSampleRate, numSources, compGain, gainDB))
            return graph
        } catch {
            if !teardownOwns { destroyTaps() }
            throw error
        }
    }

    // MARK: Teardown

    /// Live-update which lanes have their direct playback muted while tapped
    /// (kAudioTapPropertyDescription is settable on an existing tap). Off-RT.
    public func setTapMuteMask(_ mask: UInt64) {
        guard !tornDown, mask != tapMuteMask else { return }
        var addr = CAProperty.address(kAudioTapPropertyDescription)
        for (t, tapID) in tapIDs.enumerated() where t < tapDescriptions.count {
            let want = (mask >> UInt64(t)) & 1 != 0
            let had = (tapMuteMask >> UInt64(t)) & 1 != 0
            guard want != had else { continue }
            var desc = tapDescriptions[t]
            desc.muteBehavior = want ? .mutedWhenTapped : .unmuted
            let st = withUnsafeMutablePointer(to: &desc) { p in
                AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                           UInt32(MemoryLayout<CATapDescription>.size), p)
            }
            if st != noErr {
                OALog.warn("Lane \(t + 1): could not change tap mute behavior: OSStatus \(osStatusString(st))")
            }
        }
        tapMuteMask = mask
    }

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
        monScratch.deallocate()
    }
}
