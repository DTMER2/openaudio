// AppModel.swift
// The @Observable engine controller (docs/plan.md Phase 3). Owns the single
// Engine instance and all *desired* configuration (sources, gains/pans/mutes,
// routing matrix, bus count, monitor selection, recording). Source-set changes
// restart the engine (debounced); everything else is applied live.
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
    var useSystemAudio = false { didSet { if oldValue != useSystemAudio { sourcesChanged() } } }
    /// Tap: selected process PIDs (resolved to CoreAudio objects at start).
    private(set) var selectedPIDs: Set<pid_t> = []
    /// Optional real input lane.
    var inputSelection: InputSelection = .none { didSet { if oldValue != inputSelection { sourcesChanged() } } }

    // Per-source live parameters (preserved across restarts because the snapshot
    // reads them fresh each time).
    var tapGainDB: Float = 0
    var tapPan: Float = 0
    var tapMuted = false
    var inputGainDB: Float = 0
    var inputPan: Float = 0
    var inputMuted = false

    /// Routing matrix (0-based bus indices). Preserved across restarts.
    private(set) var routes: Set<RouteKey> = [RouteKey(source: .tap, bus: 0)]

    /// Number of attached buses == driver device count. 1…maxBuses.
    private(set) var busCount = 1

    /// Monitor selection (F-M1): 0-based bus, or nil == off. One bus at a time.
    private(set) var monitorBusIndex: Int?
    var monitorGainDB: Float = 0

    // MARK: Live telemetry

    private(set) var stats: EngineStats?
    private(set) var processes: [ProcRow] = []
    private(set) var inputDevices: [(uid: String, name: String)] = []

    // MARK: Private machinery

    /// Authoritative engine — engineOps-thread only.
    private var opsEngine: Engine?
    /// Main-thread mirror, used only to hand a reference to the stats poll.
    private var mainEngine: Engine?
    /// True when the engine was started by the Record button from a stopped
    /// state — stopping the recording then also stops the engine.
    private var startedViaRecord = false

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

    init() {
        // Adopt whatever the driver currently publishes as the initial bus count.
        engineOps.async { [weak self] in
            let count = (try? OpenAudioControlPlane.deviceCount()) ?? 1
            DispatchQueue.main.async { self?.busCount = max(1, min(kOpenAudioMaxBuses, count)) }
        }
        refreshProcesses()
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

    // MARK: - Source selection (trigger debounced restart)

    func toggleProcess(pid: pid_t) {
        if selectedPIDs.contains(pid) { selectedPIDs.remove(pid) } else { selectedPIDs.insert(pid) }
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

    // MARK: - Live parameter setters (applied via the ops queue → opsEngine)

    private func engineSource(_ src: SourceKind) -> EngineSource { src == .tap ? .tap : .input }

    func setGain(_ src: SourceKind, _ dB: Float) {
        switch src {
        case .tap:   tapGainDB = dB
        case .input: inputGainDB = dB
        }
        let es = engineSource(src)
        engineOps.async { [weak self] in self?.opsEngine?.setGain(es, dB: dB) }
    }

    func setPan(_ src: SourceKind, _ pan: Float) {
        switch src {
        case .tap:   tapPan = pan
        case .input: inputPan = pan
        }
        let es = engineSource(src)
        engineOps.async { [weak self] in self?.opsEngine?.setPan(es, pan) }
    }

    func setMute(_ src: SourceKind, _ muted: Bool) {
        switch src {
        case .tap:   tapMuted = muted
        case .input: inputMuted = muted
        }
        let es = engineSource(src)
        engineOps.async { [weak self] in self?.opsEngine?.setMute(es, muted) }
    }

    // MARK: - Routing

    func isRouted(_ src: SourceKind, bus: Int) -> Bool { routes.contains(RouteKey(source: src, bus: bus)) }

    func toggleRoute(_ src: SourceKind, bus: Int) {
        let key = RouteKey(source: src, bus: bus)
        let on = !routes.contains(key)
        if on { routes.insert(key) } else { routes.remove(key) }
        let es = engineSource(src)
        // Applied live; the engine restarts only on source changes, not routing.
        engineOps.async { [weak self] in try? self?.opsEngine?.setRoute(es, bus: bus, on: on) }
    }

    // MARK: - Monitoring (F-M1)

    func toggleMonitor(bus: Int) {
        monitorBusIndex = (monitorBusIndex == bus) ? nil : bus
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

    // MARK: - Bus add / remove (control plane + engine attach)

    func addBus() {
        guard busCount < maxBuses, !busOpInProgress else { return }
        let target = busCount + 1
        busOpInProgress = true
        engineOps.async { [weak self] in
            guard let self else { return }
            do {
                _ = try OpenAudioControlPlane.setDeviceCount(target)
                if let e = self.opsEngine { try e.attachBus(target - 1) }
                DispatchQueue.main.async {
                    self.busCount = target
                    self.busOpInProgress = false
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
                _ = try OpenAudioControlPlane.setDeviceCount(target)
                DispatchQueue.main.async {
                    self.busCount = target
                    self.busOpInProgress = false
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.mainEngine = nil
                self.isRunning = false
                self.isRecording = false
                self.recordURL = nil
                self.recordStartDate = nil
            }
        }
    }

    /// Build a fresh engine from current desired state and start it. Replaces any
    /// running engine (source-change restart or record add/remove). The
    /// authoritative teardown target is `opsEngine`, read/written only here on
    /// the ops queue, so back-to-back rebuilds can never leak an engine.
    private func rebuildEngine(recording: Bool) {
        guard canStart else {
            report(OAError("Select at least one source (System audio, a process, or an input) before starting."),
                   permission: false)
            return
        }

        // Snapshot ALL desired state on main into a value (no shared mutable
        // fields, no cross-thread @Observable reads).
        let snap = buildSnapshot(recording: recording)

        engineOps.async { [weak self] in
            guard let self else { return }
            // Tear down whatever is currently running before starting anew.
            self.opsEngine?.stop()
            self.opsEngine = nil

            if let url = snap.recordURL {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            do {
                let e = try Engine(config: snap.config)
                try e.start()
                // Apply state the config does not carry: mutes + monitor.
                e.setMute(.tap, snap.muteTap)
                if snap.hasInput { e.setMute(.input, snap.muteInput) }
                if let b = snap.monitorBus { e.setMonitor(busIndex: b, gainDB: snap.monitorGain) }
                self.opsEngine = e
                DispatchQueue.main.async {
                    self.mainEngine = e
                    self.isRunning = true
                    self.isRecording = recording
                    self.recordURL = recording ? snap.recordURL : nil
                    self.recordStartDate = recording ? Date() : nil
                    self.lastError = nil
                    self.lastErrorIsPermission = false
                }
            } catch {
                self.opsEngine = nil
                DispatchQueue.main.async {
                    self.mainEngine = nil
                    self.isRunning = false
                    self.isRecording = false
                    self.recordStartDate = nil
                    self.report(error, permission: Self.looksLikePermission(error))
                }
            }
        }
    }

    /// Immutable value carrying everything a rebuild needs off-main.
    private struct Snapshot {
        var config: EngineConfig
        var recordURL: URL?
        var muteTap: Bool
        var muteInput: Bool
        var hasInput: Bool
        var monitorBus: Int?
        var monitorGain: Float
    }

    /// Construct the engine snapshot from desired state (called on main).
    private func buildSnapshot(recording: Bool) -> Snapshot {
        // Resolve tap mode.
        let tapMode: EngineTapMode
        if useSystemAudio {
            tapMode = .system
        } else if !selectedPIDs.isEmpty {
            var objs: [AudioObjectID] = []
            for pid in selectedPIDs.sorted() {
                if let obj = try? AudioProcessCatalog.processObject(forPID: pid) { objs.append(obj) }
            }
            tapMode = .processes(objs)
        } else {
            tapMode = .processes([])   // input-only: tap nothing
        }

        var cfg = EngineConfig(tapMode: tapMode)
        cfg.inputDeviceUID = inputSelection.configUID
        cfg.busCount = busCount
        cfg.tapGainDB = tapGainDB
        cfg.tapPan = tapPan
        cfg.inputGainDB = inputGainDB
        cfg.inputPan = inputPan

        // Routing (group by source; drop routes past busCount).
        var tapBuses: [Int] = [], inputBuses: [Int] = []
        for r in routes where r.bus < busCount {
            if r.source == .tap { tapBuses.append(r.bus) } else { inputBuses.append(r.bus) }
        }
        var rlist: [EngineRoute] = []
        if !tapBuses.isEmpty { rlist.append(EngineRoute(source: .tap, buses: tapBuses.sorted())) }
        if inputSelection.isActive && !inputBuses.isEmpty {
            rlist.append(EngineRoute(source: .input, buses: inputBuses.sorted()))
        }
        cfg.routes = rlist

        let recURL: URL? = recording ? Self.newRecordingURL() : nil
        cfg.recordURL = recURL

        let monBus: Int? = monitorBusIndex.flatMap { $0 < busCount ? $0 : nil }
        return Snapshot(config: cfg, recordURL: recURL,
                        muteTap: tapMuted, muteInput: inputMuted,
                        hasInput: inputSelection.isActive,
                        monitorBus: monBus, monitorGain: monitorGainDB)
    }

    /// ~/Documents/OpenAudio Recordings/OpenAudio-<timestamp>.caf
    static func newRecordingURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAudio Recordings", isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return dir.appendingPathComponent("OpenAudio-\(f.string(from: Date())).caf")
    }

    // MARK: - Error reporting

    private func report(_ error: Error, permission: Bool) {
        let msg = (error as? OAError)?.description ?? "\(error)"
        lastError = msg
        lastErrorIsPermission = permission
    }

    private static func looksLikePermission(_ error: Error) -> Bool {
        let s = ((error as? OAError)?.description ?? "\(error)").lowercased()
        // CoreAudio surfaces TCC / tap-creation denials variously; match broadly.
        return s.contains("permission") || s.contains("not permitted")
            || s.contains("privacy") || s.contains("tap")
            || s.contains("!obj") || s.contains("2003332927")
            || s.contains("createprocesstap") || s.contains("aggregate")
    }

    // MARK: - Process list + input devices (F-U3)

    func refreshProcesses() {
        procQueue.async { [weak self] in
            let infos = (try? AudioProcessCatalog.listAudioProcesses()) ?? []
            let rows = infos.map {
                ProcRow(pid: $0.pid, objectID: $0.objectID, name: $0.name,
                        bundleID: $0.bundleID, isRunningOutput: $0.isRunningOutput)
            }
            let devs = DeviceUtil.allDevices()
                .filter { $0.inChannels > 0 && !$0.uid.hasPrefix("OpenAudioDevice-") }
                .map { (uid: $0.uid, name: $0.name) }
            DispatchQueue.main.async {
                self?.processes = rows
                self?.inputDevices = devs
            }
        }
    }

    // MARK: - Polling gating

    func setWindowVisible(_ v: Bool) { windowVisible = v; reconcilePolling() }
    func setMenuVisible(_ v: Bool)   { menuVisible = v;   reconcilePolling() }

    private var shouldPoll: Bool { windowVisible || menuVisible }

    private func reconcilePolling() {
        if shouldPoll {
            if meterTimer == nil {
                let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                    self?.pollStats()
                }
                t.tolerance = 0.02
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
            DispatchQueue.main.async { self?.stats = s }
        }
    }

    // MARK: - Meter helpers for the UI

    /// Per-source stereo meter (nil until stats arrive / source absent).
    func sourceMeter(_ src: SourceKind) -> StereoMeter? {
        guard let s = stats else { return nil }
        switch src {
        case .tap:   return s.sourcesStereo.first
        case .input: return s.sourcesStereo.count > 1 ? s.sourcesStereo[1] : nil
        }
    }

    /// The overall (pre-routing) mix meter — used as the master output indicator.
    var mixMeter: StereoMeter? { stats?.busMixStereo }

    /// Approximate per-bus level as the max peak of the sources routed to it
    /// (the engine exposes only a global mix meter, not per-bus post-mix levels).
    func busPeakDB(_ bus: Int) -> Float {
        guard stats != nil else { return -.infinity }
        var peak = -Float.infinity
        for r in routes where r.bus == bus {
            if let m = sourceMeter(r.source) { peak = max(peak, m.peakDB) }
        }
        return peak
    }
}
