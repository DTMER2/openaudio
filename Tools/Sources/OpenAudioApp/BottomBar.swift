// BottomBar.swift
// The one-click transport (F-U2): a big Record button that configures + starts
// the engine AND recording together, a separate Start-engine (routing without
// recording) control, the master output meter, elapsed time / file name while
// recording, and TCC guidance when tap creation fails.

import SwiftUI

struct BottomBar: View {
    @Bindable var model: AppModel
    /// Drives the elapsed-time label without polling the whole model.
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            if let err = model.lastError { errorBanner(err) }

            HStack(spacing: 16) {
                recordButton
                engineButton
                Divider().frame(height: 34)
                statusBlock
                Spacer()
                masterMeter
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: Record (primary)

    private var recordButton: some View {
        Button {
            model.toggleRecord()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    .font(.title2)
                Text(model.isRecording ? "Stop" : "Record")
                    .fontWeight(.semibold)
            }
            .frame(minWidth: 108)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.canStart && !model.isRecording)
        .help(model.canStart ? "Record the mix to a file (starts the engine if needed)"
                             : "Select a source first")
    }

    // MARK: Start engine (routing / monitoring only)

    private var engineButton: some View {
        Button {
            model.toggleEngine()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isRunning ? "stop.circle" : "play.circle")
                Text(model.isRunning ? "Stop engine" : "Start engine")
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled((!model.canStart && !model.isRunning) || model.isRecording)
        .help("Run routing and monitoring without recording to a file")
    }

    // MARK: Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(statusText).font(.subheadline).fontWeight(.medium)
            }
            if model.isRecording {
                Text(model.recordURL?.lastPathComponent ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Ready").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if model.isRecording {
            return "Recording  " + Fmt.elapsed(now.timeIntervalSince(model.recordStartDate ?? now))
        }
        return model.isRunning ? "Running" : "Stopped"
    }

    // MARK: Master meter

    private var masterMeter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Output").font(.caption2).foregroundStyle(.secondary)
            MiniMeterView(peakDB: model.mixMeter?.peakL ?? -.infinity, width: 120, height: 7)
            MiniMeterView(peakDB: model.mixMeter?.peakR ?? -.infinity, width: 120, height: 7)
        }
    }

    // MARK: Error / TCC guidance

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.lastErrorIsPermission ? "lock.shield" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.lastErrorIsPermission ? .orange : .yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.lastErrorIsPermission ? "Audio capture permission needed" : "Could not start")
                    .font(.subheadline).fontWeight(.semibold)
                if model.lastErrorIsPermission {
                    Text("OpenAudio needs permission to capture system audio. Open System Settings › "
                       + "Privacy & Security › Screen & System Audio Recording (or approve the prompt), "
                       + "enable this app, then try again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            Button { model.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((model.lastErrorIsPermission ? Color.orange : Color.yellow).opacity(0.12)))
        .padding(.horizontal, 16).padding(.top, 8)
    }
}
