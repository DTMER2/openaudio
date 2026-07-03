// RoutingPane.swift
// Pane 2 (F-U1): node-graph routing view. Source nodes on the left, bus nodes on
// the right, edges for active routes drawn with a Canvas. Every possible edge
// carries a midpoint toggle so a first-time user can wire source→bus by clicking.
// Buses can be added (control plane + engine attach) / removed, and each bus has
// a headphones monitor toggle (F-M1) and a mini level meter.

import SwiftUI
import AppKit
import OpenAudioEngine

struct RoutingPane: View {
    @Bindable var model: AppModel
    @State private var confirmRemove = false

    // Fixed node geometry.
    private let nodeW: CGFloat = 128
    private let nodeH: CGFloat = 54
    private let vGap: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Routing", systemImage: "point.3.connected.trianglepath.dotted")
            header
            GeometryReader { geo in graph(in: geo.size) }
                .padding(14)
        }
        .confirmationDialog("Remove the last bus?", isPresented: $confirmRemove) {
            Button("Remove bus \(model.busCount)", role: .destructive) { model.removeLastBus() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bus \(model.busCount) is routed or being monitored. Removing it will drop those connections.")
        }
    }

    /// One node per source: the system tap OR each selected app, plus input.
    private var sources: [SourceKind] { model.mixSources }

    // MARK: Header controls (bus add/remove + monitor level)

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Buses").font(.subheadline).foregroundStyle(.secondary)
                Button { attemptRemove() } label: {
                    Image(systemName: "minus").frame(width: 12, height: 12)
                }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busCount <= 1 || model.busOpInProgress)
                Text("\(model.busCount)").font(.subheadline).monospacedDigit().frame(minWidth: 16)
                Button { model.addBus() } label: {
                    Image(systemName: "plus").frame(width: 12, height: 12)
                }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busCount >= model.maxBuses || model.busOpInProgress)
                if model.busOpInProgress { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }
            Picker("", selection: Binding(get: { model.outputMode },
                                          set: { model.setOutputMode($0) })) {
                Text("Devices").tag(BusOutputMode.separateDevices)
                Text("16ch (DAW)").tag(BusOutputMode.single16ch)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 190)
            .disabled(model.isRecording || model.busOpInProgress)
            .help("Devices: each bus is its own stereo output device. " +
                  "16ch (DAW): every bus lands on a channel pair of the single " +
                  "\"OpenAudio\" device, so a DAW records all buses through one input device.")
            Spacer()
            if model.monitorBusIndex != nil {
                HStack(spacing: 6) {
                    Image(systemName: "headphones").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.monitorGainDB) },
                                          set: { model.setMonitorGain(Float($0)) }),
                           in: -24...6)
                        .frame(width: 120).controlSize(.small)
                    Text(Fmt.dB(model.monitorGainDB)).font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 6)
    }

    private func attemptRemove() {
        if model.lastBusIsInUse { confirmRemove = true } else { model.removeLastBus() }
    }

    // MARK: Graph

    private func graph(in size: CGSize) -> some View {
        let leftX = nodeW / 2 + 8
        let rightX = size.width - nodeW / 2 - 8
        let srcPts = columnPoints(count: sources.count, x: leftX, height: size.height)
        let busPts = columnPoints(count: model.busCount, x: rightX, height: size.height)

        return ZStack {
            // Edges (visual).
            Canvas { ctx, _ in
                for (si, src) in sources.enumerated() {
                    for bi in 0..<model.busCount {
                        guard si < srcPts.count, bi < busPts.count else { continue }
                        let a = CGPoint(x: srcPts[si].x + nodeW / 2, y: srcPts[si].y)
                        let b = CGPoint(x: busPts[bi].x - nodeW / 2, y: busPts[bi].y)
                        let active = model.isRouted(src, bus: bi)
                        ctx.stroke(edgePath(a, b),
                                   with: .color(active ? Color.accentColor : Color.secondary.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: active ? 2.5 : 1.2,
                                                      dash: active ? [] : [4, 4]))
                    }
                }
            }

            // Edge hit areas: the whole line is clickable, so overlapping toggles at
            // the graph centre never block a connection — click any clear stretch.
            ForEach(Array(sources.enumerated()), id: \.offset) { si, src in
                ForEach(0..<model.busCount, id: \.self) { bi in
                    if si < srcPts.count && bi < busPts.count {
                        let a = CGPoint(x: srcPts[si].x + nodeW / 2, y: srcPts[si].y)
                        let b = CGPoint(x: busPts[bi].x - nodeW / 2, y: busPts[bi].y)
                        let shape = EdgeShape(a: a, b: b)
                        shape.strokedHit(width: 14)
                            .onTapGesture { model.toggleRoute(src, bus: bi) }
                            .help(model.isRouted(src, bus: bi) ? "Disconnect" : "Connect")
                    }
                }
            }

            // Edge midpoint toggles.
            ForEach(Array(sources.enumerated()), id: \.offset) { si, src in
                ForEach(0..<model.busCount, id: \.self) { bi in
                    if si < srcPts.count && bi < busPts.count {
                        let mid = CGPoint(x: (srcPts[si].x + busPts[bi].x) / 2,
                                          y: (srcPts[si].y + busPts[bi].y) / 2)
                        edgeToggle(src, bi).position(mid)
                    }
                }
            }

            // Source nodes.
            ForEach(Array(sources.enumerated()), id: \.offset) { si, src in
                if si < srcPts.count { sourceNode(src).position(srcPts[si]) }
            }
            // Bus nodes.
            ForEach(0..<model.busCount, id: \.self) { bi in
                if bi < busPts.count { busNode(bi).position(busPts[bi]) }
            }
        }
    }

    private func columnPoints(count: Int, x: CGFloat, height: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        let slot = height / CGFloat(count)
        return (0..<count).map { CGPoint(x: x, y: slot * (CGFloat($0) + 0.5)) }
    }

    /// The cubic used both for drawing and hit-testing an edge (control points
    /// pulled horizontally to the midpoint x).
    private func edgePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let mx = (a.x + b.x) / 2
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        return p
    }

    private func edgeToggle(_ src: SourceKind, _ bus: Int) -> some View {
        let on = model.isRouted(src, bus: bus)
        return Button { model.toggleRoute(src, bus: bus) } label: {
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 16))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        }
        .buttonStyle(.plain)
        .help(on ? "Disconnect" : "Connect")
    }

    private func sourceNode(_ src: SourceKind) -> some View {
        let meter = model.sourceMeter(src)
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                sourceIcon(src)
                Text(model.displayName(src)).font(.caption).lineLimit(1)
            }
            StereoMiniMeterView(peakL: meter?.peakL ?? -.infinity,
                                peakR: meter?.peakR ?? -.infinity,
                                hold: model.sourceHold(src), width: 92)
        }
        .frame(width: nodeW, height: nodeH)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))
    }

    @ViewBuilder private func sourceIcon(_ src: SourceKind) -> some View {
        switch src {
        case .system:
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        case .app:
            if let icon = model.icon(for: src) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.caption).foregroundStyle(.secondary)
            }
        case .input:
            Image(systemName: "mic.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func busNode(_ bus: Int) -> some View {
        let monitoring = model.monitorBusIndex == bus
        let stereo = model.busStereo(bus)
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(nsImage: AppIcon.image)
                    .resizable().frame(width: 16, height: 16)
                Text(busName(bus)).font(.caption).lineLimit(1)
            }
            StereoMiniMeterView(peakL: stereo.l, peakR: stereo.r,
                                hold: model.busHold(bus), width: 92)
        }
        .padding(.horizontal, 8)
        .frame(width: nodeW, height: nodeH)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(monitoring ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(monitoring ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10)))
    }

    /// Separate devices: "OpenAudio" / "OpenAudio n" (device names). Single
    /// 16ch: the channel pair the bus occupies on the one device.
    private func busName(_ index: Int) -> String {
        switch model.outputMode {
        case .single16ch:      return "Ch \(index * 2 + 1)-\(index * 2 + 2)"
        case .separateDevices: return index == 0 ? "OpenAudio" : "OpenAudio \(index + 1)"
        }
    }
}

/// The routing edge curve as a `Shape`, so its stroked outline can serve as a
/// generous, precise click target that follows the whole line.
private struct EdgeShape: Shape {
    let a: CGPoint
    let b: CGPoint
    func path(in rect: CGRect) -> Path {
        let mx = (a.x + b.x) / 2
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        return p
    }

    /// A transparent, hit-testable band tracing the line at the given width.
    func strokedHit(width: CGFloat) -> some View {
        stroke(style: StrokeStyle(lineWidth: width, lineCap: .round))
            .fill(Color.clear)
            .contentShape(stroke(style: StrokeStyle(lineWidth: width, lineCap: .round)))
    }
}

/// Shared pane header styling.
struct PaneHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        Divider()
    }
}
