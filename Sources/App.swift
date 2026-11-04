import AppKit
import SwiftUI

@main
struct OLEDialApp: App {
    @StateObject private var tv = TVController()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(tv)
        } label: {
            Image(nsImage: AppInfo.menuBarIcon(connected: tv.isConnected))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Settings live in a regular window (more reliable than the Settings scene for menu bar apps).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tv: TVController) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(tv))
            let w = NSWindow(contentViewController: controller)
            w.title = "OLEDial"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        tv.updateMediaKeyTap()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum AppInfo {
    /// Monochrome template glyph for the menu bar (dial + TV); falls back to an SF Symbol.
    static func menuBarIcon(connected: Bool) -> NSImage {
        let name = connected ? "MenuBarIcon" : "MenuBarIconOff"
        let image = (Bundle.main.image(forResource: name)?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: connected ? "tv.fill" : "tv", accessibilityDescription: "OLEDial")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    static var appIcon: NSImage { NSApplication.shared.applicationIconImage }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var repoURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "LGTVRepositoryURL") as? String,
              s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }
}
