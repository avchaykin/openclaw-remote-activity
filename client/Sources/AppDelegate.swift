import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var activityMonitor: ActivityMonitor!
    private var popover: NSPopover!
    private var statusMenu: NSMenu!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        activityMonitor = ActivityMonitor()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create popover for details
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 330)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(monitor: activityMonitor)
        )

        updateIcon()

        if let button = statusItem.button {
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem.menu = nil
    }

    @objc private func togglePopover() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            if let statusMenu {
                statusItem.menu = statusMenu
                statusItem.button?.performClick(nil)
                statusItem.menu = nil
            }
            return
        }

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

    @objc private func showSettings() {
        if let existingWindow = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView(monitor: activityMonitor) { [weak self] in
            self?.settingsWindow?.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenClaw Activity Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: contentView)
        window.delegate = self

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleStateChange() {
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let isActive = activityMonitor.state.active
        let isConnected = activityMonitor.state.connected

        if !isConnected {
            // Disconnected — red dot
            button.image = createDotImage(color: .systemRed, filled: true)
            button.toolTip = "OpenClaw: disconnected from server"
        } else if isActive {
            // Active — dark green dot
            button.image = createDotImage(color: .activityDarkGreen, filled: true)
            let count = activityMonitor.state.summary.activeSessions
            button.toolTip = "OpenClaw: \(count) active session\(count == 1 ? "" : "s")"
        } else {
            // Connected + idle — white dot
            button.image = createDotImage(color: .white, filled: true)
            button.toolTip = "OpenClaw: connected (idle)"
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }
}
