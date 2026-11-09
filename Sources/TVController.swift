import AppKit
import Carbon
import Foundation
import ServiceManagement

/// Which keyboard media keys go to the TV.
enum MediaKeyMode: String, CaseIterable, Identifiable {
    case followDisplay   // when the mouse pointer is on the TV's screen (BetterDisplay-style)
    case always          // always while connected
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .followDisplay: return "When pointer is on the TV"
        case .always: return "Always"
        case .off: return "Off"
        }
    }
}

/// Whether the keyboard's media keys are being captured.
enum MediaKeyStatus: Equatable {
    case off              // user turned the feature off
    case needsPermission  // Accessibility not granted
    case blocked          // granted, but macOS refused the event tap (stale permission after an update)
    case volumeOnly       // tap running, but without keyDown events (brightness keys 144/145 not seen)
    case active
}

/// App state + TV control logic. Owns the WebOSClient.
@MainActor
final class TVController: ObservableObject {
    // Connection
    @Published var host: String
    @Published private(set) var status: String = "Not connected"
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var discovered: [DiscoveredTV] = []
    @Published private(set) var isDiscovering = false

    // Controls
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var brightness: Double = 0
    @Published private(set) var brightnessAvailable = false
    @Published private(set) var lastError: String?

    // Keyboard
    @Published private(set) var shortcuts: [TVAction: KeyCombo] = [:]
    @Published var mediaKeyMode: MediaKeyMode {
        didSet { defaults.set(mediaKeyMode.rawValue, forKey: Keys.mediaMode); updateMediaKeyTap() }
    }
    @Published var tvDisplayName: String {   // "" = auto-detect a screen named "LG…"
        didSet { defaults.set(tvDisplayName, forKey: Keys.tvDisplay) }
    }
    @Published var volumeStep: Int {
        didSet { defaults.set(volumeStep, forKey: Keys.volumeStep) }
    }
    @Published var brightnessStepSize: Int {
        didSet { defaults.set(brightnessStepSize, forKey: Keys.brightnessStep) }
    }
    @Published var showHUD: Bool {
        didSet { defaults.set(showHUD, forKey: Keys.showHUD) }
    }
    @Published private(set) var accessibilityTrusted = MediaKeyTap.isTrusted
    @Published private(set) var mediaKeyStatus: MediaKeyStatus = .off
    @Published private(set) var launchAtLogin: Bool = false

    var volumeEditing = false
    var brightnessEditing = false

    private var client: WebOSClient?
    private let defaults = UserDefaults.standard
    private var reconnectTask: Task<Void, Never>?
    private var mediaKeyRetryTask: Task<Void, Never>?
    private var userWantsConnection = false
    private let mediaKeys = MediaKeyTap()

    // Latest-value-wins coalescing so dragging a slider doesn't flood the TV.
    private var volumeTarget: Int?
    private var volumeSending = false
    private var brightnessTarget: Int?
    private var brightnessSending = false
    /// nil = unknown, true = luna fallback needed, false = direct SSAP works.
    private var useLunaForSettings: Bool?

    private enum Keys {
        static let host = "tvHost"
        static let shortcuts = "shortcuts"
        static let mediaMode = "mediaKeyMode"
        static let tvDisplay = "tvDisplayName"
        static let volumeStep = "volumeStep"
        static let brightnessStep = "brightnessStep"
        static let showHUD = "showHUD"
        static func clientKey(_ host: String) -> String { "clientKey.\(host)" }
    }

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: Keys.host) ?? ""
        mediaKeyMode = MediaKeyMode(rawValue: d.string(forKey: Keys.mediaMode) ?? "") ?? .followDisplay
        tvDisplayName = d.string(forKey: Keys.tvDisplay) ?? ""
        volumeStep = d.object(forKey: Keys.volumeStep) as? Int ?? 2
        brightnessStepSize = d.object(forKey: Keys.brightnessStep) as? Int ?? 5
        showHUD = d.object(forKey: Keys.showHUD) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        shortcuts = Self.loadShortcuts()

        registerHotkeys()
        setUpMediaKeys()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconnect(after: 3) }
        }

        if !host.isEmpty, defaults.string(forKey: Keys.clientKey(host)) != nil {
            userWantsConnection = true
            Task { await connect() }
        }
    }

    var isPaired: Bool { !host.isEmpty && defaults.string(forKey: Keys.clientKey(host)) != nil }

    // MARK: - Connection

    func connect() async {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { status = "Enter the TV's IP address"; return }
        if target != host { host = target }
        defaults.set(target, forKey: Keys.host)
        userWantsConnection = true
        reconnectTask?.cancel()

        client?.close()
        let c = WebOSClient(host: target)
        client = c
        isBusy = true
        lastError = nil
        c.onStateChange = { [weak self, weak c] state in
            guard let self, let c, self.client === c else { return }
            switch state {
            case .connecting: self.status = "Connecting…"
            case .waitingForPairing: self.status = "Accept the prompt on your TV"
            case .connected: self.status = "Connected · \(c.host)"
            case .disconnected: self.status = "Disconnected"
            }
            self.isConnected = state == .connected
        }
        c.onDisconnect = { [weak self, weak c] _ in
            guard let self, let c, self.client === c else { return }
            self.isConnected = false
            self.scheduleReconnect(after: 5)
        }

        do {
            let key = try await c.connect(clientKey: defaults.string(forKey: Keys.clientKey(target)))
            guard client === c else { return }
            defaults.set(key, forKey: Keys.clientKey(target))
            isBusy = false
            startSubscriptions(c)
        } catch {
            guard client === c else { return }
            isBusy = false
            isConnected = false
            status = "Can't reach TV — is it on?"
            lastError = error.localizedDescription
            if let e = error as? WebOSError, case .pairingRejected = e {
                status = "Pairing rejected"
            } else if isPaired {
                scheduleReconnect(after: 10)
            }
        }
    }

    func disconnect() {
        userWantsConnection = false
        reconnectTask?.cancel()
        client?.close()
        client = nil
        isConnected = false
        status = "Disconnected"
    }

    func forgetPairing() {
        disconnect()
        defaults.removeObject(forKey: Keys.clientKey(host))
        status = "Pairing removed"
    }

    private func scheduleReconnect(after seconds: Double) {
        guard userWantsConnection, isPaired, !isConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isConnected, !self.isBusy else { return }
            await self.connect()
        }
    }

    func discover() async {
        isDiscovering = true
        discovered = await SSDPDiscovery.discover()
        isDiscovering = false
        if discovered.isEmpty { status = "No TVs found — enter the IP manually" }
    }

    // MARK: - State updates from TV

    private func startSubscriptions(_ c: WebOSClient) {
        c.subscribe("audio/getVolume") { [weak self] p in self?.applyAudio(p) }
        c.subscribe("audio/getStatus") { [weak self] p in self?.applyAudio(p) }
        c.subscribe("settings/getSystemSettings",
                    ["category": "picture", "keys": ["backlight"]]) { [weak self] p in
            self?.applyPicture(p)
        }
        Task { [weak self] in
            if let p = try? await c.request("settings/getSystemSettings",
                                             ["category": "picture", "keys": ["backlight"]]) {
                self?.applyPicture(p)
            }
            if let p = try? await c.request("audio/getVolume") { self?.applyAudio(p) }
        }
    }

    private func applyAudio(_ payload: [String: Any]) {
        let s = payload["volumeStatus"] as? [String: Any] ?? payload
        if let v = Self.intValue(s["volume"]), !volumeEditing, volumeTarget == nil, !volumeSending {
            volume = Double(v)
        }
        if let m = (s["muteStatus"] as? Bool) ?? (s["mute"] as? Bool) {
            muted = m
        }
    }

    private func applyPicture(_ payload: [String: Any]) {
        guard let settings = payload["settings"] as? [String: Any],
              let b = Self.intValue(settings["backlight"]) else { return }
        brightnessAvailable = true
        if !brightnessEditing, brightnessTarget == nil, !brightnessSending {
            brightness = Double(b)
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: - Volume

    func setVolume(_ value: Double) {
        volume = min(100, max(0, value.rounded()))
        volumeTarget = Int(volume)
        pumpVolume()
    }

    private func pumpVolume() {
        guard !volumeSending, let target = volumeTarget, let c = client, isConnected else { return }
        volumeTarget = nil
        volumeSending = true
        Task {
            do { try await c.request("audio/setVolume", ["volume": target]) }
            catch { self.lastError = "Volume: \(error.localizedDescription)" }
            self.volumeSending = false
            self.pumpVolume()
        }
    }

    func adjustVolume(by delta: Int) {
        guard isConnected else { return }
        if muted, delta > 0 { toggleMute() }
        setVolume(volume + Double(delta))
    }

    func toggleMute() {
        guard let c = client, isConnected else { return }
        let newValue = !muted
        muted = newValue
        Task {
            do { try await c.request("audio/setMute", ["mute": newValue]) }
            catch { self.muted = !newValue; self.lastError = "Mute: \(error.localizedDescription)" }
        }
    }

    // MARK: - Brightness (OLED Pixel Brightness / OLED Light = picture "backlight")

    func setBrightness(_ value: Double) {
        brightness = min(100, max(0, value.rounded()))
        brightnessTarget = Int(brightness)
        pumpBrightness()
    }

    func adjustBrightness(by delta: Int) {
        guard isConnected else { return }
        setBrightness(brightness + Double(delta))
    }

    private func pumpBrightness() {
        guard !brightnessSending, let target = brightnessTarget, let c = client, isConnected else { return }
        brightnessTarget = nil
        brightnessSending = true
        Task {
            do { try await self.setPictureSettings(["backlight": target], on: c) }
            catch { self.lastError = "Brightness: \(error.localizedDescription)" }
            self.brightnessSending = false
            self.pumpBrightness()
        }
    }

    /// Newer firmware accepts settings/setSystemSettings over SSAP directly; older firmware
    /// needs the luna:// alert workaround. Try direct first and remember what works.
    private func setPictureSettings(_ settings: [String: Any], on c: WebOSClient) async throws {
        let params: [String: Any] = ["category": "picture", "settings": settings]
        if useLunaForSettings != true {
            do {
                try await c.request("settings/setSystemSettings", params)
                useLunaForSettings = false
                return
            } catch {
                if useLunaForSettings == false { throw error }
            }
        }
        try await c.lunaRequest("com.webos.settingsservice/setSystemSettings", params: params)
        useLunaForSettings = true
    }

    // MARK: - Power

    func powerOff() {
        guard let c = client, isConnected else { return }
        Task { try? await c.request("system/turnOff") }
    }

    // MARK: - Actions (shared by shortcuts and media keys)

    func perform(_ action: TVAction, fine: Bool = false, hudScreen: NSScreen? = nil) {
        guard isConnected else { return }
        let vStep = fine ? 1 : volumeStep
        let bStep = fine ? 1 : brightnessStepSize
        switch action {
        case .volumeUp: adjustVolume(by: vStep); showVolumeHUD(on: hudScreen)
        case .volumeDown: adjustVolume(by: -vStep); showVolumeHUD(on: hudScreen)
        case .mute: toggleMute(); showVolumeHUD(on: hudScreen)
        case .brightnessUp: adjustBrightness(by: bStep); showBrightnessHUD(on: hudScreen)
        case .brightnessDown: adjustBrightness(by: -bStep); showBrightnessHUD(on: hudScreen)
        case .powerOff: powerOff()
        }
    }

    private func showVolumeHUD(on screen: NSScreen?) {
        guard showHUD else { return }
        let symbol: String
        if muted || volume == 0 { symbol = "speaker.slash.fill" }
        else if volume < 34 { symbol = "speaker.wave.1.fill" }
        else if volume < 67 { symbol = "speaker.wave.2.fill" }
        else { symbol = "speaker.wave.3.fill" }
        HUDController.shared.show(symbol: symbol, title: "TV Volume", value: volume, muted: muted,
                                  on: screen ?? tvScreen() ?? mouseScreen())
    }

    private func showBrightnessHUD(on screen: NSScreen?) {
        guard showHUD else { return }
        HUDController.shared.show(symbol: brightness < 50 ? "sun.min.fill" : "sun.max.fill",
                                  title: "TV Brightness", value: brightness,
                                  on: screen ?? tvScreen() ?? mouseScreen())
    }

    // MARK: - Custom shortcuts

    private static func loadShortcuts() -> [TVAction: KeyCombo] {
        guard let data = UserDefaults.standard.data(forKey: Keys.shortcuts),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else {
            return KeyCombo.defaults
        }
        var result: [TVAction: KeyCombo] = [:]
        for (k, v) in raw { if let a = TVAction(rawValue: k) { result[a] = v } }
        return result
    }

    private func saveShortcuts() {
        var raw: [String: KeyCombo] = [:]
        for (k, v) in shortcuts { raw[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Keys.shortcuts) }
    }

    func setShortcut(_ combo: KeyCombo?, for action: TVAction) {
        if let combo {
            // A combo can only belong to one action.
            for (a, c) in shortcuts where c.keyCode == combo.keyCode && c.modifiers == combo.modifiers {
                shortcuts[a] = nil
            }
        }
        shortcuts[action] = combo
        saveShortcuts()
        registerHotkeys()
    }

    func resetShortcuts() {
        shortcuts = KeyCombo.defaults
        saveShortcuts()
        registerHotkeys()
    }

    /// Temporarily disables global shortcuts (while recording a new one).
    func suspendHotkeys(_ suspend: Bool) {
        if suspend { HotKeyManager.shared.unregisterAll() } else { registerHotkeys() }
    }

    private func registerHotkeys() {
        HotKeyManager.shared.unregisterAll()
        for (action, combo) in shortcuts {
            HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                Task { @MainActor in self?.perform(action) }
            }
        }
    }

    // MARK: - Keyboard media keys (volume / brightness / mute keys)

    private func setUpMediaKeys() {
        mediaKeys.shouldIntercept = { [weak self] key in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.shouldInterceptMediaKey(key) }
        }
        mediaKeys.onKey = { [weak self] key, flags in
            guard let self else { return }
            MainActor.assumeIsolated {
                // ⌥⇧ + key = fine step of 1, like macOS.
                let fine = flags.contains(.option) && flags.contains(.shift)
                let screen = self.mouseScreen()
                switch key {
                case .soundUp: self.perform(.volumeUp, fine: fine, hudScreen: screen)
                case .soundDown: self.perform(.volumeDown, fine: fine, hudScreen: screen)
                case .mute: self.perform(.mute, hudScreen: screen)
                case .brightnessUp: self.perform(.brightnessUp, fine: fine, hudScreen: screen)
                case .brightnessDown: self.perform(.brightnessDown, fine: fine, hudScreen: screen)
                }
            }
        }
        updateMediaKeyTap()
    }

    private func shouldInterceptMediaKey(_ key: MediaKey) -> Bool {
        guard isConnected else { return false }
        if key == .brightnessUp || key == .brightnessDown, !brightnessAvailable { return false }
        switch mediaKeyMode {
        case .off: return false
        case .always: return true
        case .followDisplay:
            guard let tv = tvScreen(), let mouse = mouseScreen() else { return false }
            return Self.displayID(tv) == Self.displayID(mouse)
        }
    }

    func updateMediaKeyTap() {
        accessibilityTrusted = MediaKeyTap.isTrusted
        if mediaKeyMode == .off {
            mediaKeys.stop()
            mediaKeyRetryTask?.cancel()
            mediaKeyRetryTask = nil
            mediaKeyStatus = .off
            return
        }
        if accessibilityTrusted { mediaKeys.start() }
        refreshMediaKeyStatus()
        if !mediaKeys.isRunning { startMediaKeyRetry() }
    }

    private func refreshMediaKeyStatus() {
        accessibilityTrusted = MediaKeyTap.isTrusted
        if mediaKeyMode == .off { mediaKeyStatus = .off }
        else if mediaKeys.isRunning { mediaKeyStatus = mediaKeys.capturesKeyEvents ? .active : .volumeOnly }
        else if !accessibilityTrusted { mediaKeyStatus = .needsPermission }
        else { mediaKeyStatus = .blocked }
    }

    /// Keeps trying to install the tap (e.g. while the user grants or re-grants permission).
    private func startMediaKeyRetry() {
        guard mediaKeyRetryTask == nil else { return }
        mediaKeyRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.mediaKeyMode == .off { break }
                if MediaKeyTap.isTrusted { self.mediaKeys.start() }
                self.refreshMediaKeyStatus()
                if self.mediaKeys.isRunning { break }
            }
            self?.mediaKeyRetryTask = nil
        }
    }

    func requestAccessibility() {
        MediaKeyTap.requestTrust()
        startMediaKeyRetry()
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Displays

    var screenNames: [String] { NSScreen.screens.map { $0.localizedName } }

    /// The screen that is the LG TV (chosen in Settings, or auto-detected by name).
    func tvScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if !tvDisplayName.isEmpty {
            return screens.first { $0.localizedName == tvDisplayName }
        }
        return screens.first { $0.localizedName.localizedCaseInsensitiveContains("LG TV") }
            ?? screens.first { $0.localizedName.localizedCaseInsensitiveContains("LG") }
    }

    func mouseScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
