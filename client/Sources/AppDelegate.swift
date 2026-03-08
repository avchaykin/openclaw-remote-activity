import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var activityMonitor: ActivityMonitor!
    private var popover: NSPopover!
    private var animationTimer: Timer?
    private var isBlinkOn = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        activityMonitor = ActivityMonitor()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create popover for details
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(monitor: activityMonitor)
        )

        updateIcon()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Build menu
        setupMenu()

        // Observe state changes
        activityMonitor.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.handleStateChange()
            }
        }

        // Start monitoring
        activityMonitor.start()
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "OpenClaw Activity", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let detailsItem = NSMenuItem(title: "Show Details...", action: #selector(showDetails), keyEquivalent: "d")
        detailsItem.target = self
        menu.addItem(detailsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Right-click shows menu, left-click shows popover
        statusItem.menu = nil
    }

    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Ensure popover is focused
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    @objc private func showDetails() {
        togglePopover()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleStateChange() {
        let wasActive = animationTimer != nil
        let isActive = activityMonitor.state.active

        if isActive && !wasActive {
            startBlinking()
        } else if !isActive && wasActive {
            stopBlinking()
        }

        updateIcon()
    }

    private func startBlinking() {
        animationTimer?.invalidate()
        isBlinkOn = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.isBlinkOn.toggle()
            self?.updateIcon()
        }
    }

    private func stopBlinking() {
        animationTimer?.invalidate()
        animationTimer = nil
        isBlinkOn = true
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let isActive = activityMonitor.state.active
        let isConnected = activityMonitor.state.connected

        if !isConnected {
            // Disconnected — yellow dot
            button.image = createDotImage(color: .systemYellow, filled: true)
            button.toolTip = "OpenClaw: disconnected from server"
        } else if isActive {
            // Active — red dot (blinking)
            let color: NSColor = isBlinkOn ? .systemRed : .systemRed.withAlphaComponent(0.3)
            button.image = createDotImage(color: color, filled: true)
            let count = activityMonitor.state.summary.activeSessions
            button.toolTip = "OpenClaw: \(count) active session\(count == 1 ? "" : "s")"
        } else {
            // Idle — gray dot
            button.image = createDotImage(color: .systemGray, filled: true)
            button.toolTip = "OpenClaw: idle"
        }
    }

    private func createDotImage(color: NSColor, filled: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(x: 5, y: 5, width: 8, height: 8)
            let path = NSBezierPath(ovalIn: dotRect)

            if filled {
                color.setFill()
                path.fill()
            }

            // Subtle border
            color.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }
}
