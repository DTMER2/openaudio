// CLI.swift
// Hand-rolled argument parsing (no external dependencies).

import Foundation

struct CLIOptions {
    enum Command {
        case list
        case help
        case capture
    }

    var command: Command = .capture
    var system = false
    var pids: [pid_t] = []
    var output: String?
    var duration: Double?           // seconds; nil = until Ctrl-C
    var silenceWindow: Double = 10.0
}

enum CLI {
    static let usage = """
    tapcapture — record process / system audio output via Core Audio Process Taps (macOS 14.4+)

    USAGE:
      tapcapture --list
      tapcapture --pid <pid> [--pid <pid> ...] -o <out.caf> [--duration <sec>] [--silence-window <sec>]
      tapcapture --system -o <out.caf> [--duration <sec>] [--silence-window <sec>]

    OPTIONS:
      --list                 List audio process objects (PID / output-active / name / bundle id)
      --pid <pid>            Capture this process (repeatable to tap several at once)
      --system               Capture all system output (excludes nothing)
      -o, --output <path>    Output CAF file (Float32, tap's native stream format)
      --duration <sec>       Stop automatically after <sec> seconds (default: run until Ctrl-C)
      --silence-window <sec> Silence-watchdog window before rebuild (default: 10)
      -h, --help             Show this help

    NOTES:
      First use triggers the system audio-capture (TCC) consent prompt, attributed to the
      hosting terminal application. Approve it, then re-run.
    """

    static func parse(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var sawSelector = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--list":
                opts.command = .list
            case "-h", "--help":
                opts.command = .help
            case "--system":
                opts.system = true
                sawSelector = true
            case "--pid":
                i += 1
                guard i < args.count, let pid = pid_t(args[i]) else {
                    throw TapError("--pid requires an integer PID")
                }
                opts.pids.append(pid)
                sawSelector = true
            case "-o", "--output":
                i += 1
                guard i < args.count else { throw TapError("\(arg) requires a file path") }
                opts.output = args[i]
            case "--duration":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else {
                    throw TapError("--duration requires a positive number of seconds")
                }
                opts.duration = d
            case "--silence-window":
                i += 1
                guard i < args.count, let d = Double(args[i]), d > 0 else {
                    throw TapError("--silence-window requires a positive number of seconds")
                }
                opts.silenceWindow = d
            default:
                throw TapError("Unknown argument: \(arg)")
            }
            i += 1
        }

        // Validation (skipped for list/help)
        if opts.command == .list || opts.command == .help { return opts }

        if opts.system && !opts.pids.isEmpty {
            throw TapError("--system cannot be combined with --pid")
        }
        if !sawSelector {
            throw TapError("Specify --system or one or more --pid <pid> (or --list). See --help.")
        }
        if opts.output == nil {
            throw TapError("Output file is required: -o <out.caf>")
        }
        return opts
    }
}
