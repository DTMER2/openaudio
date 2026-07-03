// main.swift
// Entry point: argument dispatch, TCC guidance, signal-driven clean shutdown.

import Foundation
import CoreAudio
import Darwin

func runCapture(_ opts: CLIOptions) throws {
    Log.info("Preparing capture. If macOS prompts for audio-capture permission, approve it for")
    Log.info("your terminal application — the prompt is attributed to the hosting process (TCC).")

    let mode: TapMode
    if opts.system {
        mode = .system
        Log.info("Mode: system-wide capture (all output, no exclusions).")
    } else {
        var objects: [AudioObjectID] = []
        for pid in opts.pids {
            let obj = try ProcessCatalog.processObject(forPID: pid)
            let info = ProcessCatalog.info(for: obj)
            Log.info("Tapping PID \(pid) (\(info.name)) -> process object \(obj)")
            objects.append(obj)
        }
        mode = .processes(objects)
    }

    let url = URL(fileURLWithPath: opts.output!)
    let session = try CaptureSession(mode: mode, outputURL: url, silenceWindow: opts.silenceWindow)
    try session.start()
    activeSession = session

    // Clean finalize on Ctrl-C.
    signal(SIGINT, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSource.setEventHandler {
        Log.info("SIGINT received — finalizing output file...")
        activeSession?.stop()
        exit(0)
    }
    sigSource.resume()
    signalSource = sigSource

    if let duration = opts.duration {
        Log.info(String(format: "Will stop automatically after %.1f s.", duration))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            Log.info("Duration reached — finalizing output file...")
            activeSession?.stop()
            exit(0)
        }
    } else {
        Log.info("Recording until Ctrl-C.")
    }

    dispatchMain()
}

// Retained for the lifetime of the process.
var activeSession: CaptureSession?
var signalSource: DispatchSourceSignal?

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let options = try CLI.parse(arguments)
    switch options.command {
    case .help:
        print(CLI.usage)
        exit(0)
    case .list:
        try ProcessCatalog.printList()
        exit(0)
    case .capture:
        try runCapture(options)
    }
} catch let error as TapError {
    Log.error(error.description)
    FileHandle.standardError.write(Data("\nRun `tapcapture --help` for usage.\n".utf8))
    exit(1)
} catch {
    Log.error("\(error)")
    exit(1)
}
