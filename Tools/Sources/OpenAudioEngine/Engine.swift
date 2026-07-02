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

public enum EngineSource {
    case tap
    case input

    public var index: Int {
        switch self {
        case .tap:   return 0
        case .input: return 1
        }
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
    public var inputDeviceUID: String?          // "default", a UID, or nil
    public var recordURL: URL?
    public var silenceWindow: Double = 10.0

    public var tapGainDB: Float = 0
    public var inputGainDB: Float = 0
    public var tapPan: Float = 0
    public var inputPan: Float = 0

    /// Number of buses to attach at start (1...kOpenAudioMaxBuses).
    public var busCount: Int = 1
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
    public var busMixPeakDB: Float     // full (pre-routing) mix meter
    public var busMixRMSDB: Float
    public var sources: [SourceMeter]
    public var buses: [BusStats]
    public var producedFrames: UInt64
    public var watchdogEvents: UInt64
    public var recordedFrames: UInt64
    public var monitorOverruns: UInt64
}

public final class Engine: @unchecked Sendable {
    private let config: EngineConfig
    private let hasInput: Bool
    private let numSources: Int

    private let captureRate: Double

    private let monitorRing: MonitorRing
    private let monitor: Monitor
    private let params = MixParamsStore()

    // Bus fan-out: slot array of atomic pointers (RT-observed) + owning buses.
    private let busSlots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private var buses: [Bus?]
    private let routingWord = Atomic64(0)
    private let captureCycles = Atomic64(0)

    private var captureGraph: CaptureGraph?

    private let controlQueue = DispatchQueue(label: "com.openaudio.engine.control")
    private var watchdogTimer: DispatchSourceTimer?
    private var lastProduced: UInt64 = 0
    private var stopping = false
    private let watchdogEvents = Atomic64(0)

    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddr = CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice)

    private let maxFrames = 8192
    private let fadeFrames: Int

    public init(config: EngineConfig) throws {
        self.config = config
        self.hasInput = config.inputDeviceUID != nil
        self.numSources = hasInput ? 2 : 1

        guard config.busCount >= 1 && config.busCount <= kOpenAudioMaxBuses else {
            throw OAError("busCount must be 1...\(kOpenAudioMaxBuses), got \(config.busCount)")
        }

        // Capture runs at the default output device's rate (aggregate main).
        let outDev = DeviceUtil.defaultOutputDevice()
        let cr = outDev != 0 ? DeviceUtil.nominalSampleRate(outDev) : 0
        self.captureRate = cr > 0 ? cr : 48000

        self.monitorRing = MonitorRing(channels: 2 + 2 * numSources, capacityFrames: Int(captureRate))
        let sourceNames = hasInput ? ["tap", "input"] : ["tap"]
        self.monitor = try Monitor(ring: monitorRing, sampleRate: captureRate,
                                   sourceNames: sourceNames, recordURL: config.recordURL)
        self.fadeFrames = max(1, Int(captureRate * 0.010))

        self.busSlots = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: kOpenAudioMaxBuses)
        self.busSlots.initialize(repeating: nil, count: kOpenAudioMaxBuses)
        self.buses = Array(repeating: nil, count: kOpenAudioMaxBuses)

        // Seed user params.
        params.tap.gainDB = config.tapGainDB
        params.tap.pan = config.tapPan
        params.input.gainDB = config.inputGainDB
        params.input.pan = config.inputPan
        params.publish()

        // Seed the routing matrix.
        var mask: UInt64 = 0
        if config.routes.isEmpty {
            for s in 0..<numSources { mask |= routeBit(source: s, bus: 0) }
        } else {
            for route in config.routes {
                let s = route.source.index
                if s >= numSources { continue }   // input route with no input source
                for bus in route.buses where bus >= 0 && bus < kOpenAudioMaxBuses {
                    mask |= routeBit(source: s, bus: bus)
                }
            }
        }
        routingWord.store(mask)

        OALog.info(String(format: "Engine config: %d source(s), %d bus(es), capture @ %.0f Hz",
                          numSources, config.busCount, captureRate))
        OALog.info("Routing matrix: \(routingDescription())")
    }

    deinit {
        busSlots.deallocate()
    }

    // MARK: Lifecycle

    public func start() throws {
        monitor.start()

        // 1. Attach and publish the requested buses (consumer IOProcs).
        do {
            for i in 0..<config.busCount {
                let bus = try Bus.attach(index: i, captureRate: captureRate)
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
            captureGraph = try CaptureGraph.build(
                mode: config.tapMode, inputDeviceUID: config.inputDeviceUID,
                busSlots: busSlots, maxBuses: kOpenAudioMaxBuses,
                routingWord: routingWord.raw, captureCycles: captureCycles.raw,
                monRing: monitorRing, params: params,
                maxFrames: maxFrames, fadeFrames: fadeFrames)
        } catch {
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
            case .tap:   params.tap.gainDB = dB
            case .input: params.input.gainDB = dB
            }
            params.publish()
        }
    }

    public func setMute(_ source: EngineSource, _ muted: Bool) {
        controlQueue.sync {
            switch source {
            case .tap:   params.tap.muted = muted
            case .input: params.input.muted = muted
            }
            params.publish()
        }
    }

    public func setPan(_ source: EngineSource, _ pan: Float) {
        controlQueue.sync {
            switch source {
            case .tap:   params.tap.pan = pan
            case .input: params.input.pan = pan
            }
            params.publish()
        }
    }

    /// Enable/disable a (source, bus) route. bus is 0-based. Off-RT; the RT
    /// callback picks up the new matrix atomically on its next cycle.
    public func setRoute(_ source: EngineSource, bus: Int, on: Bool) throws {
        guard bus >= 0 && bus < kOpenAudioMaxBuses else { throw OAError("bus index out of range: \(bus + 1)") }
        if source.index >= numSources { throw OAError("source 'input' is not active (no --input given)") }
        controlQueue.sync {
            let bit = routeBit(source: source.index, bus: bus)
            var m = routingWord.load()
            if on { m |= bit } else { m &= ~bit }
            routingWord.store(m)
        }
    }

    // MARK: Runtime bus attach / detach (off-RT)

    public func attachBus(_ index: Int) throws {
        guard index >= 0 && index < kOpenAudioMaxBuses else { throw OAError("bus index out of range: \(index + 1)") }
        var thrown: Error?
        controlQueue.sync {
            if stopping { thrown = OAError("engine is stopping"); return }
            if buses[index] != nil { thrown = OAError("bus \(index + 1) already attached"); return }
            do {
                let bus = try Bus.attach(index: index, captureRate: captureRate)
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
        }
        if let thrown { throw thrown }
    }

    // MARK: Introspection

    public func attachedBusIndices() -> [Int] {
        controlQueue.sync { (0..<kOpenAudioMaxBuses).filter { buses[$0] != nil } }
    }

    /// Human-readable matrix, e.g. "tap->[1,2] input->[1]".
    public func routingDescription() -> String {
        let m = routingWord.load()
        let names = hasInput ? ["tap", "input"] : ["tap"]
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
        let (bus, srcs) = monitor.meters()
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
            sources: srcs,
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
        do {
            captureGraph = try CaptureGraph.build(
                mode: config.tapMode, inputDeviceUID: config.inputDeviceUID,
                busSlots: busSlots, maxBuses: kOpenAudioMaxBuses,
                routingWord: routingWord.raw, captureCycles: captureCycles.raw,
                monRing: monitorRing, params: params,
                maxFrames: maxFrames, fadeFrames: fadeFrames)
            lastProduced = captureCycles.load()
            monitor.resetSilenceBaseline()

            // The new default output device (aggregate clock master) may run at
            // a different nominal rate; retune every bus bridge's base ratio so
            // the PI only absorbs ppm-scale residuals, not the whole rate gap.
            let outDev = DeviceUtil.defaultOutputDevice()
            let newRate = outDev != 0 ? DeviceUtil.nominalSampleRate(outDev) : 0
            if newRate > 0 {
                for i in 0..<kOpenAudioMaxBuses {
                    guard let b = buses[i] else { continue }
                    let newBase = newRate / b.deviceRate
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
            self.controlQueue.async { self.rebuildCapture(reason: "default output device changed") }
        }
        deviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddr, controlQueue, block)
        if status != noErr {
            OALog.warn("Could not register default-output-device listener: OSStatus \(osStatusString(status))")
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddr, controlQueue, block)
        deviceListenerBlock = nil
    }
}
