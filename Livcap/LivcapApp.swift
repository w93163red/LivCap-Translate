//
//  LivcapApp.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/2/25.
//

import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayPanel: FloatingPanel?
}

@main
struct LivcapApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var captionViewModel = CaptionViewModel()

    init() {
        print("App is launching... initing")
    }

    var body: some Scene {
        // Main history window (primary scene — auto-opens on launch)
        Window("Livcap - History", id: "main") {
            MainWindowView()
                .environmentObject(captionViewModel)
                .onAppear {
                    setupOverlayPanelIfNeeded()
                }
        }
        .defaultSize(width: 700, height: 500)
        .commands {
            // Remove default menu items for cleaner experience
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .systemServices) { }

            // Custom About menu item
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        // About window
        Window("About Livcap", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 400)

        // Settings window
        Settings {
            SettingsView()
        }
    }

    private func setupOverlayPanelIfNeeded() {
        guard appDelegate.overlayPanel == nil else { return }
        let content = AppRouterView()
            .environmentObject(captionViewModel)
        let panel = FloatingPanel(contentView: content)
        panel.positionAtBottom()
        panel.orderFront(nil)
        appDelegate.overlayPanel = panel
    }
}

struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Livcap") {
            openWindow(id: "about")
        }
        .keyboardShortcut("a", modifiers: .command)
    }
}
