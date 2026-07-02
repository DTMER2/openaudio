// MainWindowView.swift
// The three-pane main window (F-U1..U5): Sources | Routing graph | (bottom) the
// one-click transport. A 1 Hz TimelineView drives the recording clock without
// coupling it to meter polling.

import SwiftUI

struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourcesPane(model: model)
                    .frame(minWidth: 320, idealWidth: 360)
                RoutingPane(model: model)
                    .frame(minWidth: 360)
            }
            .frame(maxHeight: .infinity)

            Divider()

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                BottomBar(model: model, now: ctx.date)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.setWindowVisible(true) }
        .onDisappear { model.setWindowVisible(false) }
    }
}
