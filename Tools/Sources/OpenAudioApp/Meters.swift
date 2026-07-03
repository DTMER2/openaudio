// Meters.swift
// Reusable live level meters (F-U4 / F-E4). All readings are dBFS with a -∞
// floor; fill maps through Meter.fraction and paints the green→yellow→red
// gradient. Peak is drawn as a bright hold line over the RMS fill.

import SwiftUI
import OpenAudioEngine

/// A vertical stereo (L/R) meter used in the mixer strips. The bar fills to the
/// current peak (so it rides up to the transients, not the much lower RMS), and
/// a peak-hold line sits at the max and slowly falls.
struct StereoMeterView: View {
    var meter: StereoMeter?
    var hold: PeakHold = PeakHold()
    var height: CGFloat = 120

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                channel(peak: meter?.peakL ?? -.infinity, hold: hold.l)
                channel(peak: meter?.peakR ?? -.infinity, hold: hold.r)
            }
            scale
        }
        .frame(height: height)
    }

    private func channel(peak: Float, hold: Float) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.08))
                // Level fill (to peak).
                Meter.gradient
                    .mask(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(height: max(1, h * Meter.fraction(peak)))
                    }
                // Peak-hold line.
                Rectangle()
                    .fill(Meter.color(hold))
                    .frame(height: 2)
                    .offset(y: -(h * Meter.fraction(hold)) + 1)
                    .opacity(hold.isFinite ? 1 : 0)
            }
        }
        .frame(width: 10)
    }

    private var scale: some View {
        VStack(spacing: 0) {
            Text("0")
            Spacer()
            Text("-24")
            Spacer()
            Text("-60")
        }
        .font(.system(size: 7)).foregroundStyle(.secondary)
        .frame(width: 20)
        .allowsHitTesting(false)
    }
}

/// Compact horizontal stereo meter for the routing nodes: L over R, each filled
/// to peak with a peak-hold tick that rides the maximum and slowly falls.
struct StereoMiniMeterView: View {
    var peakL: Float
    var peakR: Float
    var hold: PeakHold = PeakHold()
    var width: CGFloat = 92

    var body: some View {
        VStack(spacing: 2) {
            bar(peak: peakL, hold: hold.l)
            bar(peak: peakR, hold: hold.r)
        }
        .frame(width: width)
    }

    private func bar(peak: Float, hold: Float) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Meter.gradientH
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(0, w * Meter.fraction(peak)))
                    }
                Rectangle()
                    .fill(Meter.color(hold))
                    .frame(width: 2)
                    .offset(x: max(0, w * Meter.fraction(hold) - 1))
                    .opacity(hold.isFinite ? 1 : 0)
            }
        }
        .frame(height: 5)
    }
}

/// A compact horizontal meter (menu bar). Shows peak fill only.
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
