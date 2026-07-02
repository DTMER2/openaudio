// MenuBarView.swift
// Menu-bar popover content (F-U6): engine status, Start/Stop, a mini output
// level, monitor on/off, open-main-window, and Quit.

import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    let openMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(status).font(.headline)
                Spacer()
            }

            HStack {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                MiniMeterView(peakDB: model.mixMeter?.peakDB ?? -.infinity, width: 130, height: 6)
            }

            Divider()

            Button {
                model.toggleRecord()
            } label: {
                Label(model.isRecording ? "Stop recording" : "Record",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle")
            }
            .disabled(!model.canStart && !model.isRecording)

            Button {
                model.toggleEngine()
            } label: {
                Label(model.isRunning ? "Stop engine" : "Start engine",
                      systemImage: model.isRunning ? "stop.circle" : "play.circle")
            }
            .disabled((!model.canStart && !model.isRunning) || model.isRecording)

            Toggle(isOn: Binding(
                get: { model.monitorBusIndex != nil },
                set: { on in
                    if on { model.toggleMonitor(bus: model.monitorBusIndex ?? 0) }
                    else if let b = model.monitorBusIndex { model.toggleMonitor(bus: b) }
                })) {
                Label(monitorLabel, systemImage: "headphones")
            }
            .toggleStyle(.switch)
            .disabled(!model.isRunning)

            Divider()

            Button {
                openMain()
            } label: { Label("Open OpenAudio…", systemImage: "macwindow") }

            Button(role: .destructive) {
                model.stopEngine()
                NSApplication.shared.terminate(nil)
            } label: { Label("Quit OpenAudio", systemImage: "power") }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { model.setMenuVisible(true) }
        .onDisappear { model.setMenuVisible(false) }
    }

    private var status: String {
        if model.isRecording { return "Recording" }
        return model.isRunning ? "Running" : "Stopped"
    }

    private var monitorLabel: String {
        if let b = model.monitorBusIndex { return "Monitor bus \(b + 1)" }
        return "Monitor bus 1"
    }
}
