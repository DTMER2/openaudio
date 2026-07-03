// AppModel.swift
// The @Observable engine controller (docs/plan.md Phase 3). Owns the single
// Engine instance and all *desired* configuration (sources, per-app mix
// params, routing matrix, bus count, monitor selection, recording). Source-set
// changes restart the engine (debounced); everything else is applied live.
//
// Source model: every tapped app is its own engine tap lane (per-app gain /
// pan / mute / routing / meter). UI sources are SourceKind values
// (.system / .app(pid) / .input); the pid -> engine-lane mapping of the
// RUNNING engine is `engineTapPIDs` (lane order), published on each rebuild.
//
// Threading discipline:
//  - `opsEngine` is the authoritative Engine, touched ONLY on `engineOps` (a
//    serial queue). All lifecycle + mutation (start/stop/attach/detach/route/
//    gain/pan/mute/monitor/control-plane) funnels through it, so ordering is
//    guaranteed and nothing that can block runs on main.
//  - `mainEngine` is a main-thread-only mirror used solely to hand a reference
//    to the off-main stats poll. It is written only on main.
//  - @Observable state is mutated only on main.

import SwiftUI
import AppKit
import Observation
import CoreAudio
import OpenAudioEngine

@Observable
final class AppModel {

    // MARK: Engine lifecycle state (read by the UI; mutated on main only)

    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var recordURL: URL?
    private(set) var recordStartDate: Date?
    private(set) var busOpInProgress = false
    /// User-facing error banner (start failure / TCC guidance / bus op failure).
    var lastError: String?
    /// True when the last start failure looked permission-related (F-C2 / TCC).
    var lastErrorIsPermission = false

    // MARK: Desired configuration (drives the next start / restart)

    /// Tap: system-wide capture. Mutually informs `.processes` selection below.
    var useSystemAudio = false {
        didSet {
            guard oldValue != useSystemAudio else { return }
            if useSystemAudio, !routes.contains(where: { $0.source == .system }) {
                routes.insert(RouteKey(source: .system, bus: 0))
            }
            sourcesChanged()
        }
    }
    /// Tap: selected process PIDs (each becomes its own engine lane at start).
    private(set) var selectedPIDs: Set<pid_t> = []
    /// Optional real input lane.
    var inputSelection: InputSelection = .none {
        didSet {
            guard oldValue != inputSelection else { return }
            if inputSelection.isActive, !routes.contains(where: { $0.source == .input }) {
                routes.insert(RouteKey(source: .input, bus: 0))
            }
            sourcesChanged()
        }
    }

    // Per-source live parameters (preserved across restarts because the
    // snapshot reads them fresh each time).
    var systemGainDB: Float = 0
    var systemPan: Float = 0
    var systemMuted = false
    private(set) var appParams: [pid_t: AppLaneParams] = [:]
    var inputGainDB: Float = 0
    var inputPan: Float = 0
    var inputMuted = false

    /// Soloed sources. While non-empty, every non-soloed source is effectively
    /// muted (see `effectiveMuted`). Preserved across restarts like the mutes.
    private(set) var soloed: Set<SourceKind> = []

    /// Routing matrix (0-based bus indices). Preserved across restarts.
    private(set) var routes: Set<RouteKey> = []

    /// Number of attached buses. In `.separateDevices` mode this equals the
    /// driver device count; in `.single16ch` mode it is the number of channel
    /// pairs used on device 1. 1…maxBuses.
    private(set) var busCount = 1

    /// Where buses land: their own stereo virtual device each, or channel
    /// pairs of the single "OpenAudio" device (DAW-friendly).
    private(set) var outputMode: BusOutputMode = .separateDevices

    /// Monitor selection (F-M1): 0-based bus, or nil == off. One bus at a time.
    private(set) var monitorBusIndex: Int?
    var monitorGainDB: Float = 0

    /// Logic-style mixer drawer visibility (toggled with the X key).
    var mixerVisible = false

    // MARK: Live telemetry

    private(set) var stats: EngineStats?
    /// Peak-hold lines (the max-riding "line that stays") per source / bus / mix,
    /// advanced from `updatePeakHolds()` at the poll cadence.
    private(set) var sourceHolds: [SourceKind: PeakHold] = [:]
    private(set) var busHolds: [Int: PeakHold] = [:]
    private(set) var mixHold = PeakHold()
    private(set) var processes: [ProcRow] = []
    private(set) var inputDevices: [(uid: String, name: String)] = []
    /// App icons for the process list / routing nodes / mixer, keyed by pid.
    private(set) var appIcons: [pid_t: NSImage] = [:]

    // MARK: Engine lane mapping (of the currently RUNNING engine; main only)

    /// Lane order of the running engine's tap lanes (empty in system mode).
    private(set) var engineTapPIDs: [pid_t] = []
    private(set) var engineSystemMode = false
    private(set) var engineHasInput = false
    /// HAL process objects each app lane was built with; compared against the
    /// live catalog to rebuild when an app's audio helpers appear/disappear
    /// (e.g. a browser starting playback after being selected).
    private var engineLaneObjs: [pid_t: Set<AudioObjectID>] = [:]

    // MARK: Private machinery

    /// Authoritative engine — engineOps-thread only.
    private var opsEngine: Engine?
    /// Main-thread mirror, used only to hand a reference to the stats poll.
    private var mainEngine: Engine?
    /// True when the engine was started by the Record button from a stopped
    /// state — stopping the recording then also stops the engine.
    private var startedViaRecord = false
    /// Ops-queue-only mirror of the running engine's lane mapping, swapped
    /// atomically with `opsEngine` so live setters can never apply a stale
    /// lane index to a freshly rebuilt engine.
    private var opsTapPIDs: [pid_t] = []
    private var opsSystemMode = false
    private var opsHasInput = false
    /// Sticky display names for selected apps (survives the app quitting).
    private var appDisplayNames: [pid_t: String] = [:]

    private let engineOps = DispatchQueue(label: "com.openaudio.app.engineOps")
    private let statsQueue = DispatchQueue(label: "com.openaudio.app.stats")
    private let procQueue = DispatchQueue(label: "com.openaudio.app.processes")

    private var restartWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var procTimer: Timer?

    // View-visibility gating for polling (avoid needless work while hidden).
    private var windowVisible = false
    private var menuVisible = false

    let maxBuses = kOpenAudioMaxBuses
    /// One engine source slot is reserved for the input lane.
    let maxSelectableApps = kOpenAudioMaxSources - 1

    private static let outputModeKey = "outputMode"
    private static let busPairCountKey = "busPairCount"

    init() {
        // Restore the output mode. In separate-devices mode the driver's
        // device count IS the bus count; in single-16ch mode the driver only
        // publishes device 1, so the pair count is restored from defaults.
        if let raw = UserDefaults.standard.string(forKey: Self.outputModeKey),
           let mode = BusOutputMode(rawValue: raw) {
            outputMode = mode
        }
        if outputMode == .single16ch {
            let pairs = UserDefaults.standard.integer(forKey: Self.busPairCountKey)
            busCount = max(1, min(kOpenAudioMaxBuses, pairs == 0 ? 1 : pairs))
        } else {
            // Adopt whatever the driver currently publishes as the bus count.
            engineOps.async { [weak self] in
                let count = (try? OpenAudioControlPlane.deviceCount()) ?? 1
                DispatchQueue.main.async { self?.busCount = max(1, min(kOpenAudioMaxBuses, count)) }
            }
        }
        refreshProcesses()
    }

    /// Persist the output mode + bus/pair count (the only bus state the driver
    /// itself cannot carry across app launches in single-16ch mode).
    private func persistBusConfig() {
        UserDefaults.standard.set(outputMode.rawValue, forKey: Self.outputModeKey)
        UserDefaults.standard.set(busCount, forKey: Self.busPairCountKey)
    }

    // MARK: - Derived

    /// Whether a tap lane is configured (system or ≥1 process).
    var tapActive: Bool { useSystemAudio || !selectedPIDs.isEmpty }
    var inputActive: Bool { inputSelection.isActive }

    /// Enough is configured to start the engine.
    var canStart: Bool { tapActive || inputActive }

    func isSelected(pid: pid_t) -> Bool { selectedPIDs.contains(pid) }

    var elapsedRecording: TimeInterval {
        guard let s = recordStartDate else { return 0 }
        return Date().timeIntervalSince(s)
    }

    /// The UI-facing mix sources in display/lane order: the system tap OR the
    /// selected apps (sorted by pid, matching engine lane order), then input.
    var mixSources: [SourceKind] {
        var out: [SourceKind] = []
        if useSystemAudio {
            out.append(.system)
        } else {
            out.append(contentsOf: selectedPIDs.sorted().map { SourceKind.app($0) })
        }
        if inputActive { out.append(.input) }
        return out
    }

    func displayName(_ kind: SourceKind) -> String {
        switch kind {
        case .system:
            return "System"
        case .app(let pid):
            return processes.first(where: { $0.pid == pid })?.displayName
                ?? appDisplayNames[pid] ?? "pid \(pid)"
        case .input:
            return inputSelection.label
        }
    }

    func icon(for kind: SourceKind) -> NSImage? {
        if case .app(let pid) = kind { return appIcons[pid] }
        return nil
    }

    // MARK: - Source selection (trigger debounced restart)

    func toggleProcess(pid: pid_t) {
        if selectedPIDs.contains(pid) {
            selectedPIDs.remove(pid)
            routes = routes.filter { $0.source != .app(pid) }
            appParams.removeValue(forKey: pid)
            // A stale solo on a deselected app would silently mute everything.
            soloed.remove(.app(pid))
        } else {
            guard selectedPIDs.count < maxSelectableApps else {
                lastError = "Up to \(maxSelectableApps) apps can be captured at once."
                lastErrorIsPermission = false
                return
            }
            selectedPIDs.insert(pid)
            if let row = processes.first(where: { $0.pid == pid }) {
                appDisplayNames[pid] = row.displayName
            }
            if appParams[pid] == nil { appParams[pid] = AppLaneParams() }
            // New apps land on bus 1 by default so they are audible/routed
            // without a trip to the graph.
            if !routes.contains(where: { $0.source == .app(pid) }) {
                routes.insert(RouteKey(source: .app(pid), bus: 0))
            }
        }
        sourcesChanged()
    }

    /// Source-set change: restart the running engine (debounced) unless we are
    /// recording (source controls are locked while recording to avoid a file
    /// discontinuity / truncation).
    private func sourcesChanged() {
        guard isRunning, !isRecording else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildEngine(recording: false) }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Per-source parameters (applied via the ops queue → opsEngine)

    /// The running engine's source for a UI kind, or nil if that lane is not
    /// part of the current engine (it will be picked up on the next rebuild).
    /// Ops-queue only — resolved against the mapping that was swapped in
    /// together with `opsEngine`.
    private func opsEngineSource(_ kind: SourceKind) -> EngineSource? {
        switch kind {
        case .system:
            return opsSystemMode ? .tap(0) : nil
        case .app(let pid):
            guard !opsSystemMode, let i = opsTapPIDs.firstIndex(of: pid) else { return nil }
            return .tap(i)
        case .input:
            return opsHasInput ? .input : nil
        }
    }

    func gainDB(_ kind: SourceKind) -> Float {
        switch kind {
        case .system:       return systemGainDB
        case .app(let pid): return appParams[pid]?.gainDB ?? 0
        case .input:        return inputGainDB
        }
    }

    func pan(_ kind: SourceKind) -> Float {
        switch kind {
        case .system:       return systemPan
        case .app(let pid): return appParams[pid]?.pan ?? 0
        case .input:        return inputPan
        }
    }

    func isMuted(_ kind: SourceKind) -> Bool {
        switch kind {
        case .system:       return systemMuted
        case .app(let pid): return appParams[pid]?.muted ?? false
        case .input:        return inputMuted
        }
    }

    func setGain(_ kind: SourceKind, _ dB: Float) {
        switch kind {
        case .system:       systemGainDB = dB
        case .app(let pid): appParams[pid, default: AppLaneParams()].gainDB = dB
        case .input:        inputGainDB = dB
        }
        engineOps.async { [weak self] in
            guard let self, let es = self.opsEngineSource(kind) else { return }
            self.opsEngine?.setGain(es, dB: dB)
        }
    }

    func setPan(_ kind: SourceKind, _ pan: Float) {
        switch kind {
        case .system:       systemPan = pan
        case .app(let pid): appParams[pid, default: AppLaneParams()].pan = pan
        case .input:        inputPan = pan
        }
        engineOps.async { [weak self] in
            guard let self, let es = self.opsEngineSource(kind) else { return }
            self.opsEngine?.setPan(es, pan)
        }
    }

    func setMute(_ kind: SourceKind, _ muted: Bool) {
        switch kind {
        case .system:       systemMuted = muted
        case .app(let pid): appParams[pid, default: AppLaneParams()].muted = muted
        case .input:        inputMuted = muted
        }
        applyEffectiveMutes()
    }

    // MARK: Solo

    var anySolo: Bool { !soloed.isEmpty }
    func isSoloed(_ kind: SourceKind) -> Bool { soloed.contains(kind) }

    /// A lane is silenced if it is muted, or if any lane is soloed and this one
    /// is not. Drives both the engine mute and the strip's dimmed appearance.
    func effectiveMuted(_ kind: SourceKind) -> Bool {
        isMuted(kind) || (anySolo && !isSoloed(kind))
    }

    func setSolo(_ kind: SourceKind, _ soloOn: Bool) {
        if soloOn { soloed.insert(kind) } else { soloed.remove(kind) }
        applyEffectiveMutes()
    }

    /// Push the effective mute of every live source to the engine. Called on any
    /// mute/solo change since soloing one lane changes the others' effective mute.
    private func applyEffectiveMutes() {
        for src in mixSources {
            let m = effectiveMuted(src)
            engineOps.async { [weak self] in
                guard let self, let es = self.opsEngineSource(src) else { return }
                self.opsEngine?.setMute(es, m)
            }
        }
    }

    // MARK: - Routing

    func isRouted(_ src: SourceKind, bus: Int) -> Bool { routes.contains(RouteKey(source: src, bus: bus)) }

    func toggleRoute(_ src: SourceKind, bus: Int) {
        let key = RouteKey(source: src, bus: bus)
        let on = !routes.contains(key)
        if on { routes.insert(key) } else { routes.remove(key) }
        // Applied live when the lane is part of the running engine; otherwise
        // the next rebuild picks the route set up from `routes`.
        engineOps.async { [weak self] in
            guard let self, let es = self.opsEngineSource(src) else { return }
            try? self.opsEngine?.setRoute(es, bus: bus, on: on)
        }
    }

    // MARK: - Monitoring (F-M1)

    func toggleMonitor(bus: Int) {
        monitorBusIndex = (monitorBusIndex == bus) ? nil : bus
        applyMonitor()
    }

    /// Direct selection (mixer output strip): nil / out-of-range = off.
    func setMonitorBus(_ bus: Int?) {
        monitorBusIndex = bus.flatMap { $0 >= 0 && $0 < busCount ? $0 : nil }
        applyMonitor()
    }

    func setMonitorGain(_ dB: Float) {
        monitorGainDB = dB
        if monitorBusIndex != nil { applyMonitor() }
    }

    private func applyMonitor() {
        let bus = monitorBusIndex
        let gain = monitorGainDB
        // setMonitor may rebuild the capture graph (self-exclusion guard) — off main.
        engineOps.async { [weak self] in self?.opsEngine?.setMonitor(busIndex: bus, gainDB: gain) }
    }

    // MARK: - Output mode (separate devices vs 16ch pair-packed)

    /// Switch between one-stereo-device-per-bus and BlackHole-16ch-style
    /// pair-packing on device 1. The whole sequence runs as ONE ops-queue
    /// block: whether a restart is needed is decided from the ops-side
    /// `opsEngine` (main's `isRunning` lags in-flight starts/stops), and the
    /// driver's device list is resized on the correct side of the restart so
    /// no live consumer IOProc ever sits on a device being removed.
    func setOutputMode(_ mode: BusOutputMode) {
        guard mode != outputMode, !isRecording, !busOpInProgress else { return }
        let previous = outputMode
        outputMode = mode
        busOpInProgress = true
        let count = busCount
        restartWork?.cancel()
        // Snapshot now (on main) with the new mode; used only if an engine is
        // actually live when the block runs.
        let snap = buildSnapshot(recording: false)
        engineOps.async { [weak self] in
            guard let self else { return }
            if mode == .separateDevices {
                // Grow the device list first; the restarted engine then
                // attaches one device per bus.
                do { _ = try OpenAudioControlPlane.setDeviceCount(count) }
                catch {
                    DispatchQueue.main.async {
                        // Could not enter the mode at all — roll the UI back.
                        self.outputMode = previous
                        self.busOpInProgress = false
                        self.report(error, permission: false)
                    }
                    return
                }
                if self.opsEngine != nil { self.startEngineOnOps(snap, recording: false) }
            } else {
                // Move the engine onto device 1's channel pairs first, then
                // shrink the device list to 1.
                if self.opsEngine != nil { self.startEngineOnOps(snap, recording: false) }
                do { _ = try OpenAudioControlPlane.setDeviceCount(1) }
                catch { DispatchQueue.main.async { self.report(error, permission: false) } }
            }
            DispatchQueue.main.async {
                self.busOpInProgress = false
                self.persistBusConfig()
            }
        }
    }

    // MARK: - Bus add / remove (control plane + engine attach)

    func addBus() {
        guard busCount < maxBuses, !busOpInProgress else { return }
        let target = busCount + 1
        let mode = outputMode
        busOpInProgress = true
        engineOps.async { [weak self] in
            guard let self else { return }
            do {
                // In single-16ch mode all pairs live on device 1 — no need to
                // grow the driver's device list.
                if mode == .separateDevices { _ = try OpenAudioControlPlane.setDeviceCount(target) }
                if let e = self.opsEngine { try e.attachBus(target - 1) }
                DispatchQueue.main.async {
                    self.busCount = target
                    self.busOpInProgress = false
                    self.persistBusConfig()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busOpInProgress = false
                    self.report(error, permission: false)
                }
            }
        }
    }

    /// Remove the last bus (index busCount-1). Callers confirm first if it is routed.
    func removeLastBus() {
        guard busCount > 1, !busOpInProgress else { return }
        let removing = busCount - 1            // 0-based index being removed
        let target = busCount - 1              // new count
        let mode = outputMode
        busOpInProgress = true
        // Drop UI state referencing the removed bus.
        routes = routes.filter { $0.bus != removing }
        if monitorBusIndex == removing { monitorBusIndex = nil }
        engineOps.async { [weak self] in
            guard let self else { return }
            do {
                if let e = self.opsEngine, e.attachedBusIndices().contains(removing) {
                    try e.detachBus(removing)
                }
                if mode == .separateDevices { _ = try OpenAudioControlPlane.setDeviceCount(target) }
                DispatchQueue.main.async {
                    self.busCount = target
                    self.busOpInProgress = false
                    self.persistBusConfig()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busOpInProgress = false
                    self.report(error, permission: false)
                }
            }
        }
    }

    /// True if the last bus carries any route or is being monitored (confirm before removing).
    var lastBusIsInUse: Bool {
        let last = busCount - 1
        return monitorBusIndex == last || routes.contains { $0.bus == last }
    }

    // MARK: - Engine start / stop / record

    /// Start-engine button (routing + monitoring, no file).
    func toggleEngine() {
        if isRunning { stopEngine() }
        else { startedViaRecord = false; rebuildEngine(recording: false) }
    }

    /// One-click Record button (F-U2): starts the engine + recorder if needed.
    func toggleRecord() {
        if isRecording {
            if startedViaRecord { stopEngine() }
            else { rebuildEngine(recording: false) }   // keep engine for monitoring
        } else if isRunning {
            rebuildEngine(recording: true)             // add recorder to a live engine
        } else {
            startedViaRecord = true
            rebuildEngine(recording: true)
        }
    }

    func stopEngine() {
        restartWork?.cancel()
        engineOps.async { [weak self] in
            self?.opsEngine?.stop()
            self?.opsEngine = nil
            self?.setOpsLaneMapping(tapPIDs: [], systemMode: false, hasInput: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mainEngine = nil
                self.isRunning = false
                self.isRecording = false
                self.recordURL = nil
                self.recordStartDate = nil
                self.clearLaneMapping()
            }
        }
    }

    private func clearLaneMapping() {
        engineTapPIDs = []
        engineLaneObjs = [:]
        engineSystemMode = false
        engineHasInput = false
    }

    /// Ops-queue only: swap the lane mapping together with `opsEngine`.
    private func setOpsLaneMapping(tapPIDs: [pid_t], systemMode: Bool, hasInput: Bool) {
        opsTapPIDs = tapPIDs
        opsSystemMode = systemMode
        opsHasInput = hasInput
    }

    /// Build a fresh engine from current desired state and start it. Replaces any
    /// running engine (source-change restart or record add/remove). The
    /// authoritative teardown target is `opsEngine`, read/written only here on
    /// the ops queue, so back-to-back rebuilds can never leak an engine.
    private func rebuildEngine(recording: Bool) {
        // A pending debounced source-change rebuild would fire after us with
        // recording=false and silently kill a recording just started.
        restartWork?.cancel()
        guard canStart else {
            report(OAError("Select at least one source (System audio, a process, or an input) before starting."),
                   permission: false)
            return
        }

        // Snapshot ALL desired state on main into a value (no shared mutable
        // fields, no cross-thread @Observable reads).
        let snap = buildSnapshot(recording: recording)

        engineOps.async { [weak self] in
            self?.startEngineOnOps(snap, recording: recording)
        }
    }

    /// Ops-queue only: tear down any running engine and start a fresh one from
    /// the snapshot. Shared by rebuildEngine and setOutputMode so both use the
    /// ops-side (authoritative) engine state, never the possibly stale
    /// main-side `isRunning`.
    private func startEngineOnOps(_ snap: Snapshot, recording: Bool) {
        // Tear down whatever is currently running before starting anew.
        opsEngine?.stop()
        opsEngine = nil

        if let url = snap.recordURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        do {
            let e = try Engine(config: snap.config)
            try e.start()
            // Apply state the config does not carry: mutes + monitor.
            for (source, muted) in snap.mutes where muted { e.setMute(source, true) }
            if let b = snap.monitorBus { e.setMonitor(busIndex: b, gainDB: snap.monitorGain) }
            opsEngine = e
            setOpsLaneMapping(tapPIDs: snap.tapPIDs, systemMode: snap.systemMode,
                              hasInput: snap.hasInput)
            DispatchQueue.main.async {
                self.mainEngine = e
                self.isRunning = true
                self.isRecording = recording
                self.recordURL = recording ? snap.recordURL : nil
                self.recordStartDate = recording ? Date() : nil
                self.engineTapPIDs = snap.tapPIDs
                self.engineLaneObjs = snap.tapLaneObjs
                self.engineSystemMode = snap.systemMode
                self.engineHasInput = snap.hasInput
                self.lastError = nil
                self.lastErrorIsPermission = false
            }
        } catch {
            opsEngine = nil
            setOpsLaneMapping(tapPIDs: [], systemMode: false, hasInput: false)
            DispatchQueue.main.async {
                self.mainEngine = nil
                self.isRunning = false
                self.isRecording = false
                self.recordStartDate = nil
                self.clearLaneMapping()
                self.report(error, permission: Self.looksLikePermission(error))
            }
        }
    }

    /// Immutable value carrying everything a rebuild needs off-main.
    private struct Snapshot {
        var config: EngineConfig
        var recordURL: URL?
        var mutes: [(EngineSource, Bool)]
        var monitorBus: Int?
        var monitorGain: Float
        var tapPIDs: [pid_t]      // engine lane order ([] in system mode)
        /// HAL process objects captured per app lane at snapshot time, used to
        /// detect helper processes appearing/disappearing (rebuild trigger).
        var tapLaneObjs: [pid_t: Set<AudioObjectID>]
        var systemMode: Bool
        var hasInput: Bool
    }

    /// Construct the engine snapshot from desired state (called on main).
    private func buildSnapshot(recording: Bool) -> Snapshot {
        var tapPIDs: [pid_t] = []
        var tapLaneObjs: [pid_t: Set<AudioObjectID>] = [:]
        var tapNames: [String] = []
        var tapGains: [Float] = []
        var tapPans: [Float] = []
        var mutes: [(EngineSource, Bool)] = []
        let systemMode = useSystemAudio

        // Resolve tap lanes: the system tap, or one lane per selected app
        // (sorted by pid — the same order engineSource()/sourceMeter() use).
        let tapMode: EngineTapMode
        if systemMode {
            tapMode = .system
            tapNames = ["System"]
            tapGains = [systemGainDB]
            tapPans = [systemPan]
            mutes.append((.tap(0), effectiveMuted(.system)))
        } else {
            // One lane per selected app = ALL process objects responsible-PID
            // grouped under it (browsers emit audio from helper processes). An
            // app with no audio objects yet keeps a silent placeholder lane;
            // refreshProcesses() triggers a rebuild when its objects appear.
            var lanes: [[AudioObjectID]] = []
            let groups = (try? AudioProcessCatalog.audioObjectsByResponsiblePID()) ?? [:]
            let ownPid = getpid()
            for pid in selectedPIDs.sorted() where pid != ownPid {
                let objs = groups[pid]
                    ?? (try? AudioProcessCatalog.processObject(forPID: pid)).map { [$0] }
                    ?? []
                lanes.append(objs)
                tapLaneObjs[pid] = Set(objs)
                tapPIDs.append(pid)
                let p = appParams[pid] ?? AppLaneParams()
                tapNames.append(displayName(.app(pid)))
                tapGains.append(p.gainDB)
                tapPans.append(p.pan)
                mutes.append((.tap(tapPIDs.count - 1), effectiveMuted(.app(pid))))
            }
            tapMode = .processes(lanes)  // empty => silent placeholder lane (input-only)
        }

        var cfg = EngineConfig(tapMode: tapMode)
        cfg.inputDeviceUID = inputSelection.configUID
        cfg.busCount = busCount
        cfg.outputMode = outputMode
        cfg.tapNames = tapNames
        cfg.tapGainsDB = tapGains
        cfg.tapPans = tapPans
        cfg.inputGainDB = inputGainDB
        cfg.inputPan = inputPan
        if inputSelection.isActive { mutes.append((.input, effectiveMuted(.input))) }

        // Routing: map UI source kinds onto engine lanes; drop routes past
        // busCount and routes whose lane is not part of this engine.
        var laneBuses: [EngineSource: [Int]] = [:]
        for r in routes where r.bus < busCount {
            let es: EngineSource?
            switch r.source {
            case .system:       es = systemMode ? .tap(0) : nil
            case .app(let pid): es = systemMode ? nil : tapPIDs.firstIndex(of: pid).map { .tap($0) }
            case .input:        es = inputSelection.isActive ? .input : nil
            }
            if let es { laneBuses[es, default: []].append(r.bus) }
        }
        cfg.routes = laneBuses.map { EngineRoute(source: $0.key, buses: $0.value.sorted()) }
        // An engine with no route at all would seed "everything -> bus 1";
        // avoid that implicit default by keeping the explicit empty matrix.
        if cfg.routes.isEmpty {
            cfg.routes = [EngineRoute(source: .tap(0), buses: [])]
        }

        let recURL: URL? = recording ? Self.newRecordingURL() : nil
        cfg.recordURL = recURL

        let monBus: Int? = monitorBusIndex.flatMap { $0 < busCount ? $0 : nil }
        return Snapshot(config: cfg, recordURL: recURL, mutes: mutes,
                        monitorBus: monBus, monitorGain: monitorGainDB,
                        tapPIDs: tapPIDs, tapLaneObjs: tapLaneObjs,
                        systemMode: systemMode,
                        hasInput: inputSelection.isActive)
    }

    /// ~/Documents/OpenAudio Recordings — where every recording is written.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAudio Recordings", isDirectory: true)
    }

    /// ~/Documents/OpenAudio Recordings/OpenAudio-<timestamp>.caf
    static func newRecordingURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return recordingsDirectory.appendingPathComponent("OpenAudio-\(f.string(from: Date())).caf")
    }

    /// Reveal recordings in Finder: select the current/most recent file if it
    /// exists, otherwise open the folder (creating it if needed).
    func revealRecordings() {
        if let url = recordURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let dir = Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Error reporting

    private func report(_ error: Error, permission: Bool) {
        let msg = (error as? OAError)?.description ?? "\(error)"
        lastError = msg
        lastErrorIsPermission = permission
    }

    private static func looksLikePermission(_ error: Error) -> Bool {
        let s = ((error as? OAError)?.description ?? "\(error)").lowercased()
        // CoreAudio surfaces TCC / tap-creation denials variously. Match the
        // specific markers only — a bare "tap"/"aggregate" also appears in
        // non-permission failures (e.g. the feedback guard) and must not
        // render as the TCC banner.
        return s.contains("permission") || s.contains("not permitted")
            || s.contains("privacy") || s.contains("tcc")
            || s.contains("!obj") || s.contains("2003332927")
            || s.contains("createprocesstap")
    }

    // MARK: - Process list + input devices (F-U3)

    func refreshProcesses() {
        procQueue.async { [weak self] in
            let infos = (try? AudioProcessCatalog.listAudioProcesses()) ?? []
            let ownPid = getpid()
            let ownBundleID = Bundle.main.bundleIdentifier
            // One row per APP: helper processes (browser audio services, WebKit
            // GPU, ...) are grouped under their responsible PID. Our own process
            // is never listed (tapping it is a feedback loop; the engine refuses).
            var members: [pid_t: [AudioProcessInfo]] = [:]
            var order: [pid_t] = []
            for info in infos where info.pid > 0 && info.pid != ownPid {
                let leader = AudioProcessCatalog.responsiblePID(for: info.pid)
                guard leader != ownPid else { continue }
                if members[leader] == nil { order.append(leader) }
                members[leader, default: []].append(info)
            }
            var rows: [ProcRow] = []
            var icons: [pid_t: NSImage] = [:]
            var laneObjs: [pid_t: Set<AudioObjectID>] = [:]
            for leader in order {
                let group = members[leader]!
                laneObjs[leader] = Set(group.map(\.objectID))
                var isUserApp = false
                var name = group[0].name
                var bundleID = group[0].bundleID
                if let app = NSRunningApplication(processIdentifier: leader) {
                    isUserApp = app.activationPolicy == .regular
                    if let n = app.localizedName ?? app.bundleIdentifier { name = n }
                    if let bid = app.bundleIdentifier { bundleID = bid }
                    if let icon = app.icon { icons[leader] = icon }
                }
                if icons[leader] == nil, let bid = bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    icons[leader] = NSWorkspace.shared.icon(forFile: url.path)
                }
                // Never list ourselves: while monitoring, OpenAudio's own output
                // can surface under a responsible PID that isn't our raw getpid().
                if let bid = bundleID, bid == ownBundleID {
                    laneObjs[leader] = nil
                    continue
                }
                rows.append(ProcRow(pid: leader, objectID: group[0].objectID, name: name,
                                    bundleID: bundleID,
                                    isRunningOutput: group.contains { $0.isRunningOutput },
                                    isUserApp: isUserApp))
            }
            // Playing first, then user-facing apps, then daemons; alphabetical
            // within each group.
            rows.sort { a, b in
                if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
                if a.isUserApp != b.isUserApp { return a.isUserApp }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            let devs = DeviceUtil.allDevices()
                .filter { $0.inChannels > 0 && !$0.uid.hasPrefix("OpenAudioDevice-") }
                .map { (uid: $0.uid, name: $0.name) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes = rows
                self.appIcons = icons
                self.inputDevices = devs
                self.rebuildIfLaneObjectsChanged(laneObjs)
            }
        }
    }

    /// Rebuild the running engine (debounced) when a selected app's set of HAL
    /// process objects changed since the engine was built — e.g. a browser
    /// spawned its audio helper after being selected, so the current tap
    /// misses it (a placeholder or stale lane is capturing silence).
    private func rebuildIfLaneObjectsChanged(_ current: [pid_t: Set<AudioObjectID>]) {
        guard isRunning, !isRecording, !engineSystemMode, !engineTapPIDs.isEmpty else { return }
        for pid in engineTapPIDs where (current[pid] ?? []) != (engineLaneObjs[pid] ?? []) {
            sourcesChanged()
            return
        }
    }

    // MARK: - Polling gating

    func setWindowVisible(_ v: Bool) { windowVisible = v; reconcilePolling() }
    func setMenuVisible(_ v: Bool)   { menuVisible = v;   reconcilePolling() }

    private var shouldPoll: Bool { windowVisible || menuVisible }

    private func reconcilePolling() {
        if shouldPoll {
            if meterTimer == nil {
                // .common mode so meters keep updating while a fader / pan slider
                // is being dragged (drags run the loop in event-tracking mode,
                // where a .default-mode timer would stall).
                let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                    self?.pollStats()
                }
                t.tolerance = 0.02
                RunLoop.main.add(t, forMode: .common)
                meterTimer = t
            }
            if procTimer == nil {
                let p = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    self?.refreshProcesses()
                }
                procTimer = p
                refreshProcesses()
            }
        } else {
            meterTimer?.invalidate(); meterTimer = nil
            procTimer?.invalidate(); procTimer = nil
        }
    }

    private func pollStats() {
        // engine.stats() takes the engine's control queue briefly; keep it off
        // main. `mainEngine` is main-only; capture a strong ref for the poll.
        guard let e = mainEngine else {
            if stats != nil { stats = nil }
            return
        }
        statsQueue.async { [weak self] in
            let s = e.stats()
            DispatchQueue.main.async {
                self?.stats = s
                self?.updatePeakHolds()
            }
        }
    }

    // MARK: - Meter helpers for the UI

    /// Per-source stereo meter (nil until stats arrive / lane absent from the
    /// running engine). Engine meter order == tap lanes, then input.
    func sourceMeter(_ kind: SourceKind) -> StereoMeter? {
        guard let s = stats else { return nil }
        switch kind {
        case .system:
            return engineSystemMode ? s.sourcesStereo.first : nil
        case .app(let pid):
            guard !engineSystemMode,
                  let i = engineTapPIDs.firstIndex(of: pid),
                  i < s.sourcesStereo.count else { return nil }
            return s.sourcesStereo[i]
        case .input:
            guard engineHasInput else { return nil }
            return s.sourcesStereo.last
        }
    }

    /// The overall (pre-routing) mix meter — used as the master output indicator.
    var mixMeter: StereoMeter? { stats?.busMixStereo }

    /// Per-bus stereo level, aggregated as the max L / max R across the sources
    /// routed to it (the engine exposes only a global mix meter post-routing).
    func busStereo(_ bus: Int) -> (l: Float, r: Float) {
        guard stats != nil else { return (-.infinity, -.infinity) }
        var l = -Float.infinity, r = -Float.infinity
        for route in routes where route.bus == bus {
            if let m = sourceMeter(route.source) { l = max(l, m.peakL); r = max(r, m.peakR) }
        }
        return (l, r)
    }

    // MARK: - Peak-hold lines

    /// Plateau length and fall rate for the peak-hold line, tuned for the 12 Hz
    /// poll: hold ~0.5 s at a new maximum, then fall ~18 dB/s.
    private static let holdFrames = 6
    private static let holdDecayDB: Float = 1.5

    func sourceHold(_ kind: SourceKind) -> PeakHold { sourceHolds[kind] ?? PeakHold() }
    func busHold(_ bus: Int) -> PeakHold { busHolds[bus] ?? PeakHold() }

    /// Advance one channel of a hold: jump up to any new maximum (re-arming the
    /// plateau), otherwise hold for a beat then decay toward the current level.
    private static func stepHold(_ prev: Float, _ incoming: Float, _ ticks: inout Int) -> Float {
        if incoming.isFinite, !prev.isFinite || incoming >= prev {
            ticks = holdFrames
            return incoming
        }
        guard prev.isFinite else { return -.infinity }
        if ticks > 0 { ticks -= 1; return prev }
        let floor = incoming.isFinite ? incoming : Meter.minDB
        let next = max(prev - holdDecayDB, floor)
        return next <= Meter.minDB ? -.infinity : next
    }

    private static func advance(_ hold: PeakHold, _ l: Float, _ r: Float) -> PeakHold {
        var h = hold
        h.l = stepHold(h.l, l, &h.lTicks)
        h.r = stepHold(h.r, r, &h.rTicks)
        return h
    }

    /// Re-advance every hold line from the latest `stats`. Called on main right
    /// after `stats` is published so the lines decay even during silence.
    private func updatePeakHolds() {
        guard stats != nil else {
            if !sourceHolds.isEmpty { sourceHolds = [:] }
            if !busHolds.isEmpty { busHolds = [:] }
            if mixHold != PeakHold() { mixHold = PeakHold() }
            return
        }
        var srcHolds: [SourceKind: PeakHold] = [:]
        for src in mixSources {
            let m = sourceMeter(src)
            srcHolds[src] = Self.advance(sourceHolds[src] ?? PeakHold(),
                                         m?.peakL ?? -.infinity, m?.peakR ?? -.infinity)
        }
        sourceHolds = srcHolds

        var bHolds: [Int: PeakHold] = [:]
        for b in 0..<busCount {
            let s = busStereo(b)
            bHolds[b] = Self.advance(busHolds[b] ?? PeakHold(), s.l, s.r)
        }
        busHolds = bHolds

        let m = mixMeter
        mixHold = Self.advance(mixHold, m?.peakL ?? -.infinity, m?.peakR ?? -.infinity)
    }
}
