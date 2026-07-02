// CaptureSession.swift
// Orchestrates the capture: ring buffer, gain computation, initial graph build,
// writer thread, silence watchdog, and default-output-device change handling.
// Rebuilds (watchdog- or device-change-triggered) are serialized on a single
// queue so tap/aggregate teardown and recreation never overlap.

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

final class CaptureSession: @unchecked Sendable {
    private let mode: TapMode
    private let outputURL: URL
    private let silenceWindow: Double

    private let ring: RingBuffer
    private let channels: Int
    private let sampleRate: Double
    private let compGain: Float
    private let pairCount: Int

    private var graph: TapGraph?
    private var writer: FileWriter!
    private let rebuildGeneration = Atomic64(0)

    // Rebuild + watchdog coordination
    private let controlQueue = DispatchQueue(label: "com.openaudio.tapcapture.control")
    private var watchdogTimer: DispatchSourceTimer?
    private var lastIOFrames: UInt64 = 0
    private var tickCount = 0
    private var stopping = false

    // Default-output-device change listener
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddr = CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice)

    init(mode: TapMode, outputURL: URL, silenceWindow: Double) throws {
        self.mode = mode
        self.outputURL = outputURL
        self.silenceWindow = silenceWindow

        // Discover the tap's stream format up front (throwaway tap) so the ring
        // and file writer can be sized correctly before the real graph is built.
        let (fmt, _) = try CaptureSession.probeTapFormat(mode: mode)
        self.channels = Int(fmt.mChannelsPerFrame)
        self.sampleRate = fmt.mSampleRate

        // ~2 seconds of headroom in the ring.
        let capacity = max(Int(fmt.mSampleRate * 2.0), 16384)
        self.ring = RingBuffer(channels: channels, capacityFrames: capacity)

        // Attenuation compensation from the default output device pair count.
        let outCh = CaptureSession.defaultOutputChannelCount()
        self.pairCount = max(1, (outCh + 1) / 2)
        self.compGain = pairCount > 1 ? Float(pairCount) : 1.0

        let gainDB = 20 * log10(Double(compGain))
        Log.info("Tap format: \(channels)ch @ \(Int(sampleRate)) Hz, Float32")
        Log.info("Default output device: \(outCh) channels -> \(pairCount) stereo pair(s)")
        Log.info(String(format: "Attenuation compensation: x%.0f (%+.1f dB)%@",
                        compGain, gainDB, pairCount > 1 ? "" : " (none needed)"))

        self.writer = try FileWriter(
            url: outputURL,
            channels: channels,
            sampleRate: sampleRate,
            compGain: compGain,
            ring: ring,
            rebuildGeneration: rebuildGeneration)
    }

    // MARK: Start / Stop

    func start() throws {
        writer.start()
        graph = try TapGraph.build(mode: mode, ring: ring)
        lastIOFrames = ring.ioFrameCount()
        Log.info("Capture started -> \(outputURL.path)")
        installDeviceListener()
        installWatchdog()
    }

    func stop() {
        controlQueue.sync {
            if stopping { return }
            stopping = true
        }
        watchdogTimer?.cancel()
        watchdogTimer = nil
        removeDeviceListener()
        graph?.teardown()
        graph = nil
        writer.stop()

        let frames = writer.framesWritten.load()
        let seconds = Double(frames) / sampleRate
        let overruns = ring.overrunCount()
        Log.info(String(format: "Capture stopped. Wrote %llu frames (%.2f s). Ring overruns: %llu frames.",
                        frames, seconds, overruns))
        Log.info("Output file: \(outputURL.path)")
    }

    // MARK: Rebuild

    /// Full teardown + recreate of tap/aggregate/IOProc. Runs on controlQueue.
    private func rebuild(reason: String) {
        if stopping { return }
        Log.event("Rebuilding capture graph — \(reason)")
        graph?.teardown()
        graph = nil
        do {
            let g = try TapGraph.build(mode: mode, ring: ring)
            graph = g
            rebuildGeneration.add(1)                 // arms the writer's fade-in
            lastIOFrames = ring.ioFrameCount()
            writer.lastNonZeroMach.store(MachClock.now()) // reset silence baseline
            Log.event("Rebuild complete; resuming with 10 ms fade-in.")
        } catch {
            Log.error("Rebuild failed: \(error). Retrying in 1 s.")
            controlQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.rebuild(reason: "retry after failed rebuild")
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
        let io = ring.ioFrameCount()
        let firing = io != lastIOFrames
        lastIOFrames = io

        tickCount += 1
        if tickCount % 2 == 0 {
            let db = writer.currentRMSdB()
            let dbStr = db.isFinite ? String(format: "%.1f dBFS", db) : "-inf dBFS"
            Log.info(String(format: "meter: %@  ioFrames=%llu  written=%llu  overruns=%llu  ioFiring=%@",
                            dbStr, io, writer.framesWritten.load(), ring.overrunCount(),
                            firing ? "yes" : "no"))
        }

        // Only judge silence once real audio has been observed at least once.
        //
        // Known limitations (inherent to the fires-but-bit-zero criterion):
        // - Genuine digital silence (nothing playing) is indistinguishable from
        //   the zero-output tap bug, so after `silenceWindow` seconds of true
        //   silence a rebuild fires. It is harmless (the splice and fade-in
        //   happen over silence) and repeats at most once per window; raise
        //   --silence-window to reduce churn.
        // - An IOProc that stops firing entirely is NOT treated as tap death
        //   (`firing == false` skips the rebuild); the device-change listener
        //   covers the common cause of that state.
        guard writer.hasSeenAudio() else { return }
        let silent = writer.secondsSinceLastNonZero()
        if firing && silent >= silenceWindow {
            rebuild(reason: String(format:
                "silence watchdog: IOProc firing but samples bit-zero for %.1fs (window %.1fs)",
                silent, silenceWindow))
        }
    }

    // MARK: Default-output-device change

    private func installDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async {
                self.rebuild(reason: "default output device changed")
            }
        }
        deviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceListenerAddr,
            controlQueue,
            block)
        if status != noErr {
            Log.warn("Could not register default-output-device listener: OSStatus \(osStatusString(status))")
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceListenerAddr,
            controlQueue,
            block)
        deviceListenerBlock = nil
    }

    // MARK: Static helpers

    /// Creates a throwaway tap to discover the stream format, then destroys it.
    private static func probeTapFormat(mode: TapMode) throws -> (AudioStreamBasicDescription, String) {
        let description: CATapDescription
        switch mode {
        case .system:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .processes(let objs):
            description = CATapDescription(stereoMixdownOfProcesses: objs)
        }
        description.name = "OpenAudio-Tap-Probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        if status != noErr {
            throw TapError(
                "AudioHardwareCreateProcessTap failed while probing format: OSStatus \(osStatusString(status)).\n" +
                "System audio-capture permission (TCC) may be required — approve the prompt attributed\n" +
                "to your terminal application and retry.")
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }
        let fmt: AudioStreamBasicDescription = try CAProperty.scalar(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let uid = (try? CAProperty.string(tapID, kAudioTapPropertyUID)) ?? ""
        guard fmt.mChannelsPerFrame > 0, fmt.mSampleRate > 0 else {
            throw TapError("Probe tap reported invalid format")
        }
        return (fmt, uid)
    }

    /// Sums the default output device's output channels across all streams.
    static func defaultOutputChannelCount() -> Int {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard let dev: AudioObjectID = try? CAProperty.scalar(
            sys, kAudioHardwarePropertyDefaultOutputDevice, default: 0), dev != 0 else {
            return 2
        }
        var addr = CAProperty.address(
            kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 2
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else {
            return 2
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        var ch = 0
        for b in abl { ch += Int(b.mNumberChannels) }
        return ch > 0 ? ch : 2
    }
}
