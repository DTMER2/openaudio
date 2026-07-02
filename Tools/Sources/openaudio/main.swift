// main.swift
// Entry point for the `openaudio` CLI: dispatches run / probe-vdev / devices,
// installs a clean-shutdown signal handler, and prints periodic engine stats.

import Foundation
import CoreAudio
import AudioToolbox
import OpenAudioEngine
import Darwin

// Retained for the process lifetime.
var activeEngine: Engine?
var signalSource: DispatchSourceSignal?

// MARK: - PID -> Core Audio process object

func processObject(forPID pid: pid_t) throws -> AudioObjectID {
    var addr = CAProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var inPID = pid
    var obj: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &obj),
        "TranslatePIDToProcessObject(pid: \(pid))")
    if obj == 0 { throw OAError("No Core Audio process object for PID \(pid) (running / producing audio?)") }
    return obj
}

// MARK: - devices

func runDevices() {
    let devices = DeviceUtil.allDevices()
    func pad(_ s: String, _ w: Int) -> String {
        let t = s.count > w - 1 ? String(s.prefix(w - 1)) : s
        return t + String(repeating: " ", count: max(0, w - t.count))
    }
    print(pad("ID", 6) + pad("IN", 4) + pad("OUT", 5) + pad("RATE", 8) + pad("NAME", 28) + "UID")
    print(String(repeating: "-", count: 90))
    for d in devices {
        print(pad(String(d.id), 6) + pad(String(d.inChannels), 4) + pad(String(d.outChannels), 5)
              + pad(String(Int(d.sampleRate)), 8) + pad(d.name, 28) + d.uid)
    }
}

// MARK: - run

func runEngine(_ o: RunOptions) throws {
    OALog.info("Preparing engine. If macOS prompts for audio-capture permission, approve it for the terminal.")

    let tapMode: EngineTapMode
    if o.tapSystem {
        tapMode = .system
        OALog.info("Tap mode: system-wide.")
    } else {
        var objs: [AudioObjectID] = []
        for pid in o.tapPIDs {
            let obj = try processObject(forPID: pid)
            OALog.info("Tapping PID \(pid) -> process object \(obj)")
            objs.append(obj)
        }
        tapMode = .processes(objs)
    }

    var cfg = EngineConfig(tapMode: tapMode)
    cfg.inputDeviceUID = o.inputSpec
    cfg.recordURL = o.recordPath.map { URL(fileURLWithPath: $0) }
    cfg.silenceWindow = o.silenceWindow
    cfg.tapGainDB = o.tapGainDB
    cfg.inputGainDB = o.inputGainDB
    cfg.tapPan = o.tapPan
    cfg.busCount = o.busCount
    cfg.routes = o.routes.map { spec in
        EngineRoute(source: spec.source == "input" ? .input : .tap, buses: spec.buses)
    }

    let engine = try Engine(config: cfg)
    try engine.start()
    activeEngine = engine

    // Clean finalize on Ctrl-C.
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler {
        OALog.info("SIGINT received — stopping engine...")
        activeEngine?.stop()
        exit(0)
    }
    sig.resume()
    signalSource = sig

    // Periodic stats.
    let statsTimer = DispatchSource.makeTimerSource(queue: .main)
    statsTimer.schedule(deadline: .now() + o.statsInterval, repeating: o.statsInterval)
    statsTimer.setEventHandler { printStats(engine) }
    statsTimer.resume()

    // Interactive stdin command loop on a background thread.
    startInteractive(engine, statsTimer: statsTimer)

    if let d = o.duration {
        OALog.info(String(format: "Will stop automatically after %.1f s.", d))
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
            OALog.info("Duration reached — stopping engine...")
            statsTimer.cancel()
            activeEngine?.stop()
            exit(0)
        }
    } else {
        OALog.info("Running until Ctrl-C (or `quit` on stdin).")
    }
    dispatchMain()
}

func dbStr(_ v: Float) -> String { v.isFinite ? String(format: "%.1f", v) : "-inf" }

func printStats(_ engine: Engine) {
    let s = engine.stats()
    var srcStr = ""
    for m in s.sources {
        srcStr += String(format: " %@[pk %@ rms %@]", m.name, dbStr(m.peakDB), dbStr(m.rmsDB))
    }
    var busStr = ""
    for b in s.buses {
        busStr += String(format: " b%d[fill %d (%.0f%%) %+.1fppm u%llu o%llu c%llu]",
                         b.index + 1, b.fillFrames, b.fillPct, b.ratioPPM,
                         b.underruns, b.overruns, b.consumerCallbacks)
    }
    let line = String(format: "mix[pk %@ rms %@]%@ |%@ | route %@ | wdog %llu",
                      dbStr(s.busMixPeakDB), dbStr(s.busMixRMSDB), srcStr, busStr,
                      engine.routingDescription(), s.watchdogEvents)
    OALog.info(line)
}

/// Reads stdin lines on a background thread and applies live commands.
func startInteractive(_ engine: Engine, statsTimer: DispatchSourceTimer) {
    let t = Thread {
        while let line = readLine(strippingNewline: true) {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let cmd = toks.first?.lowercased() else { continue }
            let args = Array(toks.dropFirst())
            do {
                try handleCommand(engine, cmd, args, statsTimer: statsTimer)
            } catch let e as OAError {
                OALog.error("command failed: \(e.description)")
            } catch {
                OALog.error("command failed: \(error)")
            }
        }
        // stdin closed (EOF): leave the engine running (matches Ctrl-C model);
        // duration/SIGINT still govern shutdown.
    }
    t.name = "OpenAudio.CLI.stdin"
    t.start()
}

func parseSource(_ s: String) throws -> EngineSource {
    switch s.lowercased() {
    case "tap":   return .tap
    case "input": return .input
    default: throw OAError("source must be 'tap' or 'input': \(s)")
    }
}

func parseOnOff(_ s: String) throws -> Bool {
    switch s.lowercased() {
    case "on", "1", "true":   return true
    case "off", "0", "false": return false
    default: throw OAError("expected on|off: \(s)")
    }
}

func handleCommand(_ engine: Engine, _ cmd: String, _ args: [String],
                   statsTimer: DispatchSourceTimer) throws {
    switch cmd {
    case "route":
        guard args.count == 3 else { throw OAError("usage: route <src> <bus> on|off") }
        let src = try parseSource(args[0])
        guard let bus1 = Int(args[1]), bus1 >= 1 else { throw OAError("bus must be a 1-based integer") }
        let on = try parseOnOff(args[2])
        try engine.setRoute(src, bus: bus1 - 1, on: on)
        OALog.info("route \(args[0]) \(bus1) \(on ? "on" : "off") -> \(engine.routingDescription())")
    case "gain":
        guard args.count == 2, let db = Float(args[1]) else { throw OAError("usage: gain <src> <dB>") }
        let src = try parseSource(args[0])
        engine.setGain(src, dB: db)
        OALog.info("gain \(args[0]) = \(db) dB")
    case "pan":
        guard args.count == 2, let v = Float(args[1]) else { throw OAError("usage: pan <src> <-1..1>") }
        let src = try parseSource(args[0])
        engine.setPan(src, max(-1, min(1, v)))
        OALog.info("pan \(args[0]) = \(max(-1, min(1, v)))")
    case "mute":
        guard args.count == 2 else { throw OAError("usage: mute <src> on|off") }
        let src = try parseSource(args[0])
        let on = try parseOnOff(args[1])
        engine.setMute(src, on)
        OALog.info("mute \(args[0]) \(on ? "on" : "off")")
    case "attach":
        guard args.count == 1, let bus1 = Int(args[0]), bus1 >= 1 else { throw OAError("usage: attach <bus>") }
        try engine.attachBus(bus1 - 1)
        OALog.info("attached bus \(bus1); attached: \(engine.attachedBusIndices().map { $0 + 1 })")
    case "detach":
        guard args.count == 1, let bus1 = Int(args[0]), bus1 >= 1 else { throw OAError("usage: detach <bus>") }
        try engine.detachBus(bus1 - 1)
        OALog.info("detached bus \(bus1); attached: \(engine.attachedBusIndices().map { $0 + 1 })")
    case "stats":
        printStats(engine)
    case "quit", "exit", "q":
        OALog.info("quit received — stopping engine...")
        statsTimer.cancel()
        activeEngine?.stop()
        exit(0)
    default:
        OALog.warn("unknown command '\(cmd)' (route|gain|pan|mute|attach|detach|stats|quit)")
    }
}

// MARK: - buses (control plane)

func runBuses(count: Int?) throws {
    if let n = count {
        OALog.info("Setting driver device count to \(n) via control plane...")
        let applied = try ControlPlane.setDeviceCount(n)
        OALog.info("Device count set to \(applied); HAL device list settled.")
    } else {
        let current = try ControlPlane.deviceCount()
        OALog.info("Current driver device count: \(current)")
    }
    // List the resulting OpenAudio devices.
    let devices = DeviceUtil.allDevices().filter { $0.uid.hasPrefix("OpenAudioDevice-") }
    if devices.isEmpty {
        print("(no OpenAudio devices present)")
        return
    }
    func pad(_ s: String, _ w: Int) -> String {
        let t = s.count > w - 1 ? String(s.prefix(w - 1)) : s
        return t + String(repeating: " ", count: max(0, w - t.count))
    }
    print(pad("ID", 6) + pad("IN", 4) + pad("OUT", 5) + pad("RATE", 8) + pad("NAME", 28) + "UID")
    print(String(repeating: "-", count: 70))
    for d in devices.sorted(by: { $0.uid < $1.uid }) {
        print(pad(String(d.id), 6) + pad(String(d.inChannels), 4) + pad(String(d.outChannels), 5)
              + pad(String(Int(d.sampleRate)), 8) + pad(d.name, 28) + d.uid)
    }
}

// MARK: - probe-vdev

/// Opens the virtual device's INPUT (channels 0/1) with its own IOProc and
/// records to CAF. Independent, second-process proof of the end-to-end path.
func runProbe(output: String, duration: Double?, deviceUID: String = "OpenAudioDevice-1") throws {
    let uid = deviceUID
    let dev = DeviceUtil.device(forUID: uid)
    guard dev != 0 else { throw OAError("Virtual device '\(uid)' not found.") }
    let rate = DeviceUtil.nominalSampleRate(dev)
    let sr = rate > 0 ? rate : 48000
    let dur = duration ?? 15.0
    OALog.info(String(format: "probe-vdev: recording virtual device input ch0/1 for %.1f s @ %.0f Hz -> %@", dur, sr, output))

    // Preallocated capture buffer (stereo), filled by the RT IOProc via memcpy.
    let capacityFrames = Int(sr * (dur + 1.0))
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
    buffer.initialize(repeating: 0, count: capacityFrames * 2)
    defer { buffer.deallocate() }
    let offset = UnsafeMutablePointer<Int>.allocate(capacity: 1); offset.pointee = 0
    defer { offset.deallocate() }

    let block: AudioDeviceIOBlock = { (_, inInputData, _, _, _) in
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard inList.count > 0, let raw = inList[0].mData else { return }
        let ch = Int(inList[0].mNumberChannels)
        if ch <= 0 { return }
        let frames = Int(inList[0].mDataByteSize) / (ch * MemoryLayout<Float>.size)
        let src = raw.assumingMemoryBound(to: Float.self)
        var pos = offset.pointee
        var i = 0
        while i < frames && pos < capacityFrames {
            buffer[pos * 2] = src[i * ch]
            buffer[pos * 2 + 1] = ch > 1 ? src[i * ch + 1] : src[i * ch]
            pos += 1; i += 1
        }
        offset.pointee = pos
    }

    var procID: AudioDeviceIOProcID?
    try check(AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil, block),
              "AudioDeviceCreateIOProcIDWithBlock(probe)")
    guard let procID else { throw OAError("probe IOProc creation returned null") }
    try check(AudioDeviceStart(dev, procID), "AudioDeviceStart(probe)")
    Thread.sleep(forTimeInterval: dur)
    AudioDeviceStop(dev, procID)
    AudioDeviceDestroyIOProcID(dev, procID)

    let framesCaptured = offset.pointee
    OALog.info("probe-vdev: captured \(framesCaptured) frames; writing CAF...")

    // Write to CAF (Float32 stereo).
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var file: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(URL(fileURLWithPath: output) as CFURL, kAudioFileCAFType,
                                        &asbd, nil, AudioFileFlags.eraseFile.rawValue, &file),
              "ExtAudioFileCreateWithURL(\(output))")
    guard let file else { throw OAError("ExtAudioFileCreateWithURL returned null") }
    defer { ExtAudioFileDispose(file) }
    try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd),
              "ExtAudioFileSetProperty(ClientDataFormat)")
    if framesCaptured > 0 {
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2,
                                  mDataByteSize: UInt32(framesCaptured * 2 * MemoryLayout<Float>.size),
                                  mData: buffer))
        try check(ExtAudioFileWrite(file, UInt32(framesCaptured), &abl), "ExtAudioFileWrite")
    }
    OALog.info("probe-vdev: wrote \(output)")
}

// MARK: - Dispatch

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch try CLI.parse(arguments) {
    case .help:
        print(CLI.usage); exit(0)
    case .devices:
        runDevices(); exit(0)
    case .probeVDev(let out, let dur, let uid):
        try runProbe(output: out, duration: dur, deviceUID: uid); exit(0)
    case .buses(let count):
        try runBuses(count: count); exit(0)
    case .run(let o):
        try runEngine(o)
    }
} catch let e as CLIError {
    OALog.error(e.description)
    FileHandle.standardError.write(Data("\nRun `openaudio --help` for usage.\n".utf8))
    exit(1)
} catch let e as OAError {
    OALog.error(e.description)
    exit(1)
} catch {
    OALog.error("\(error)")
    exit(1)
}
