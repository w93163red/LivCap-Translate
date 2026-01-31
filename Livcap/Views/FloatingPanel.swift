//
//  FloatingPanel.swift
//  Livcap
//
//  Non-activating NSPanel for the overlay caption display.
//  Clicking this panel does not activate the app or bring other windows forward.
//

import SwiftUI
import AppKit

final class FloatingPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces]
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
    }

    /// Ensure the panel becomes key on mouse interaction so resize drag works.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// Position the panel at the bottom center of the focused screen.
    func positionAtBottom() {
        let screen = getFocusedScreen()
        let width = screen.frame.width * 0.618
        let height: CGFloat = 80
        let x = screen.frame.minX + (screen.frame.width - width) / 2
        let y = calculateYPositionAboveDock(screen: screen, windowHeight: height)
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

    private func calculateYPositionAboveDock(screen: NSScreen, windowHeight: CGFloat) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        let dockHeight = screen.frame.height - visibleFrame.height
        if dockHeight > 0 {
            return visibleFrame.minY + 10
        }
        return screen.frame.minY + 20
    }
}
