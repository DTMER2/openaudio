// SourcesPane.swift
// Pane 1 (F-U3 / F-U5): choose capture sources (system audio or specific running
// applications, plus an optional real input device). Rows show the app icon and
// a friendly name; user-facing apps sort above daemons. Per-source levels live
// in the mixer drawer (X key), not here.

import SwiftUI
import AppKit

struct SourcesPane: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Sources", systemImage: "waveform")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    systemToggle
                    processList
                    inputPicker
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
            Text("Capture everything playing on this Mac. Turn off to pick specific apps below.")
                .font(.caption).foregroundStyle(.secondary)
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
                Text("Up to \(model.maxSelectableApps) apps can be captured at once.")
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

    // MARK: Input device

    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input device").font(.headline)
            Picker("", selection: Binding(get: { model.inputSelection },
                                          set: { model.inputSelection = $0 })) {
                Text("None").tag(InputSelection.none)
                Text("Default input").tag(InputSelection.systemDefault)
                ForEach(model.inputDevices, id: \.uid) { dev in
                    Text(dev.name).tag(InputSelection.device(uid: dev.uid, name: dev.name))
                }
            }
            .labelsHidden()
            .disabled(sourcesLocked)
            Text("Optionally mix in a microphone or audio interface.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourcesLocked: Bool { model.isRecording }
}
