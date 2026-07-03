// OpenAudioApp.swift
// SwiftUI entry point (Phase 3). A menu-bar-resident utility (LSUIElement when
// bundled): a MenuBarExtra always present (F-U6) plus the main "OpenAudio"
// window. The single AppModel is shared by both scenes. NOTE: because this uses
// @main, the file must not be named main.swift.

import SwiftUI

@main
struct OpenAudioApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("OpenAudio", id: "main") {
            MainWindowView(model: model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New" — this is a utility
            CommandGroup(after: .sidebar) {
                // The Logic-style bare X shortcut is handled by a key monitor
                // in MainWindowView (a bare-key menu equivalent would steal
                // "x" from text fields); this menu item is for discoverability.
                Button(model.mixerVisible ? "Hide Mixer" : "Show Mixer") {
                    model.mixerVisible.toggle()
                }
            }
        }

        MenuBarExtra {
            MenuBarView(model: model) {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if model.isRecording { return "record.circle.fill" }
        return model.isRunning ? "waveform.circle.fill" : "waveform"
    }
}
