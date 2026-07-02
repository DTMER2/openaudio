// SourcesPane.swift
// Pane 1 (F-U3 / F-U5): choose capture sources (system audio or specific running
// processes, plus an optional real input device), and adjust per-source
// gain / pan / mute with live L/R meters.

import SwiftUI

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
                    Divider()
                    strips
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
        }
    }

    private func processRow(_ row: ProcRow) -> some View {
        Button {
            model.toggleProcess(pid: row.pid)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isSelected(pid: row.pid) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(model.isSelected(pid: row.pid) ? Color.accentColor : .secondary)
                Circle()
                    .fill(row.isRunningOutput ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(row.isRunningOutput ? "Currently playing" : "Idle")
                Text(row.name).lineLimit(1)
                Spacer()
                Text("pid \(row.pid)").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private var filteredProcesses: [ProcRow] {
        let base = model.processes
        guard !search.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(search)
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

    // MARK: Source strips (F-U5)

    @ViewBuilder private var strips: some View {
        Text("Levels").font(.headline)
        HStack(alignment: .top, spacing: 18) {
            if model.tapActive {
                SourceStrip(model: model, kind: .tap, title: tapTitle, icon: "waveform")
            }
            if model.inputActive {
                SourceStrip(model: model, kind: .input, title: model.inputSelection.label, icon: "mic.fill")
            }
            if !model.tapActive && !model.inputActive {
                Text("Choose a source above to see its level and controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tapTitle: String {
        if model.useSystemAudio { return "System" }
        let n = model.selectedPIDs.count
        return n == 1 ? "1 app" : "\(n) apps"
    }

    private var sourcesLocked: Bool { model.isRecording }
}

/// One mixer strip: title, meter, gain, pan, mute.
struct SourceStrip: View {
    @Bindable var model: AppModel
    let kind: SourceKind
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption).lineLimit(1)
                .frame(maxWidth: 120)

            StereoMeterView(meter: model.sourceMeter(kind), height: 130)
                .frame(width: 46)

            // Gain -40…+12 dB
            VStack(spacing: 2) {
                Slider(value: gainBinding, in: -40...12)
                    .controlSize(.small)
                Text(Fmt.dB(gainValue)).font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 110)

            // Pan -1…+1
            VStack(spacing: 2) {
                Slider(value: panBinding, in: -1...1) {
                    Text("Pan")
                } minimumValueLabel: { Text("L").font(.caption2) }
                  maximumValueLabel: { Text("R").font(.caption2) }
                    .controlSize(.small)
                Text(panLabel).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 110)

            Button {
                model.setMute(kind, !muted)
            } label: {
                Label("Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(muted ? .red : .accentColor)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var muted: Bool { kind == .tap ? model.tapMuted : model.inputMuted }
    private var gainValue: Float { kind == .tap ? model.tapGainDB : model.inputGainDB }
    private var panValue: Float { kind == .tap ? model.tapPan : model.inputPan }

    private var gainBinding: Binding<Double> {
        Binding(get: { Double(gainValue) }, set: { model.setGain(kind, Float($0)) })
    }
    private var panBinding: Binding<Double> {
        Binding(get: { Double(panValue) }, set: { model.setPan(kind, Float($0)) })
    }
    private var panLabel: String {
        let p = panValue
        if abs(p) < 0.02 { return "Center" }
        return p < 0 ? String(format: "L %.0f%%", -p * 100) : String(format: "R %.0f%%", p * 100)
    }
}
