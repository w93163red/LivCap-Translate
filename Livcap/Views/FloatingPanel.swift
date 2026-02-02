//
//  FloatingPanel.swift
//  Livcap
//
//  Borderless NSPanel for the overlay caption display.
//  Visible in Mission Control and Alt-Tab window switchers.
//

import SwiftUI
import AppKit

final class FloatingPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        // Use nearly-transparent background so the entire window area captures mouse events
        // (fully clear background causes clicks in transparent areas to pass through)
        backgroundColor = NSColor(white: 0, alpha: 0.005)
        hasShadow = false
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true

        minSize = NSSize(width: 400, height: 45)
        maxSize = NSSize(width: 2000, height: 800)

        let hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView

        // Persist window frame across launches
        setFrameAutosaveName("LivcapOverlayPanel")
    }

    /// Ensure the panel becomes key on mouse interaction so resize drag works.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// Position the panel at the lower-third center of the focused screen (subtitle-style).
    func positionDefault() {
        let screen = getFocusedScreen()
        let visibleFrame = screen.visibleFrame
        let width = visibleFrame.width * 0.618
        let height: CGFloat = 80
        let x = visibleFrame.minX + (visibleFrame.width - width) / 2
        let y = visibleFrame.minY + visibleFrame.height * 0.25 - height / 2
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func getFocusedScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}
