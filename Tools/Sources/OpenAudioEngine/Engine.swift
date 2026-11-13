// Engine.swift
// Top-level orchestration. Phase 2 generalizes the Phase 1 single stereo bus to
// N buses (F-E1): the capture aggregate (one producer IOProc) fans out through
// a per-source × per-bus routing matrix into up to kOpenAudioMaxBuses buses,
// each a ClockBridge + consumer IOProc on virtual device "OpenAudioDevice-n".
// Buses attach/detach at runtime off the RT thread via an atomic slot array;
// per-source gain/mute/pan stays global per source. Also owns the reliability
// machinery (silence watchdog + default-output rebuild). Public API for the
// CLI: start/stop, live gain/mute/pan/route setters, runtime attach/detach,
// and a consolidated per-bus stats snapshot.

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

public enum EngineSource: Hashable {
    /// One tap lane (0-based). Lane == one tapped app, or lane 0 for the
    /// system-wide tap.
    case tap(Int)
    /// One input-device lane (0-based, in `EngineConfig.inputs` order).
    case input(Int)
}

/// A real input device (microphone / audio interface / Bluetooth headset mic)
/// mixed in as its own source lane. Each input runs on its own IOProc and is
/// resampled into the capture clock, so devices at any sample rate can be
/// combined.
public struct EngineInput {
    /// "default" (the system default input) or a device UID.
    public var deviceUID: String
    /// Display name for stats/meters ("input n" when empty).
    public var name: String
    public var gainDB: Float
    public var pan: Float

    public init(deviceUID: String, name: String = "", gainDB: Float = 0, pan: Float = 0) {
        self.deviceUID = deviceUID
        self.name = name
        self.gainDB = gainDB
        self.pan = pan
    }
}

/// Declarative route: a source enabled onto a set of 0-based bus indices.
public struct EngineRoute {
    public var source: EngineSource
    public var buses: [Int]
    public init(source: EngineSource, buses: [Int]) {
        self.source = source
        self.buses = buses
    }
}

public struct EngineConfig {
    public var tapMode: EngineTapMode
    /// Input-device lanes, mixed after the tap lanes (empty == none).
    public var inputs: [EngineInput] = []
    public var recordURL: URL?
    public var silenceWindow: Double = 10.0

    /// Per-tap-lane display names (used for stats/meters). Padded with
    /// "tap n" when shorter than the lane count.
    public var tapNames: [String] = []
    /// Per-tap-lane initial gains/pans. Missing entries default to 0.
    public var tapGainsDB: [Float] = []
    public var tapPans: [Float] = []

    /// Number of buses to attach at start (1...kOpenAudioMaxBuses).
    public var busCount: Int = 1
    /// Where buses land: their own stereo device each, or channel pairs of
    /// the single 16ch device (DAW-friendly, BlackHole-16ch-style).
    public var outputMode: BusOutputMode = .separateDevices
    /// Initial routing. If empty: every present source -> bus 0 (index 0).
    public var routes: [EngineRoute] = []

    public init(tapMode: EngineTapMode) { self.tapMode = tapMode }
}

public struct BusStats {
    public var index: Int              // 0-based
    public var deviceUID: String
    public var fillFrames: Int
    public var fillPct: Double
    public var ratioPPM: Double
    public var underruns: UInt64
    public var overruns: UInt64
    public var producerCallbacks: UInt64
    public var consumerCallbacks: UInt64
}

public struct EngineStats {
    public var busMixPeakDB: Float     // full (pre-routing) mix meter (max L/R)
    public var busMixRMSDB: Float
    public var sources: [SourceMeter]  // mono (max L/R) summaries, back-compat
    // Per-channel (L/R) meters (F-U4): full pre-routing mix + per source.
    public var busMixStereo: StereoMeter
    public var sourcesStereo: [StereoMeter]
    public var buses: [BusStats]
    public var producedFrames: UInt64
    public var watchdogEvents: UInt64
    public var recordedFrames: UInt64
    public var monitorOverruns: UInt64
}

public final class Engine: @unchecked Sendable {
    private let config: EngineConfig
    private let numTaps: Int
    private let numInputs: Int
    private let numSources: Int

    /// Rate the engine was configured at (monitor meters / recording header).
    private let captureRate: Double
    /// Device that clocks the capture aggregate. OpenAudio's own virtual
    /// device whenever the driver is present, so the mix rate never follows a
    /// Bluetooth headset into its 16/24 kHz hands-free profile; the default
    /// output only as a fallback.
    private var clockUID: String
    private var clockIsDefaultOutput: Bool
    private let clockBufferFrames: Int
    /// Clock-device nominal rate the CURRENT capture graph was built at; a
    /// change triggers a capture rebuild + bridge retune.
    private var graphRate: Double

    private let monitorRing: MonitorRing
    private let monitor: Monitor
    private let params: MixParamsStore

    // Bus fan-out: slot array of atomic pointers (RT-observed) + owning buses.
    private let busSlots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private var buses: [Bus?]
    private let routingWord = Atomic64(0)
    private let captureCycles = Atomic64(0)

    // Monitor selection (F-M1/M2): packed (Int32 busIndex, Float linear-gain).
    // Default off (bus -1). Owned here and passed by pointer to every capture
    // graph so the setting survives watchdog / device-change rebuilds.
    private let monitorWord = Atomic64(packMonitor(bus: -1, gain: 1))
    /// One-entry slot the capture callback reads to feed the monitor output
    /// (nil == not monitoring). The feed itself runs on the real default
    /// output's clock and is re-attached when that device / its rate changes.
    private let monitorSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private var monitorOut: MonitorOutput?
    /// 1 == microphones are also heard in the monitor (default 0: excluded,
    /// so a headset's own mic never echoes / feeds back into that headset).
    private let monitorInputsWord = Atomic64(0)

    private var captureGraph: CaptureGraph?
    /// Input devices, one per input lane, each on its own IOProc + rate bridge
    /// (nil entry == device missing / could not be opened; lane stays silent).
    private var inputSources: [InputSource?]
    /// Consumer contexts handed to every capture graph (numInputs entries,
    /// owned here so they survive capture rebuilds).
    private let inputBridgePtrs: UnsafeMutablePointer<UnsafeMutablePointer<ConsumerCtx>?>

    private let controlQueue = DispatchQueue(label: "com.openaudio.engine.control")
    private var watchdogTimer: DispatchSourceTimer?
    private var lastProduced: UInt64 = 0
    private var stopping = false
    private let watchdogEvents = Atomic64(0)

    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddr = CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice)

    private let maxFrames = 8192
    private let fadeFrames: Int
    private let sourceNames: [String]

    /// Number of tap lanes (one per tapped app; 1 for the system tap).
    public var tapLaneCount: Int { numTaps }
    /// Number of input-device lanes (== config.inputs.count).
    public var inputLaneCount: Int { numInputs }
    /// Per input lane: the HAL device it was opened on (0 == the device was
    /// missing or could not be started; that lane is silent until a restart).
    public let inputLaneDeviceIDs: [AudioObjectID]

    /// Routing-matrix index for a source, or nil if the source is not active.
    private func sourceIndex(_ source: EngineSource) -> Int? {
        switch source {
        case .tap(let i):   return (i >= 0 && i < numTaps) ? i : nil
        case .input(let j): return (j >= 0 && j < numInputs) ? numTaps + j : nil
        }
    }

    public init(config: EngineConfig) throws {
        self.config = config
        switch config.tapMode {
        case .system:               self.numTaps = 1
        case .processes(let lanes): self.numTaps = max(1, lanes.count)
        }
        self.numInputs = config.inputs.count
        self.numSources = numTaps + numInputs

        guard numSources <= kOpenAudioMaxSources else {
            throw OAError("Too many sources: \(numSources) (max \(kOpenAudioMaxSources) apps and inputs combined)")
        }
        guard config.busCount >= 1 && config.busCount <= kOpenAudioMaxBuses else {
            throw OAError("busCount must be 1...\(kOpenAudioMaxBuses), got \(config.busCount)")
        }

        // Capture clock: resolved first so every bridge is sized against it.
        let clock = Self.resolveClock()
        self.clockUID = clock.uid
        self.clockIsDefaultOutput = clock.isDefaultOutput
        let cr = clock.id != 0 ? DeviceUtil.nominalSampleRate(clock.id) : 0
        self.captureRate = cr > 0 ? cr : 48000
        self.graphRate = self.captureRate
        self.clockBufferFrames = clock.id != 0 ? max(64, DeviceUtil.bufferFrameSize(clock.id)) : 512

        // Input devices, each on its own IOProc/clock, resampled into the
        // capture clock. Opening a Bluetooth headset's mic switches that
        // headset to its mono hands-free profile (OS / Bluetooth limit); with
        // the capture clock on the virtual device that only affects what the
        // headset itself plays, never the mix rate.
        var opened: [InputSource?] = []
        for input in config.inputs {
            opened.append(InputSource.start(request: input.deviceUID,
                                            captureRate: captureRate,
                                            captureBufferFrames: clockBufferFrames,
                                            maxFrames: maxFrames))
        }
        self.inputSources = opened
        self.inputLaneDeviceIDs = opened.map { $0?.deviceID ?? 0 }
        self.inputBridgePtrs = .allocate(capacity: max(1, numInputs))
        self.inputBridgePtrs.initialize(repeating: nil, count: max(1, numInputs))
        for (j, src) in opened.enumerated() { inputBridgePtrs[j] = src?.bridge.consumerCtxPointer }

        self.params = MixParamsStore(tapCount: numTaps, inputCount: numInputs)
        self.monitorRing = MonitorRing(channels: 2 + 2 * numSources, capacityFrames: Int(captureRate))
        let taps = numTaps
        let names = config.tapNames
        var sourceNames: [String] = (0..<taps).map { i in
            i < names.count ? names[i] : (taps == 1 ? "tap" : "tap \(i + 1)")
        }
        for (j, input) in config.inputs.enumerated() {
            sourceNames.append(input.name.isEmpty ? (numInputs == 1 ? "input" : "input \(j + 1)") : input.name)
        }
        self.sourceNames = sourceNames
        do {
            self.monitor = try Monitor(ring: monitorRing, sampleRate: captureRate,
                                       sourceNames: sourceNames, recordURL: config.recordURL)
        } catch {
            for src in opened { src?.stop() }
            inputBridgePtrs.deallocate()
            throw error
        }
        self.fadeFrames = max(1, Int(captureRate * 0.010))
        self.monitorSlot = .allocate(capacity: 1)
        self.monitorSlot.initialize(to: nil)

        self.busSlots = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: kOpenAudioMaxBuses)
        self.busSlots.initialize(repeating: nil, count: kOpenAudioMaxBuses)
        self.buses = Array(repeating: nil, count: kOpenAudioMaxBuses)

        // Seed user params.
        for i in 0..<numTaps {
            params.taps[i].gainDB = i < config.tapGainsDB.count ? config.tapGainsDB[i] : 0
            params.taps[i].pan = i < config.tapPans.count ? config.tapPans[i] : 0
        }
        for (j, input) in config.inputs.enumerated() {
            params.inputs[j].gainDB = input.gainDB
            params.inputs[j].pan = input.pan
        }
        params.publish()

        // Seed the routing matrix.
        var mask: UInt64 = 0
        if config.routes.isEmpty {
            for s in 0..<numSources { mask |= routeBit(source: s, bus: 0) }
        } else {
            for route in config.routes {
                guard let s = sourceIndex(route.source) else { continue }   // inactive source
                for bus in route.buses where bus >= 0 && bus < kOpenAudioMaxBuses {
                    mask |= routeBit(source: s, bus: bus)
                }
            }
        }
        routingWord.store(mask)

        OALog.info(String(format: "Engine config: %d source(s), %d bus(es), capture @ %.0f Hz (clock '%@')",
                          numSources, config.busCount, captureRate, clockUID))
        OALog.info("Routing matrix: \(routingDescription())")
    }

    /// The capture clock device: OpenAudio's first virtual device (always
    /// published while the driver is installed; fixed rate, never Bluetooth),
    /// else the default output.
    private static func resolveClock() -> (id: AudioObjectID, uid: String, isDefaultOutput: Bool) {
        let vuid = OpenAudioControl.deviceUID(1)
        let v = DeviceUtil.device(forUID: vuid)
        if v != 0 { return (v, vuid, false) }
        let out = DeviceUtil.defaultOutputDevice()
        OALog.warn("Virtual device '\(vuid)' not found; clocking capture on the default output (its rate changes will change the mix rate).")
        return (out, out != 0 ? DeviceUtil.uid(out) : "", true)
    }

    deinit {
        // Normal paths call stop() first; if not, the capture IOProc (consumer
        // of the input bridges, producer of the monitor feed) must be gone
        // before those are freed.
        captureGraph?.teardown()
        monitorOut?.detach(from: monitorSlot, captureCycles: captureCycles, producerStopped: true)
        stopInputs()
        busSlots.deallocate()
        inputBridgePtrs.deallocate()
        monitorSlot.deallocate()
    }

    /// Tap lanes whose direct playback is muted: those routed to the
    /// monitored bus while monitoring. The listener then hears those sources
    /// once, through the mix, instead of the original plus a delayed copy
    /// (which sounds doubled / louder / phasey). Lanes not on the monitored
    /// bus keep playing directly. Taps are destroyed on stop, which restores
    /// normal playback.
    private func desiredTapMuteMask() -> UInt64 {
        let (bus, _) = unpackMonitor(monitorWord.load())
        // Only while a monitor feed actually runs — never silence the direct
        // playback when the monitor output failed to attach.
        guard bus >= 0, monitorOut != nil else { return 0 }
        let routing = routingWord.load()
        var mask: UInt64 = 0
        for t in 0..<numTaps where (routing & routeBit(source: t, bus: Int(bus))) != 0 {
            mask |= UInt64(1) << UInt64(t)
        }
        return mask
    }

    /// Control queue only.
    private func applyTapMutes() {
        captureGraph?.setTapMuteMask(desiredTapMuteMask())
    }

    /// (Re)attach the monitor feed to the current default output, or drop it
    /// when monitoring is off. Control queue only.
    private func syncMonitorOutput(reason: String? = nil) {
        let (bus, _) = unpackMonitor(monitorWord.load())
        if let m = monitorOut {
            m.detach(from: monitorSlot, captureCycles: captureCycles, producerStopped: captureGraph == nil)
            monitorOut = nil
        }
        guard bus >= 0, !stopping else { applyTapMutes(); return }
        if let reason { OALog.event("Re-attaching monitor output — \(reason)") }
        do {
            let m = try MonitorOutput.attach(captureRate: graphRate,
                                             captureBufferFrames: clockBufferFrames,
                                             maxFrames: maxFrames)
            m.publish(into: monitorSlot)
            monitorOut = m
        } catch {
            OALog.error("Monitor output unavailable: \(error)")
        }
        applyTapMutes()
    }

    /// Stop every input IOProc. Only after the capture graph (the bridges'
    /// consumer) has been torn down. Idempotent.
    private func stopInputs() {
        for j in 0..<inputSources.count {
            inputSources[j]?.stop()
            inputSources[j] = nil
            inputBridgePtrs[j] = nil
        }
    }

    private func buildCaptureGraph() throws -> CaptureGraph {
        try CaptureGraph.build(
            mode: config.tapMode, clockDeviceUID: clockUID, monitorSlot: monitorSlot,
            monitorInputsWord: monitorInputsWord.raw,
            tapMuteMask: desiredTapMuteMask(),
            inputBridges: inputBridgePtrs, numInputs: numInputs,
            busSlots: busSlots, maxBuses: kOpenAudioMaxBuses,
            routingWord: routingWord.raw, captureCycles: captureCycles.raw,
            monRing: monitorRing, params: params, monitorWord: monitorWord.raw,
            maxFrames: maxFrames, fadeFrames: fadeFrames)
    }

    // MARK: Lifecycle

    public func start() throws {
        monitor.start()

        // 1. Attach and publish the requested buses (consumer IOProcs).
        do {
            for i in 0..<config.busCount {
                let bus = try Bus.attach(index: i, captureRate: captureRate,
                                         output: config.outputMode)
                buses[i] = bus
                bus.publish(into: busSlots)
            }
        } catch {
            // Roll back any buses already attached, then the monitor.
            for i in 0..<kOpenAudioMaxBuses {
                buses[i]?.detach(from: busSlots, captureCycles: captureCycles, producerStopped: true)
                buses[i] = nil
            }
            monitor.stop()
            throw error
        }

        // 2. Capture graph (producer). Bridges already consuming (silence until prefill).
        do {
            captureGraph = try buildCaptureGraph()
        } catch {
            stopInputs()
            for i in 0..<kOpenAudioMaxBuses {
                buses[i]?.detach(from: busSlots, captureCycles: captureCycles, producerStopped: true)
                buses[i] = nil
            }
            monitor.stop()
            throw error
        }
        lastProduced = captureCycles.load()

        installDeviceListener()
        installWatchdog()
        OALog.info("Engine started.")
    }

    public func stop() {
        var alreadyStopping = false
        controlQueue.sync {
            if stopping { alreadyStopping = true } else { stopping = true }
        }
        if alreadyStopping { return }   // second stop() is a no-op
        watchdogTimer?.cancel(); watchdogTimer = nil
        removeDeviceListener()

        controlQueue.sync {
            // Stop the producer first: after teardown() returns, no capture
            // callback can observe the slots, so bus detach is immediately safe.
            captureGraph?.teardown()
            captureGraph = nil
            monitorOut?.detach(from: monitorSlot, captureCycles: captureCycles, producerStopped: true)
            monitorOut = nil
            stopInputs()
            for i in 0..<kOpenAudioMaxBuses {
                buses[i]?.detach(from: busSlots, captureCycles: captureCycles, producerStopped: true)
                buses[i] = nil
            }
        }
        monitor.stop()

        let s = stats()
        var under: UInt64 = 0, over: UInt64 = 0
        for b in s.buses { under &+= b.underruns; over &+= b.overruns }
        OALog.info(String(format: "Engine stopped. underruns=%llu overruns=%llu watchdog=%llu recorded=%llu frames",
                          under, over, s.watchdogEvents, s.recordedFrames))
    }

    // MARK: Live parameter setters (off-RT)

    public func setGain(_ source: EngineSource, dB: Float) {
        controlQueue.sync {
            switch source {
            case .tap(let i) where i >= 0 && i < numTaps: params.taps[i].gainDB = dB
            case .input(let j) where j >= 0 && j < numInputs: params.inputs[j].gainDB = dB
            default: return
            }
            params.publish()
        }
    }

    public func setMute(_ source: EngineSource, _ muted: Bool) {
        controlQueue.sync {
            switch source {
            case .tap(let i) where i >= 0 && i < numTaps: params.taps[i].muted = muted
            case .input(let j) where j >= 0 && j < numInputs: params.inputs[j].muted = muted
            default: return
            }
            params.publish()
        }
    }

    public func setPan(_ source: EngineSource, _ pan: Float) {
        controlQueue.sync {
            switch source {
            case .tap(let i) where i >= 0 && i < numTaps: params.taps[i].pan = pan
            case .input(let j) where j >= 0 && j < numInputs: params.inputs[j].pan = pan
            default: return
            }
            params.publish()
        }
    }

    /// Enable/disable a (source, bus) route. bus is 0-based. Off-RT; the RT
    /// callback picks up the new matrix atomically on its next cycle.
    public func setRoute(_ source: EngineSource, bus: Int, on: Bool) throws {
        guard bus >= 0 && bus < kOpenAudioMaxBuses else { throw OAError("bus index out of range: \(bus + 1)") }
        guard let s = sourceIndex(source) else { throw OAError("source is not active: \(source)") }
        controlQueue.sync {
            let bit = routeBit(source: s, bus: bus)
            var m = routingWord.load()
            if on { m |= bit } else { m &= ~bit }
            routingWord.store(m)
            applyTapMutes()
        }
    }

    /// Route a bus's stereo mix to the real default output device for
    /// monitoring (F-M1/M2; fed through MonitorOutput on that device's own
    /// clock), or turn monitoring off. `busIndex` is 0-based;
    /// pass nil (or an out-of-range index) to disable. `gainDB` is applied as a
    /// linear factor on the monitor path only. Off-RT: the capture callback
    /// picks up the new packed snapshot atomically on its next cycle. The
    /// selection is stored on the engine and survives capture rebuilds.
    public func setMonitor(busIndex: Int?, gainDB: Float) {
        controlQueue.sync {
            if let b = busIndex, b >= 0, b < kOpenAudioMaxBuses {
                // Feedback safety: never enable monitoring while the current
                // capture graph's tap lacks self-exclusion (the rare degraded
                // build where our process object was not yet available). Rebuild
                // first — bus consumer IOProcs are running now, so the rebuild
                // resolves our process object and excludes it.
                if let g = captureGraph, !g.selfExcluded, !stopping {
                    OALog.warn("Current tap lacks self-exclusion; rebuilding before enabling monitor (feedback guard).")
                    rebuildCapture(reason: "self-exclusion required for monitoring")
                }
                let gain = powf(10, gainDB / 20)
                monitorWord.store(packMonitor(bus: Int32(b), gain: gain))
                if monitorOut == nil { syncMonitorOutput() }
                applyTapMutes()
                OALog.info(String(format: "Monitor -> bus %d @ %+.1f dB", b + 1, gainDB))
            } else {
                if let b = busIndex {
                    OALog.warn("Monitor bus index out of range (\(b + 1)); monitoring off.")
                }
                monitorWord.store(packMonitor(bus: -1, gain: 1))
                applyTapMutes()
                syncMonitorOutput()
                OALog.info("Monitor off.")
            }
        }
    }

    /// Whether the monitor feed also carries the microphone / input lanes.
    /// Off by default; buses and recordings always include them.
    public func setMonitorIncludesInputs(_ on: Bool) {
        monitorInputsWord.store(on ? 1 : 0)
        OALog.info("Monitor microphones: \(on ? "on" : "off")")
    }

    /// Current monitor selection: (0-based bus index or nil if off, gain dB).
    public func monitorSelection() -> (busIndex: Int?, gainDB: Float) {
        let (bus, gain) = unpackMonitor(monitorWord.load())
        if bus < 0 { return (nil, 0) }
        let db = gain > 0 ? 20 * log10f(gain) : -Float.infinity
        return (Int(bus), db)
    }

    // MARK: Runtime bus attach / detach (off-RT)

    public func attachBus(_ index: Int) throws {
        guard index >= 0 && index < kOpenAudioMaxBuses else { throw OAError("bus index out of range: \(index + 1)") }
        var thrown: Error?
        controlQueue.sync {
            if stopping { thrown = OAError("engine is stopping"); return }
            if buses[index] != nil { thrown = OAError("bus \(index + 1) already attached"); return }
            do {
                let bus = try Bus.attach(index: index, captureRate: graphRate,
                                         output: config.outputMode)
                buses[index] = bus
                bus.publish(into: busSlots)
            } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    public func detachBus(_ index: Int) throws {
        guard index >= 0 && index < kOpenAudioMaxBuses else { throw OAError("bus index out of range: \(index + 1)") }
        var thrown: Error?
        controlQueue.sync {
            guard let bus = buses[index] else { thrown = OAError("bus \(index + 1) is not attached"); return }
            bus.detach(from: busSlots, captureCycles: captureCycles)
            buses[index] = nil
            // Clear any routes pointing at the now-gone bus (harmless if left,
            // but keeps the matrix honest).
            var m = routingWord.load()
            for s in 0..<numSources { m &= ~routeBit(source: s, bus: index) }
            routingWord.store(m)
            applyTapMutes()
        }
        if let thrown { throw thrown }
    }

    // MARK: Introspection

    public func attachedBusIndices() -> [Int] {
        controlQueue.sync { (0..<kOpenAudioMaxBuses).filter { buses[$0] != nil } }
    }

    /// Human-readable matrix, e.g. "tap->1,2 input->1".
    public func routingDescription() -> String {
        let m = routingWord.load()
        let names = sourceNames
        var parts: [String] = []
        for s in 0..<numSources {
            var bs: [Int] = []
            for bus in 0..<kOpenAudioMaxBuses where (m & routeBit(source: s, bus: bus)) != 0 {
                bs.append(bus + 1)
            }
            let list = bs.isEmpty ? "-" : bs.map(String.init).joined(separator: ",")
            parts.append("\(names[s])->\(list)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Stats

    public func stats() -> EngineStats {
        let (bus, srcs) = monitor.stereoMeters()
        // `buses` is mutated on controlQueue (attach/detach); snapshot the bus
        // stats there so this can be called from the stdin / stats-timer
        // threads without racing an Array mutation.
        var busStats: [BusStats] = []
        var produced: UInt64 = 0
        controlQueue.sync {
            for i in 0..<kOpenAudioMaxBuses {
                guard let b = buses[i] else { continue }
                let s = b.bridge.stats()
                produced = max(produced, s.producedFrames)
                busStats.append(BusStats(
                    index: i,
                    deviceUID: b.deviceUID,
                    fillFrames: s.fillFrames,
                    fillPct: s.fillPct,
                    ratioPPM: s.ratioPPM,
                    underruns: s.underruns,
                    overruns: s.overruns,
                    producerCallbacks: s.producerCallbacks,
                    consumerCallbacks: s.consumerCallbacks))
            }
        }
        return EngineStats(
            busMixPeakDB: bus.peakDB,
            busMixRMSDB: bus.rmsDB,
            sources: srcs.map { $0.mono },
            busMixStereo: bus,
            sourcesStereo: srcs,
            buses: busStats,
            producedFrames: produced,
            watchdogEvents: watchdogEvents.load(),
            recordedFrames: monitor.framesRecorded.load(),
            monitorOverruns: monitorRing.overrunCount())
    }

    // MARK: Rebuild (control queue)

    private func rebuildCapture(reason: String) {
        if stopping { return }
        watchdogEvents.add(1)
        OALog.event("Rebuilding capture graph — \(reason)")
        captureGraph?.teardown()
        captureGraph = nil
        // Re-resolve the clock (the driver may have come or gone) and read its
        // rate BEFORE building: the aggregate adopts the main sub-device's
        // current rate, and graphRate must describe this graph.
        let clock = Self.resolveClock()
        clockUID = clock.uid
        clockIsDefaultOutput = clock.isDefaultOutput
        let newRate = clock.id != 0 ? DeviceUtil.nominalSampleRate(clock.id) : 0
        let rateChanged = newRate > 0 && abs(newRate - graphRate) > 0.5
        // Adopt it even if this build fails: the 1 s retry chain below owns
        // recovery, and the watchdog must not start a second chain for the
        // same rate change.
        if newRate > 0 { graphRate = newRate }
        do {
            captureGraph = try buildCaptureGraph()
            lastProduced = captureCycles.load()
            monitor.resetSilenceBaseline()

            // The clock may now run at a different nominal rate; retune every
            // bridge's base ratio so the PI only absorbs ppm-scale residuals,
            // not the whole rate gap (the monitor feed is re-attached).
            if newRate > 0 {
                if rateChanged || monitorOut == nil {
                    syncMonitorOutput(reason: "capture rate now \(Int(newRate)) Hz")
                }
                for src in inputSources { src?.retune(captureRate: newRate) }
                for i in 0..<kOpenAudioMaxBuses {
                    guard let b = buses[i] else { continue }
                    // Re-read the bus device's rate: it may be the clock device
                    // itself (OpenAudioDevice-1), which just changed rate.
                    let dr = DeviceUtil.nominalSampleRate(b.vdevID)
                    let devRate = dr > 0 ? dr : b.deviceRate
                    b.bridge.consumerCtxPointer.pointee.sampleRate = devRate   // PI dt; aligned store
                    let newBase = newRate / devRate
                    if abs(newBase - b.bridge.currentBaseRatio()) > 1e-9 {
                        b.bridge.setBaseRatio(newBase)
                        OALog.event(String(format: "Bus %d: capture rate now %.0f Hz; base ratio retuned to %.6f",
                                           i + 1, newRate, newBase))
                    }
                }
                if config.recordURL != nil && abs(newRate - captureRate) > 0.5 {
                    OALog.warn("Recording continues at the original sample rate header; the new capture rate differs — recorded pitch/duration will be off until restart.")
                }
            }
            OALog.event("Rebuild complete; resuming with fade-in.")
        } catch {
            OALog.error("Rebuild failed: \(error). Retrying in 1 s.")
            controlQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.rebuildCapture(reason: "retry after failed rebuild")
            }
        }
    }

    // MARK: Watchdog

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdogTimer = timer
    }

    private func watchdogTick() {
        if stopping { return }
        // The clock device's rate changed (user retuned the virtual device, or
        // — in the no-driver fallback — the output's Bluetooth profile moved):
        // the aggregate follows it, so rebuild and retune every bridge.
        let clockDev = DeviceUtil.device(forUID: clockUID)
        let curRate = clockDev != 0 ? DeviceUtil.nominalSampleRate(clockDev) : 0
        if curRate > 0 && abs(curRate - graphRate) > 0.5 {
            rebuildCapture(reason: String(format: "clock sample rate changed (%.0f -> %.0f Hz)",
                                          graphRate, curRate))
            return
        }
        // The monitor feed follows the real output: a Bluetooth headset
        // switching between its stereo and hands-free profiles (whenever any
        // app opens / releases its mic) changes only that feed's rate.
        // (Also retries a monitor feed that failed to attach.)
        if unpackMonitor(monitorWord.load()).0 >= 0 {
            let out = DeviceUtil.defaultOutputDevice()
            let outRate = out != 0 ? DeviceUtil.nominalSampleRate(out) : 0
            if let m = monitorOut {
                if out != m.deviceID || (outRate > 0 && abs(outRate - m.deviceRate) > 0.5) {
                    syncMonitorOutput(reason: String(format: "output now %.0f Hz", outRate))
                }
            } else if out != 0 {
                syncMonitorOutput(reason: "retrying monitor output")
            }
        }
        // Inputs can change rate on their own too; keep their ratios honest.
        for src in inputSources { src?.retune(captureRate: graphRate) }
        let produced = captureCycles.load()
        let firing = produced != lastProduced
        lastProduced = produced

        guard monitor.hasSeenAudio() else { return }
        let silent = monitor.secondsSinceLastNonZero()
        if firing && silent >= config.silenceWindow {
            rebuildCapture(reason: String(format:
                "silence watchdog: capture firing but source mix bit-zero for %.1fs (window %.1fs)",
                silent, config.silenceWindow))
        }
    }

    // MARK: Default-output-device change

    private func installDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async { self.defaultOutputChanged() }
        }
        deviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddr, controlQueue, block)
        if status != noErr {
            OALog.warn("Could not register default-output-device listener: OSStatus \(osStatusString(status))")
        }
    }

    /// Only the monitor feed (and, in the no-driver fallback, the clock)
    /// depends on the default output.
    private func defaultOutputChanged() {
        if stopping { return }
        // Tap attenuation compensation is derived from the default output's
        // channel-pair count; rebuild when that changes (or when the output
        // also clocks the capture).
        let out = DeviceUtil.defaultOutputDevice()
        let outCh = out != 0 ? DeviceUtil.channelCount(out, scope: kAudioObjectPropertyScopeOutput) : 2
        let pairs = max(1, (outCh + 1) / 2)
        let comp: Float = pairs > 1 ? Float(pairs) : 1
        if clockIsDefaultOutput || captureGraph == nil || abs((captureGraph?.compGain ?? comp) - comp) > 1e-6 {
            rebuildCapture(reason: "default output device changed")
        }
        if unpackMonitor(monitorWord.load()).0 >= 0 {
            syncMonitorOutput(reason: "default output device changed")
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddr, controlQueue, block)
        deviceListenerBlock = nil
    }
}
