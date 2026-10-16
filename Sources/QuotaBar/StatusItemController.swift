import AppKit
import Observation
import SwiftUI

/// One menu bar item with its own popover. The popover is `.transient`, so AppKit closes it on any
/// click outside (another app, the desktop, or another status item) — MenuBarExtra does not
/// reliably do that for an accessory app.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let label: @MainActor () -> NSImage
    private let isVisible: @MainActor () -> Bool

    init<Content: View>(
        label: @escaping @MainActor () -> NSImage,
        isVisible: @escaping @MainActor () -> Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.isVisible = isVisible
        super.init()

        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        renderLabel()

        // `.transient` alone misses some cases (e.g. after hopping between our own items),
        // so also close on app deactivation and on any click delivered to another app.
        NotificationCenter.default.addObserver(
            self, selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    @objc private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc func togglePopover() {
        guard statusItem.isVisible, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // An accessory app is not active by default; without this, clicks in other apps
            // would not count as "outside" and the popover would stay open.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let window = popover.contentViewController?.view.window
            window?.makeKey()
            // AppKit gives initial focus to the first focusable control (the refresh button),
            // which draws a focus ring. Start with nothing focused; Tab still works.
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        }
    }

    /// Re-renders the menu bar item whenever the observed values it reads change.
    private func renderLabel() {
        withObservationTracking {
            statusItem.isVisible = isVisible()
            statusItem.button?.image = label()
        } onChange: { [weak self] in
            Task { @MainActor in self?.renderLabel() }
        }
    }
}
