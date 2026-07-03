// MixerPane.swift
// Logic-style mixer drawer, toggled with the X key: one channel strip per
// source (each tapped app / the system tap / the input device). Each strip has
// a vertical fader (⌘-click resets to 0 dB), a stereo meter, a click-to-edit
// dB readout, pan, and mute. An Output (master) strip is pinned at the right
// edge, outside the horizontal scroller: final-mix meter, monitor destination
// and monitor level.

import SwiftUI
import AppKit

struct MixerPane: View {
    @Bindable var model: AppModel

    var body: some View {
        // The output strip defines the drawer height (all strips share the
        // same fixed row layout); the source area hugs it via the outer
        // fixedSize so the drawer never balloons to the window height.
        HStack(alignment: .center, spacing: 0) {
            if model.mixSources.isEmpty {
                Text("Select a source (an app, System audio, or an input) to mix.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 1) {
                        ForEach(model.mixSources, id: \.self) { src in
                            ChannelStrip(model: model, kind: src)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                Spacer(minLength: 0)
            }

            // Output strip: always visible, pinned at the trailing edge.
            OutputStrip(model: model)
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        // Hug the strips' height so the drawer has no empty band above
        // (or below) the channel cards.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.03))
    }
}

/// The master strip: final-mix stereo meter, monitor-level fader, and the
/// monitor destination (Off / Bus n). Layout mirrors ChannelStrip so the two
/// kinds of strips line up row for row.
private struct OutputStrip: View {
    @Bindable var model: AppModel

    /// Monitor bus to re-enable when MON is toggled back on.
    @State private var lastBus = 0

    private var monitorOn: Bool { model.monitorBusIndex != nil }

    var body: some View {
        VStack(spacing: 6) {
            // Title
            VStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                Text("Output")
                    .font(.caption2).lineLimit(1)
                    .frame(width: 76)
            }
            .frame(height: 40)

            // Monitor-level fader + final-mix meter. The meter always shows the
            // full mix; the fader only scales the speaker pass-through.
            HStack(alignment: .center, spacing: 8) {
                FaderView(
                    value: Binding(get: { model.monitorGainDB },
                                   set: { model.setMonitorGain($0) }),
                    range: -40...12)
                    .opacity(monitorOn ? 1 : 0.55)
                StereoMeterView(meter: model.mixMeter, hold: model.mixHold, height: 140)
            }

            // Monitor destination (pan-row slot in ChannelStrip)
            VStack(spacing: 1) {
                Picker("", selection: Binding(
                    get: { model.monitorBusIndex ?? -1 },
                    set: { model.setMonitorBus($0 < 0 ? nil : $0) })) {
                    Text("Off").tag(-1)
                    ForEach(0..<model.busCount, id: \.self) { b in
                        Text("Bus \(b + 1)").tag(b)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                Text("Monitor").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(width: 76)

            // dB row: editable monitor gain + live mix level.
            HStack(spacing: 6) {
                DBValueField(
                    value: Binding(get: { model.monitorGainDB },
                                   set: { model.setMonitorGain($0) }),
                    range: -40...12, width: ChannelStrip.cellW)
                LevelReadout(db: model.mixMeter?.peakDB ?? -.infinity,
                             width: ChannelStrip.cellW)
            }

            // MON toggle (M/S-row slot): speaker pass-through on/off (F-M1).
            Button {
                model.setMonitorBus(monitorOn ? nil : lastBus)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "headphones").font(.system(size: 10))
                    Text("MON").font(.caption).fontWeight(.bold)
                }
                .frame(width: ChannelStrip.cellW * 2 + 6, height: 20)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(monitorOn ? Color.green : Color.primary.opacity(0.08)))
                .foregroundStyle(monitorOn ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(monitorOn ? "Stop monitoring" : "Monitor the selected bus on your speakers")
            .onChange(of: model.monitorBusIndex) { _, new in
                if let b = new { lastBus = b }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

/// One Logic-style channel strip: name/icon, fader + stereo meter, editable dB
/// readout, pan, mute.
private struct ChannelStrip: View {
    @Bindable var model: AppModel
    let kind: SourceKind

    /// Shared cell width for the dB readouts and the M/S buttons so the two
    /// rows line up as a 2-column grid.
    static let cellW: CGFloat = 42

    var body: some View {
        VStack(spacing: 6) {
            // Title
            VStack(spacing: 3) {
                icon
                Text(model.displayName(kind))
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
                    .frame(width: 76)
            }
            .frame(height: 40)

            // Fader + meter
            HStack(alignment: .center, spacing: 8) {
                FaderView(
                    value: Binding(get: { model.gainDB(kind) },
                                   set: { model.setGain(kind, $0) }),
                    range: -40...12)
                StereoMeterView(meter: model.sourceMeter(kind),
                                hold: model.sourceHold(kind), height: 140)
            }
            .opacity(model.effectiveMuted(kind) ? 0.55 : 1)

            // Pan
            VStack(spacing: 1) {
                Slider(value: Binding(get: { Double(model.pan(kind)) },
                                      set: { model.setPan(kind, Float($0)) }),
                       in: -1...1)
                    .controlSize(.mini)
                Text(panLabel).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(width: 76)

            // dB — two columns above M/S (same widths so they line up): left =
            // fader (slider) value (editable), right = current live level.
            HStack(spacing: 6) {
                DBValueField(
                    value: Binding(get: { model.gainDB(kind) },
                                   set: { model.setGain(kind, $0) }),
                    range: -40...12, width: Self.cellW)
                LevelReadout(db: model.sourceMeter(kind)?.peakDB ?? -.infinity, width: Self.cellW)
            }

            // Mute + Solo
            HStack(spacing: 6) {
                muteButton
                soloButton
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var muteButton: some View {
        Button {
            model.setMute(kind, !model.isMuted(kind))
        } label: {
            toggleLabel("M", on: model.isMuted(kind), onColor: .orange, onText: .white)
        }
        .buttonStyle(.plain)
        .help(model.isMuted(kind) ? "Unmute" : "Mute")
    }

    private var soloButton: some View {
        Button {
            model.setSolo(kind, !model.isSoloed(kind))
        } label: {
            toggleLabel("S", on: model.isSoloed(kind), onColor: .yellow, onText: .black)
        }
        .buttonStyle(.plain)
        .help(model.isSoloed(kind) ? "Unsolo" : "Solo (silence the others)")
    }

    /// A compact toggle chip sized exactly like the dB readouts above it.
    private func toggleLabel(_ text: String, on: Bool,
                             onColor: Color, onText: Color) -> some View {
        Text(text)
            .font(.caption).fontWeight(.bold)
            .frame(width: Self.cellW, height: 20)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(on ? onColor : Color.primary.opacity(0.08)))
            .foregroundStyle(on ? onText : Color.secondary)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .system:
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 14)).foregroundStyle(.secondary)
        case .app:
            if let img = model.icon(for: kind) {
                Image(nsImage: img).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        case .input:
            Image(systemName: "mic.fill").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private var panLabel: String {
        let p = model.pan(kind)
        if abs(p) < 0.02 { return "C" }
        return p < 0 ? String(format: "L%.0f", -p * 100) : String(format: "R%.0f", p * 100)
    }
}

/// Vertical fader. Drag to set; ⌘-click (or ⌘-drag start) resets to 0 dB.
private struct FaderView: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    private let width: CGFloat = 22
    private let capHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(width: width)
                // 0 dB tick
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: width, height: 1)
                    .offset(y: y(for: 0, height: h))
                // Cap
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25)))
                    .overlay(Rectangle().fill(Color.primary.opacity(0.4)).frame(height: 1))
                    .frame(width: width, height: capHeight)
                    .offset(y: y(for: value, height: h) - capHeight / 2)
                    .shadow(radius: 1, y: 1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if NSEvent.modifierFlags.contains(.command) {
                            value = 0    // ⌘-click / ⌘-drag: reset to 0 dB
                            return
                        }
                        value = dB(atY: g.location.y, height: h)
                    }
            )
        }
        .frame(width: width, height: 140)
    }

    /// Cap center Y for a dB value (top == max, bottom == min).
    private func y(for db: Float, height: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let frac = (max(range.lowerBound, min(range.upperBound, db)) - range.lowerBound) / span
        return (1 - CGFloat(frac)) * (height - capHeight) + capHeight / 2
    }

    private func dB(atY yPos: CGFloat, height: CGFloat) -> Float {
        let usable = max(1, height - capHeight)
        let frac = 1 - (yPos - capHeight / 2) / usable
        let clamped = Float(min(1, max(0, frac)))
        let span = range.upperBound - range.lowerBound
        // Snap near 0 dB so the reset position is easy to hit by hand too.
        let db = range.lowerBound + clamped * span
        return abs(db) < 0.25 ? 0 : db
    }
}

/// dB readout that turns into a text field on click (commit with Return,
/// cancel with Esc).
private struct DBValueField: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var width: CGFloat = 60

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: width)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { commit() }
                    }
            } else {
                Text(value.isFinite ? String(format: "%+.1f", value) : "−∞")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        text = String(format: "%.1f", value)
                        editing = true
                        focused = true
                    }
                    .help("Fader value (dB) — click to type a value")
            }
        }
    }

    private func commit() {
        defer { editing = false }
        let cleaned = text
            .replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Float(cleaned) else { return }
        value = max(range.lowerBound, min(range.upperBound, v))
    }
}

/// Read-only live level readout (dBFS), colored by meter zone. Sits to the right
/// of the editable fader value; shows the current peak the strip's meter reflects.
private struct LevelReadout: View {
    let db: Float
    var width: CGFloat = 60

    var body: some View {
        Text(db.isFinite ? String(format: "%.1f", db) : "−∞")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(db.isFinite ? Meter.color(db) : .secondary)
            .frame(width: width, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
            .help("Current level (dBFS)")
    }
}
