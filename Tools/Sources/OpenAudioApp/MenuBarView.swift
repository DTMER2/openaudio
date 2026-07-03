// MenuBarView.swift
// Menu-bar popover content (F-U6): engine status, Start/Stop, a mini output
// level, monitor on/off, open-main-window, and Quit.

import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    let openMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(status).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)

            HStack(spacing: 8) {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                StereoMiniMeterView(peakL: model.mixMeter?.peakL ?? -.infinity,
                                    peakR: model.mixMeter?.peakR ?? -.infinity,
                                    hold: model.mixHold, width: 130)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)

            rowDivider

            MenuRow(title: model.isRecording ? "Stop recording" : "Record",
                    systemImage: model.isRecording ? "stop.fill" : "record.circle",
                    disabled: !model.canStart && !model.isRecording,
                    action: model.toggleRecord)

            MenuRow(title: model.isRunning ? "Stop engine" : "Start engine",
                    systemImage: model.isRunning ? "stop.circle" : "play.circle",
                    disabled: (!model.canStart && !model.isRunning) || model.isRecording,
                    action: model.toggleEngine)

            HStack(spacing: 8) {
                Image(systemName: "headphones").frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(monitorLabel)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { model.monitorBusIndex != nil },
                    set: { on in
                        if on { model.toggleMonitor(bus: model.monitorBusIndex ?? 0) }
                        else if let b = model.monitorBusIndex { model.toggleMonitor(bus: b) }
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .opacity(model.isRunning ? 1 : 0.4)
            .disabled(!model.isRunning)

            rowDivider

            MenuRow(title: "Open OpenAudio…", systemImage: "macwindow", action: openMain)

            MenuRow(title: "Quit OpenAudio", systemImage: "power", destructive: true) {
                model.stopEngine()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 240)
        .onAppear { model.setMenuVisible(true) }
        .onDisappear { model.setMenuVisible(false) }
    }

    private var rowDivider: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
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

/// A full-width native-style menu row: aligned icon column, hover highlight,
/// left-aligned label. Keeps every action consistent instead of the default
/// bezeled buttons that misaligned and clipped at the popover edge.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18)
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}
