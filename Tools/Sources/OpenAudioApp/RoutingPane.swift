// RoutingPane.swift
// Pane 2 (F-U1): node-graph routing view. Source nodes on the left, bus nodes on
// the right, edges for active routes drawn with a Canvas. Every possible edge
// carries a midpoint toggle so a first-time user can wire source→bus by clicking.
// Buses can be added (control plane + engine attach) / removed, and each bus has
// a headphones monitor toggle (F-M1) and a mini level meter.

import SwiftUI

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

    private var sources: [SourceKind] {
        var s: [SourceKind] = []
        if model.tapActive { s.append(.tap) }
        if model.inputActive { s.append(.input) }
        return s
    }

    // MARK: Header controls (bus add/remove + monitor level)

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Buses").font(.subheadline).foregroundStyle(.secondary)
                Button { attemptRemove() } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busCount <= 1 || model.busOpInProgress)
                Text("\(model.busCount)").font(.subheadline).monospacedDigit().frame(minWidth: 16)
                Button { model.addBus() } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busCount >= model.maxBuses || model.busOpInProgress)
                if model.busOpInProgress { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }
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
            // Edges.
            Canvas { ctx, _ in
                for (si, src) in sources.enumerated() {
                    for bi in 0..<model.busCount {
                        guard si < srcPts.count, bi < busPts.count else { continue }
                        let a = CGPoint(x: srcPts[si].x + nodeW / 2, y: srcPts[si].y)
                        let b = CGPoint(x: busPts[bi].x - nodeW / 2, y: busPts[bi].y)
                        var path = Path()
                        path.move(to: a)
                        path.addCurve(to: b,
                                      control1: CGPoint(x: (a.x + b.x) / 2, y: a.y),
                                      control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                        let active = model.isRouted(src, bus: bi)
                        ctx.stroke(path,
                                   with: .color(active ? Color.accentColor : Color.secondary.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: active ? 2.5 : 1.2,
                                                      dash: active ? [] : [4, 4]))
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
            Label(nodeTitle(src), systemImage: src == .tap ? "waveform" : "mic.fill")
                .font(.caption).lineLimit(1)
            MiniMeterView(peakDB: meter?.peakDB ?? -.infinity, width: 92)
        }
        .frame(width: nodeW, height: nodeH)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))
    }

    private func busNode(_ bus: Int) -> some View {
        let monitoring = model.monitorBusIndex == bus
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(busName(bus)).font(.caption).lineLimit(1)
                Spacer()
                Button { model.toggleMonitor(bus: bus) } label: {
                    Image(systemName: monitoring ? "headphones.circle.fill" : "headphones")
                        .foregroundStyle(monitoring ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(monitoring ? "Monitoring on this bus" : "Monitor this bus on your output")
            }
            MiniMeterView(peakDB: model.busPeakDB(bus), width: 92)
        }
        .padding(.horizontal, 8)
        .frame(width: nodeW, height: nodeH)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(monitoring ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(monitoring ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10)))
    }

    private func nodeTitle(_ src: SourceKind) -> String {
        switch src {
        case .tap:
            if model.useSystemAudio { return "System" }
            let n = model.selectedPIDs.count
            return n == 1 ? "1 app" : "\(n) apps"
        case .input:
            return model.inputSelection.label
        }
    }

    /// Bus 1 == "OpenAudio 16ch"; bus n≥2 == "OpenAudio 16ch n" (mirrors the driver naming).
    private func busName(_ index: Int) -> String {
        index == 0 ? "OpenAudio 16ch" : "OpenAudio 16ch \(index + 1)"
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
