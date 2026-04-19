import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandPanel: DynamicIslandPanel?
    private var statusItem: NSStatusItem?
    private let uiState = UIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        setupStatusBar()
        setupIsland()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "ParrotIsle")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Island", action: #selector(toggleIsland), keyEquivalent: "i"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ParrotIsle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func toggleIsland() {
        guard let panel = islandPanel else { return }
        if panel.isVisible {
            if uiState.isRecording {
                uiState.stopRecording()
            }
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
    
    private func setupIsland() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 400
        let initialRect = NSRect(
            x: screen.visibleFrame.midX - (windowWidth / 2),
            y: screen.visibleFrame.maxY - windowHeight - 8,
            width: windowWidth,
            height: windowHeight
        )

        let panel = DynamicIslandPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DynamicIslandView(uiState: uiState))
        panel.orderFrontRegardless()

        islandPanel = panel
    }
}

final class DynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

