// CLI.swift
// Hand-rolled argument parsing for the `openaudio` engine driver (no external
// dependencies), matching the tapcapture CLI style.

import Foundation

struct RouteSpec {
    var source: String            // "tap" or "input"
    var buses: [Int]              // 0-based bus indices
}

struct RunOptions {
    var tapSystem = false
    var tapPIDs: [pid_t] = []
    var inputSpec: String?        // "default" or a device UID
    var tapGainDB: Float = 0
    var inputGainDB: Float = 0
    var tapPan: Float = 0
    var recordPath: String?
    var duration: Double?
    var statsInterval: Double = 2.0
    var silenceWindow: Double = 10.0
    var busCount: Int = 1
    var routes: [RouteSpec] = []  // empty => all sources -> bus 1
    var monitorBus: Int?          // 0-based; nil => monitoring off
    var monitorGainDB: Float = 0
}

enum ParsedCommand {
    case run(RunOptions)
    case probeVDev(output: String, duration: Double?, deviceUID: String)
    case buses(count: Int?)       // nil => read/list; non-nil => set then list
    case devices
    case processes
    case help
}

enum CLI {
    static let usage = """
    openaudio — Phase 1 engine: capture (tap + optional input) -> mix -> clock bridge -> virtual device

    USAGE:
      openaudio run (--tap-pid <pid>... | --tap-system) [--input default|<uid>]
                    [--buses N] [--route <src>=<bus[,bus...]>]...
                    [--gain tap=<dB>] [--gain input=<dB>] [--pan tap=<-1..1>]
                    [--record <out.caf>] [--duration <sec>] [--stats-interval <sec>]
                    [--silence-window <sec>]
      openaudio buses [N]
      openaudio probe-vdev -o <out.caf> [--duration <sec>] [--device <uid>]
      openaudio devices
      openaudio processes
      openaudio --help

    COMMANDS:
      run           Start the engine. Prints a stats line every --stats-interval seconds.
                    Reads interactive commands from stdin while running (see below).
      buses [N]     Read (no arg) or set (N=1..8) the driver's published device count via
                    the control plane, then list the resulting OpenAudio devices. Requires
                    the Phase 2 driver for setting; fails clearly on older drivers.
      probe-vdev    Open the virtual device INPUT (ch 0/1) and record it to CAF (end-to-end proof).
      devices       List output/input devices (id, UID, name, in/out ch, rate).
      processes     List audio-capable processes (pid, output-active, name, bundle ID) (F-U3).

    RUN OPTIONS:
      --tap-pid <pid>       Tap this process output (repeatable).
      --tap-system          Tap all system output.
      --input default|<uid> Add a real input device as a source (drift-compensated in-aggregate).
      --buses N             Attach buses 1..N (virtual devices OpenAudioDevice-1..N). Default 1.
      --route <src>=<b,..>  Route source (tap|input) to 1-based bus indices. Repeatable.
                            Default (no --route): all sources -> bus 1.
      --gain tap=<dB>       Tap gain in dB (default 0).
      --gain input=<dB>     Input gain in dB (default 0).
      --pan tap=<-1..1>     Tap stereo balance (equal-power), -1 L .. +1 R.
      --monitor <bus>       Pass bus (1-based) through to the default output for monitoring.
      --monitor-gain <dB>   Monitor gain in dB (default 0). Applies to the monitor path only.
      --record <out.caf>    Record the full (pre-routing) stereo mix to a CAF file.
      --duration <sec>      Stop automatically after N seconds (default: until Ctrl-C).
      --stats-interval <s>  Stats print interval (default 2).
      --silence-window <s>  Silence-watchdog window before rebuild (default 10).

    INTERACTIVE (stdin, while `run` is active):
      route <src> <bus> on|off   Toggle a (source, 1-based bus) route.
      gain <src> <dB>            Set source gain.
      pan <src> <v>              Set source pan (-1..1).
      mute <src> on|off          Mute/unmute a source.
      attach <bus>               Attach a bus (1-based) at runtime.
      detach <bus>               Detach a bus (1-based) at runtime.
      monitor <bus|off> [dB]     Monitor a bus (1-based) to the default output, or turn off.
      stats                      Print a stats line now.
      quit                       Stop the engine and exit.

    NOTES:
      First use triggers the system audio-capture (TCC) consent prompt, attributed to the
      hosting terminal application.
    """

    static func parse(_ args: [String]) throws -> ParsedCommand {
        guard let first = args.first else {
            throw CLIError("No command given. See --help.")
        }
        if first == "-h" || first == "--help" { return .help }

        let rest = Array(args.dropFirst())
        switch first {
        case "run":        return try parseRun(rest)
        case "probe-vdev": return try parseProbe(rest)
        case "buses":      return try parseBuses(rest)
        case "devices":    return .devices
        case "processes":  return .processes
        default:
            throw CLIError("Unknown command: \(first). See --help.")
        }
    }

    private static func parseBuses(_ args: [String]) throws -> ParsedCommand {
        if args.isEmpty { return .buses(count: nil) }
        guard args.count == 1, let n = Int(args[0]), n >= 1, n <= 8 else {
            throw CLIError("buses takes an optional count 1..8 (e.g. `openaudio buses 3`)")
        }
        return .buses(count: n)
    }

    private static func parseRun(_ args: [String]) throws -> ParsedCommand {
        var o = RunOptions()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--tap-system":
                o.tapSystem = true
            case "--tap-pid":
                i += 1
                guard i < args.count, let p = pid_t(args[i]) else { throw CLIError("--tap-pid requires a PID") }
                o.tapPIDs.append(p)
            case "--input":
                i += 1
                guard i < args.count else { throw CLIError("--input requires 'default' or a device UID") }
                o.inputSpec = args[i]
            case "--buses":
                i += 1
                guard i < args.count, let n = Int(args[i]), n >= 1, n <= 8 else {
                    throw CLIError("--buses requires an integer 1..8")
                }
                o.busCount = n
            case "--route":
                i += 1
                guard i < args.count else { throw CLIError("--route requires <src>=<bus[,bus...]>") }
                let (src, list) = try splitKV(args[i], flag: "--route")
                guard src == "tap" || src == "input" else {
                    throw CLIError("--route source must be 'tap' or 'input': \(args[i])")
                }
                var buses: [Int] = []
                for tok in list.split(separator: ",") {
                    guard let b = Int(tok), b >= 1, b <= 8 else {
                        throw CLIError("--route bus indices must be 1..8: \(args[i])")
                    }
                    buses.append(b - 1)   // to 0-based
                }
                guard !buses.isEmpty else { throw CLIError("--route needs at least one bus: \(args[i])") }
                o.routes.append(RouteSpec(source: src, buses: buses))
            case "--gain":
                i += 1
                guard i < args.count else { throw CLIError("--gain requires src=<dB> (e.g. tap=-3)") }
                let (k, v) = try splitKV(args[i], flag: "--gain")
                guard let db = Float(v) else { throw CLIError("--gain value must be a number: \(args[i])") }
                switch k {
                case "tap":   o.tapGainDB = db
                case "input": o.inputGainDB = db
                default: throw CLIError("--gain source must be 'tap' or 'input': \(args[i])")
                }
            case "--pan":
                i += 1
                guard i < args.count else { throw CLIError("--pan requires tap=<-1..1>") }
                let (k, v) = try splitKV(args[i], flag: "--pan")
                guard let pan = Float(v) else { throw CLIError("--pan value must be a number: \(args[i])") }
                guard k == "tap" else { throw CLIError("--pan currently supports only 'tap'") }
                o.tapPan = max(-1, min(1, pan))
            case "--monitor":
                i += 1
                guard i < args.count, let b = Int(args[i]), b >= 1, b <= 8 else {
                    throw CLIError("--monitor requires a 1-based bus index 1..8")
                }
                o.monitorBus = b - 1   // to 0-based
            case "--monitor-gain":
                i += 1
                guard i < args.count, let db = Float(args[i]) else {
                    throw CLIError("--monitor-gain requires a number (dB)")
                }
                o.monitorGainDB = db
            case "--record":
                i += 1
                guard i < args.count else { throw CLIError("--record requires a file path") }
                o.recordPath = args[i]
            case "--duration":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else { throw CLIError("--duration requires positive seconds") }
                o.duration = d
            case "--stats-interval":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else { throw CLIError("--stats-interval requires positive seconds") }
                o.statsInterval = d
            case "--silence-window":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else { throw CLIError("--silence-window requires positive seconds") }
                o.silenceWindow = d
            default:
                throw CLIError("Unknown run argument: \(a)")
            }
            i += 1
        }
        if o.tapSystem && !o.tapPIDs.isEmpty { throw CLIError("--tap-system cannot be combined with --tap-pid") }
        if !o.tapSystem && o.tapPIDs.isEmpty { throw CLIError("Specify --tap-system or one or more --tap-pid <pid>") }
        return .run(o)
    }

    private static func parseProbe(_ args: [String]) throws -> ParsedCommand {
        var output: String?
        var duration: Double?
        var deviceUID = "OpenAudioDevice-1"
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--output":
                i += 1
                guard i < args.count else { throw CLIError("\(a) requires a file path") }
                output = args[i]
            case "--duration":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else { throw CLIError("--duration requires positive seconds") }
                duration = d
            case "--device":
                i += 1
                guard i < args.count else { throw CLIError("--device requires a device UID") }
                deviceUID = args[i]
            default:
                throw CLIError("Unknown probe-vdev argument: \(a)")
            }
            i += 1
        }
        guard let out = output else { throw CLIError("probe-vdev requires -o <out.caf>") }
        return .probeVDev(output: out, duration: duration, deviceUID: deviceUID)
    }

    private static func splitKV(_ s: String, flag: String) throws -> (String, String) {
        let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CLIError("\(flag) expects key=value, got '\(s)'") }
        return (parts[0], parts[1])
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}
