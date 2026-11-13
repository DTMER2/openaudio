// SourcesPane.swift
// Pane 1 (F-U3 / F-U5): choose capture sources — any number of microphones /
// audio interfaces at the top (picked from a multi-select pull-down; each
// becomes its own mix source), then system audio or specific running apps.
// Rows show the app icon and a friendly name; user-facing apps sort above
// daemons. Per-source levels live in the mixer drawer (X key), not here.

import SwiftUI
import AppKit

struct SourcesPane: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var micPickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    microphones
                    systemToggle
                    processList
                }
                .padding(14)
            }
        }
    }

    // MARK: System audio

    private var systemToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.useSystemAudio },
                                 set: { model.useSystemAudio = $0 })) {
                Label("System audio", systemImage: "speaker.wave.3.fill")
                    .font(.headline)
            }
            .toggleStyle(.switch)
            .disabled(sourcesLocked)
        }
    }

    // MARK: Process list (F-U3)

    private var processList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Applications").font(.headline)
                Spacer()
                Button {
                    model.refreshProcesses()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the list of running audio apps")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            let rows = filteredProcesses
            if rows.isEmpty {
                Text("No audio applications found.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in processRow(row) }
                }
                .opacity(model.useSystemAudio ? 0.45 : 1)
                .disabled(model.useSystemAudio || sourcesLocked)
            }
            if selectionAtCap {
                Text("Up to \(model.maxSources) apps and microphones can be mixed at once.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var selectionAtCap: Bool { model.selectedPIDs.count >= model.maxSelectableApps }

    private func processRow(_ row: ProcRow) -> some View {
        let selected = model.isSelected(pid: row.pid)
        let selectable = selected || !selectionAtCap
        return Button {
            model.toggleProcess(pid: row.pid)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                appIcon(row)
                Circle()
                    .fill(row.isRunningOutput ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(row.isRunningOutput ? "Currently playing" : "Idle")
                Text(row.displayName).lineLimit(1)
                    .help(row.bundleID ?? row.name)
                Spacer()
                Text("pid \(row.pid)").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .opacity(selectable ? 1 : 0.4)
    }

    @ViewBuilder private func appIcon(_ row: ProcRow) -> some View {
        if let icon = model.appIcons[row.pid] {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private var filteredProcesses: [ProcRow] {
        let base = model.processes
        guard !search.isEmpty else { return base }
        return base.filter { $0.displayName.localizedCaseInsensitiveContains(search)
            || $0.name.localizedCaseInsensitiveContains(search)
            || ($0.bundleID?.localizedCaseInsensitiveContains(search) ?? false) }
    }

    // MARK: Microphones (multi-select input devices)

    private var microphones: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Microphones").font(.headline)
                Spacer()
                micPickerButton
            }

            if !model.selectedInputUIDs.isEmpty {
                VStack(spacing: 2) {
                    ForEach(model.selectedInputUIDs, id: \.self) { uid in selectedMicRow(uid) }
                }
                .disabled(sourcesLocked)
            }

            bluetoothNotice
        }
    }

    /// Pull-down that stays open so several devices can be ticked in one go.
    private var micPickerButton: some View {
        Button {
            micPickerShown.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text(model.selectedInputUIDs.isEmpty ? "Add" : "Edit")
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .controlSize(.small)
        .disabled(sourcesLocked)
        .help("Choose input devices to mix (multiple selection)")
        .popover(isPresented: $micPickerShown, arrowEdge: .bottom) { micPicker }
    }

    private var micPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input devices").font(.headline)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            if model.inputDevices.isEmpty {
                Text("No input devices found.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.inputDevices) { dev in micPickerRow(dev) }
                }
                .padding(.vertical, 4)
            }
            Divider()
            Toggle("Keep Mac default input on built-in mic",
                   isOn: Binding(get: { model.pinDefaultInputToBuiltIn },
                                 set: { model.setPinDefaultInputToBuiltIn($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .help("When a Bluetooth headset connects, macOS makes it the default input; apps using the default mic then turn its playback mono. This switches the default back to the built-in mic.")
            if model.inputSelectionAtCap {
                Divider()
                Text("Up to \(model.maxSources) apps and microphones can be mixed at once.")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 320)
    }

    private func micPickerRow(_ dev: InputDeviceRow) -> some View {
        let selected = model.isInputSelected(dev.uid)
        let selectable = selected || !model.inputSelectionAtCap
        return Button {
            model.toggleInput(dev.uid)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Image(systemName: dev.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(dev.name).lineLimit(1)
                        if dev.isSystemDefault { Tag("Default") }
                    }
                }
                Spacer(minLength: 4)
                Text(dev.rateLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .opacity(selectable ? 1 : 0.4)
    }

    private func selectedMicRow(_ uid: String) -> some View {
        let dev = model.inputDevice(uid)
        let missing = dev == nil
        return HStack(spacing: 8) {
            Image(systemName: model.symbol(for: .input(uid)))
                .foregroundStyle(missing ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            Text(model.displayName(.input(uid))).lineLimit(1)
                .foregroundStyle(missing ? .secondary : .primary)
            if missing {
                Text("Not connected").font(.caption2).foregroundStyle(.orange)
                    .help("This device is unplugged or disconnected. Its channel is silent and resumes automatically when it reconnects.")
            } else if let dev {
                if dev.isBluetooth { Tag("Bluetooth") }
                Text(dev.rateLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.toggleInput(uid)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this microphone")
        }
        .padding(.vertical, 3)
    }

    /// Classic Bluetooth cannot carry stereo playback and a microphone at the
    /// same time: opening the headset's mic switches it to the hands-free
    /// profile (mono, 16/24 kHz). Say so plainly and offer the one-click fix.
    @ViewBuilder private var bluetoothNotice: some View {
        let degrading = model.bluetoothMicsDegradingOutput
        if let mic = degrading.first {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("\(mic.name) plays in mono while its mic is in use.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let alt = model.stereoFriendlyMic {
                    Button("Use \(alt.name) instead (keeps stereo)") {
                        model.replaceBluetoothMics(with: alt)
                    }
                    .controlSize(.small)
                    .disabled(sourcesLocked)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
        }
    }

    private var sourcesLocked: Bool { model.isRecording }
}

/// Small capsule label ("Default", "Bluetooth").
private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}
