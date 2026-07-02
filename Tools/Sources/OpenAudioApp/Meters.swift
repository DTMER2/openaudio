// Meters.swift
// Reusable live level meters (F-U4 / F-E4). All readings are dBFS with a -∞
// floor; fill maps through Meter.fraction and paints the green→yellow→red
// gradient. Peak is drawn as a bright hold line over the RMS fill.

import SwiftUI
import OpenAudioEngine

/// A vertical stereo (L/R) meter used in the source strips.
struct StereoMeterView: View {
    var meter: StereoMeter?
    var height: CGFloat = 120

    var body: some View {
        HStack(spacing: 3) {
            channel(peak: meter?.peakL ?? -.infinity, rms: meter?.rmsL ?? -.infinity)
            channel(peak: meter?.peakR ?? -.infinity, rms: meter?.rmsR ?? -.infinity)
        }
        .frame(height: height)
        .overlay(alignment: .trailing) { scale }
    }

    private func channel(peak: Float, rms: Float) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.08))
                // RMS fill.
                Meter.gradient
                    .mask(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(height: max(1, h * Meter.fraction(rms)))
                    }
                // Peak hold line.
                Rectangle()
                    .fill(Meter.color(peak))
                    .frame(height: 2)
                    .offset(y: -(h * Meter.fraction(peak)) + 1)
                    .opacity(peak.isFinite ? 1 : 0)
            }
        }
        .frame(width: 10)
    }

    private var scale: some View {
        VStack {
            Text("0").font(.system(size: 7)).foregroundStyle(.secondary)
            Spacer()
            Text("-24").font(.system(size: 7)).foregroundStyle(.secondary)
            Spacer()
            Text("-60").font(.system(size: 7)).foregroundStyle(.secondary)
        }
        .offset(x: 16)
        .allowsHitTesting(false)
    }
}

/// A compact horizontal meter (bus nodes, menu bar). Shows peak fill only.
struct MiniMeterView: View {
    var peakDB: Float
    var width: CGFloat = 60
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Meter.gradientH
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(0, geo.size.width * Meter.fraction(peakDB)))
                    }
            }
        }
        .frame(width: width, height: height)
    }
}
