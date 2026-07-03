// MainWindowView.swift
// The main window (F-U1..U5): Sources | Routing graph, an optional Logic-style
// mixer drawer that slides up from the bottom (X key), and the one-click
// transport. A 1 Hz TimelineView drives the recording clock without coupling
// it to meter polling.

import SwiftUI
import AppKit

struct MainWindowView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                BottomBar(model: model, now: ctx.date)
            }

            Divider()

            HSplitView {
                // Sources opens at its minimum width; extra window width goes
                // to the routing graph (still user-draggable up to maxWidth).
                SourcesPane(model: model)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                RoutingPane(model: model)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            // The mixer floats as a drawer over the bottom of the content so it
            // never reflows / resizes the routing graph underneath it.
            .overlay(alignment: .bottom) {
                if model.mixerVisible {
                    VStack(spacing: 0) {
                        Divider()
                        MixerPane(model: model)
                    }
                    // Opaque so the routing graph doesn't bleed through the
                    // drawer — the boundary reads as a single top line.
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.mixerVisible)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            model.setWindowVisible(true)
            installKeyMonitor()
        }
        .onDisappear {
            model.setWindowVisible(false)
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    /// Logic-style bare-key shortcut: X toggles the mixer drawer. Implemented
    /// as a local event monitor (not a menu key equivalent) so typing "x" in
    /// the search field / dB fields keeps working — text editing is detected
    /// via the field editor being first responder.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "x",
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window, window.isKeyWindow,
                  !(window.firstResponder is NSText)
            else { return event }
            model.mixerVisible.toggle()
            return nil
        }
    }
}
