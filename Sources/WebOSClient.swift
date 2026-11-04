import Foundation

/// Errors surfaced by the webOS client.
enum WebOSError: LocalizedError {
    case notConnected
    case timeout
    case pairingRejected(String)
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the TV."
        case .timeout: return "The TV did not respond in time."
        case .pairingRejected(let m): return "Pairing was rejected: \(m)"
        case .requestFailed(let m): return "Request failed: \(m)"
        case .invalidResponse: return "Unexpected response from the TV."
        }
    }
}

/// Minimal LG webOS "SSAP" client over WebSocket.
///
/// Protocol notes (cross-checked against the aiowebostv and bscpylgtv libraries):
/// - Newer firmware requires TLS on port 3001 (self-signed cert); older firmware uses ws:// on 3000.
/// - Pairing: send a `register` message with a manifest; the TV shows a prompt; on accept it
///   returns a `registered` message containing a `client-key`, which is reused on later connections.
/// - Requests: `{type:"request", id, uri:"ssap://...", payload}`; responses reuse the same id.
@MainActor
final class WebOSClient: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable {
        case disconnected
        case connecting
        case waitingForPairing
        case connected
    }

    let host: String
    private(set) var state: State = .disconnected { didSet { onStateChange?(state) } }

    var onStateChange: ((State) -> Void)?
    /// Called when an established connection drops unexpectedly.
    var onDisconnect: ((Error?) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var counter = 0

    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var subscriptions: [String: ([String: Any]) -> Void] = [:]

    private var registerID = ""
    private var registerCont: CheckedContinuation<String, Error>?
    private var sawPairingPrompt = false
    private var pingTask: Task<Void, Never>?

    init(host: String) {
        self.host = host
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Connection

    /// Connects and registers. Returns the client key (new or existing).
    func connect(clientKey: String?) async throws -> String {
        state = .connecting
        var lastError: Error = WebOSError.notConnected
        let endpoints = ["wss://\(host):3001", "ws://\(host):3000"]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let key = try await attempt(url: url, clientKey: clientKey)
                state = .connected
                startPinging()
                return key
            } catch let e as WebOSError {
                lastError = e
                if case .pairingRejected = e { break }
            } catch {
                lastError = error
            }
        }
        teardown(error: lastError)
        state = .disconnected
        throw lastError
    }

    /// Permanently closes this client (breaks the URLSession -> delegate retain cycle).
    func close() {
        teardown(error: WebOSError.notConnected)
        state = .disconnected
        session.invalidateAndCancel()
    }

    private func attempt(url: URL, clientKey: String?) async throws -> String {
        teardown(error: WebOSError.notConnected)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        sawPairingPrompt = false
        t.resume()
        receiveLoop(t)

        registerID = nextID()
        var payload = Self.registrationPayload
        if let clientKey, !clientKey.isEmpty { payload["client-key"] = clientKey }
        let message: [String: Any] = ["type": "register", "id": registerID, "payload": payload]

        return try await withCheckedThrowingContinuation { cont in
            registerCont = cont
            send(message)
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, self.generation == gen, !self.sawPairingPrompt else { return }
                self.finishRegister(.failure(WebOSError.timeout))
            }
        }
    }

    private func finishRegister(_ result: Result<String, Error>) {
        guard let cont = registerCont else { return }
        registerCont = nil
        cont.resume(with: result)
    }

    private func teardown(error: Error) {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        subscriptions.removeAll()
        let waiting = pending
        pending.removeAll()
        for (_, c) in waiting { c.resume(throwing: error) }
        finishRegister(.failure(error))
    }

    private func connectionLost(_ error: Error?) {
        let wasConnected = state == .connected
        teardown(error: error ?? WebOSError.notConnected)
        if state != .connecting { state = .disconnected }
        if wasConnected { onDisconnect?(error) }
    }

    private func startPinging() {
        pingTask?.cancel()
        let gen = generation
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.generation == gen, let t = self.task else { return }
                t.sendPing { error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.connectionLost(error)
                    }
                }
            }
        }
    }

    // MARK: - Messaging

    private func nextID() -> String {
        counter += 1
        return "lgtvctl_\(counter)"
    }

    private func send(_ object: [String: Any]) {
        guard let t = task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let gen = generation
        t.send(.string(text)) { error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.connectionLost(error)
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        let gen = generation
        t.receive { result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(Data(s.utf8))
                    case .data(let d): self.handle(d)
                    @unknown default: break
                    }
                    self.receiveLoop(t)
                case .failure(let error):
                    self.connectionLost(error)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let id = obj["id"] as? String ?? ""
        let payload = obj["payload"] as? [String: Any] ?? [:]

        // Registration flow
        if id == registerID, registerCont != nil {
            switch type {
            case "registered":
                if let key = payload["client-key"] as? String {
                    finishRegister(.success(key))
                } else {
                    finishRegister(.failure(WebOSError.invalidResponse))
                }
            case "response":
                if (payload["pairingType"] as? String) == "PROMPT" {
                    sawPairingPrompt = true
                    state = .waitingForPairing
                    let gen = generation
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard let self, self.generation == gen else { return }
                        self.finishRegister(.failure(WebOSError.timeout))
                    }
                }
            case "error":
                finishRegister(.failure(WebOSError.pairingRejected(obj["error"] as? String ?? "unknown")))
            default:
                break
            }
            return
        }

        if let handler = subscriptions[id] {
            if type != "error" { handler(payload) }
        }

        if let cont = pending.removeValue(forKey: id) {
            if type == "error" {
                cont.resume(throwing: WebOSError.requestFailed(obj["error"] as? String ?? "error"))
            } else if let rv = payload["returnValue"] as? Bool, rv == false {
                let msg = payload["errorText"] as? String ?? "returnValue false"
                cont.resume(throwing: WebOSError.requestFailed(msg))
            } else {
                cont.resume(returning: payload)
            }
        }
    }

    // MARK: - Public API

    /// Sends an SSAP request, e.g. `request("audio/setVolume", ["volume": 10])`.
    @discardableResult
    func request(_ uri: String, _ payload: [String: Any]? = nil, timeout: Double = 6) async throws -> [String: Any] {
        guard task != nil, state == .connected else { throw WebOSError.notConnected }
        let id = nextID()
        var message: [String: Any] = ["type": "request", "id": id, "uri": "ssap://\(uri)"]
        if let payload { message["payload"] = payload }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(message)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let c = self.pending.removeValue(forKey: id) else { return }
                c.resume(throwing: WebOSError.timeout)
            }
        }
    }

    /// Subscribes to an SSAP URI; `handler` is called with every update payload.
    func subscribe(_ uri: String, _ payload: [String: Any]? = nil, handler: @escaping ([String: Any]) -> Void) {
        guard task != nil, state == .connected else { return }
        let id = nextID()
        subscriptions[id] = handler
        var message: [String: Any] = ["type": "subscribe", "id": id, "uri": "ssap://\(uri)"]
        if let payload { message["payload"] = payload }
        send(message)
    }

    /// Calls an internal luna:// service using the createAlert/closeAlert workaround
    /// (same technique as bscpylgtv's `luna_request`). Closing the alert triggers `onclose`.
    func lunaRequest(_ uri: String, params: [String: Any]) async throws {
        let luna = "luna://\(uri)"
        let payload: [String: Any] = [
            "message": " ",
            "buttons": [["label": "", "onClick": luna, "params": params]],
            "onclose": ["uri": luna, "params": params],
            "onfail": ["uri": luna, "params": params],
        ]
        let result = try await request("system.notifications/createAlert", payload)
        guard let alertId = result["alertId"] as? String else { throw WebOSError.invalidResponse }
        try await request("system.notifications/closeAlert", ["alertId": alertId])
    }

    // MARK: - URLSessionDelegate (accept the TV's self-signed certificate)

    nonisolated func urlSession(_ session: URLSession,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    // MARK: - Registration manifest (permissions list as used by aiowebostv)

    static let registrationPayload: [String: Any] = [
        "forcePairing": false,
        "pairingType": "PROMPT",
        "manifest": [
            "appVersion": "1.1",
            "manifestVersion": 1,
            "permissions": [
                "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY",
                "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_PLAYBACK",
                "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV",
                "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN",
                "LAUNCH", "LAUNCH_WEBAPP", "READ_APP_STATUS", "READ_COUNTRY_INFO",
                "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS",
                "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE",
                "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS",
                "READ_SETTINGS", "READ_TV_CHANNEL_LIST", "READ_TV_CURRENT_TIME",
                "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE",
                "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT",
                "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
            ],
        ] as [String: Any],
    ]
}
