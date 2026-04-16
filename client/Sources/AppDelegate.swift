import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var activityMonitor: ActivityMonitor!
    private var popover: NSPopover!
    private var statusMenu: NSMenu!
    private var settingsWindow: NSWindow?
    private var animationTimer: Timer?
    private var rippleStartTimes: [TimeInterval] = []
    private var lastRippleSpawnAt: TimeInterval = 0

    private let rippleDuration: TimeInterval = 0.9
    private let rippleSpawnInterval: TimeInterval = 0.75

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        activityMonitor = ActivityMonitor()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create popover for details
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 390)
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
            stopAnimation()
            // Disconnected — red dot
            button.image = createDotImage(color: .systemRed, filled: true)
            button.toolTip = "OpenClaw: disconnected from server"
        } else if isActive {
            ensureAnimationRunning()
            renderAnimatedIcon()
            let count = activityMonitor.state.summary.activeSessions
            button.toolTip = "OpenClaw: \(count) active session\(count == 1 ? "" : "s")"
        } else {
            if rippleStartTimes.isEmpty {
                stopAnimation()
            } else {
                ensureAnimationRunning()
                renderAnimatedIcon()
                return
            }
            // Connected + idle — white dot
            button.image = createDotImage(color: .white, filled: true)
            button.toolTip = "OpenClaw: connected (idle)"
        }
    }

    private func ensureAnimationRunning() {
        if animationTimer != nil { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.renderAnimatedIcon()
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        rippleStartTimes.removeAll()
        lastRippleSpawnAt = 0
    }

    private func renderAnimatedIcon() {
        guard let button = statusItem.button else { return }

        let now = Date.timeIntervalSinceReferenceDate
        let isConnected = activityMonitor.state.connected
        let isActive = activityMonitor.state.active

        if !isConnected {
            stopAnimation()
            button.image = createDotImage(color: .systemRed, filled: true)
            return
        }

        if isActive && (lastRippleSpawnAt == 0 || now - lastRippleSpawnAt >= rippleSpawnInterval) {
            rippleStartTimes.append(now)
            lastRippleSpawnAt = now
        }

        rippleStartTimes.removeAll { now - $0 > rippleDuration }
        button.image = createRippleImage(now: now, rippleStarts: rippleStartTimes, rippleColor: phaseColor())

        if !isActive && rippleStartTimes.isEmpty {
            stopAnimation()
            button.image = createDotImage(color: .white, filled: true)
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

    private func createRippleImage(now: TimeInterval, rippleStarts: [TimeInterval]) -> NSImage {
        createRippleImage(now: now, rippleStarts: rippleStarts, rippleColor: .white)
    }

    private func createRippleImage(now: TimeInterval, rippleStarts: [TimeInterval], rippleColor: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let center = NSPoint(x: 9, y: 9)
        let image = NSImage(size: size, flipped: false) { _ in
            for start in rippleStarts {
                let progress = max(0, min(1, (now - start) / self.rippleDuration))
                let radius = 4.0 + (progress * 6.0)
                let alpha = 0.55 * (1.0 - progress)
                let ringRect = NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2.0,
                    height: radius * 2.0
                )
                let ringPath = NSBezierPath(ovalIn: ringRect)
                rippleColor.withAlphaComponent(alpha).setStroke()
                ringPath.lineWidth = max(0.6, 1.2 * (1.0 - (progress * 0.4)))
                ringPath.stroke()
            }

            let dotRect = NSRect(x: 5, y: 5, width: 8, height: 8)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            NSColor.white.setFill()
            dotPath.fill()
            NSColor.white.withAlphaComponent(0.45).setStroke()
            dotPath.lineWidth = 0.5
            dotPath.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }

    private func phaseColor() -> NSColor {
        switch activityMonitor.state.currentPhase {
        case "tooling":
            return NSColor.systemCyan
        case "thinking":
            return NSColor.systemPurple
        case "responding":
            return NSColor.systemOrange
        default:
            return NSColor.white
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }
}
