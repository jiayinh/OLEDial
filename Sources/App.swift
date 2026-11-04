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
            Image(systemName: tv.isConnected ? "tv.fill" : "tv")
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
