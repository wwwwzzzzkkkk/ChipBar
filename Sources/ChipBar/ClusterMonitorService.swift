import AppKit
import ChipBarCore
import Combine
import CryptoKit
import Foundation
import Network
import Security

struct ClusterNearbyDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let paired: Bool
}

struct ClusterPairingCandidate: Equatable {
    let id: String
    let name: String
    let publicKey: Data
    let code: String
}

@MainActor private final class ClusterPeerSession {
    let id = UUID()
    let connection: NWConnection
    let endpointID: String?
    var buffer = Data()
    var hello: ClusterPeerHello?
    var key: Data?
    var remoteApproved = false
    var localApprovalSent = false

    init(connection: NWConnection, endpointID: String?) {
        self.connection = connection
        self.endpointID = endpointID
    }
}

/// v3.6 read-only monitor: Bonjour is used for discovery, X25519 + a
/// user-verified six-digit code for pairing, and AES-GCM for observations.
/// Absolutely no shell, simulation lifecycle or job execution messages exist.
@MainActor final class ClusterMonitorService: ObservableObject {
    static let shared = ClusterMonitorService()

    @Published private(set) var enabled: Bool = false
    @Published private(set) var peers: [ClusterNodeReadout] = []
    @Published private(set) var observedOpenFASTTasks: [ClusterTaskReadout] = []
    @Published private(set) var externalTasks: [ClusterTaskReadout] = []
    @Published private(set) var taskLayoutVersion = 0
    @Published private(set) var nearby: [ClusterNearbyDevice] = []
    @Published private(set) var pairingCandidate: ClusterPairingCandidate?
    @Published private(set) var status = "打开两台 Mac 的计算集群页面即可搜索"

    private static let enabledKey = "chipbar.cluster.enabled.v2"
    private static let nodeIDKey = "chipbar.cluster.node-id.v1"
    private static let keychainService = "local.chipbar.monitor.cluster"
    private static let identityAccount = "identity-x25519-v2"
    private static let trustedAccount = "trusted-device-keys-v2"

    private weak var monitor: Monitor?
    private let nodeID: String
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private var trusted: [String: Data]
    private var panelVisible = false
    private var discoveryGraceTask: Task<Void, Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var tickTimer: Timer?
    private var sessions: [UUID: ClusterPeerSession] = [:]
    private var outgoing: [String: UUID] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var attempts: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var openFASTScan: Task<Void, Never>?
    private var lastOpenFASTScan = Date.distantPast

    private init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: Self.nodeIDKey) ?? UUID().uuidString
        defaults.set(id, forKey: Self.nodeIDKey)
        nodeID = id
        identity = Self.identityKey()
        trusted = (Self.readKeychain(account: Self.trustedAccount))
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        enabled = defaults.bool(forKey: Self.enabledKey) && !trusted.isEmpty
    }

    func attach(monitor: Monitor) {
        self.monitor = monitor
        if enabled { start() }
    }

    /// Discovery runs only while the detail panel is open, or if this Mac is
    /// already participating in an explicitly approved cluster.
    func setPanelVisible(_ value: Bool) {
        panelVisible = value
        discoveryGraceTask?.cancel()
        discoveryGraceTask = nil
        if value {
            start()
            scanOpenFASTIfNeeded(force: true)
        } else if !enabled {
            // Switching to the other Mac can dismiss the menu panel.
            // Keep discovery (but never telemetry) alive briefly so that
            // a user can open both machines' menus and compare codes.
            discoveryGraceTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(120)) }
                catch { return }
                guard let self, !self.panelVisible, !self.enabled else { return }
                self.stop()
                self.nearby = []
                self.pairingCandidate = nil
                self.discoveryGraceTask = nil
            }
        }
    }

    func setEnabled(_ value: Bool) {
        if value && trusted.isEmpty {
            status = "请先选择并确认另一台 Mac"
            return
        }
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value {
            start()
            sendToTrustedPeers()
        } else {
            sessions.values.forEach {
                $0.localApprovalSent = false
                $0.remoteApproved = false
            }
            peers = []
            lastSeen = [:]
            status = "已暂停监控共享"
            if !panelVisible { stop() }
        }
    }

    func refreshDiscovery() {
        stop()
        if enabled || panelVisible { start() }
    }

    func requestPairing(with id: String) {
        guard let session = sessions.values.first(where: { $0.hello?.id == id }),
              let hello = session.hello,
              let key = session.key,
              trusted[id] != hello.publicKey else {
            status = "设备尚未就绪，请确认两端 ChipBar 已打开"
            return
        }
        let code = ClusterPairing.verificationCode(
            sessionKey: key,
            localPublicKey: identity.publicKey.rawRepresentation,
            remotePublicKey: hello.publicKey)
        pairingCandidate = ClusterPairingCandidate(
            id: id, name: hello.name, publicKey: hello.publicKey, code: code)
        status = "请对照两台 Mac 上显示的六位数字；相同才确认"
    }

    func cancelPairing() { pairingCandidate = nil }

    func confirmPairing() {
        guard let candidate = pairingCandidate,
              let session = sessions.values.first(where: {
                  $0.hello?.id == candidate.id &&
                  $0.hello?.publicKey == candidate.publicKey &&
                  $0.key != nil
              }) else {
            status = "配对连接已断开，请重新选择设备"
            pairingCandidate = nil
            return
        }
        let previous = trusted
        trusted[candidate.id] = candidate.publicKey
        guard let encoded = try? JSONEncoder().encode(trusted),
              Self.storeKeychain(encoded, account: Self.trustedAccount) else {
            trusted = previous
            status = "无法保存配对，请检查 macOS 钥匙串"
            return
        }
        pairingCandidate = nil
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        publishNearby()
        status = "已信任 " + candidate.name + "，等待对方确认后自动连接"
        sendApproval(to: session)
        sendToTrustedPeers()
    }

    func forgetPeer(_ id: String) {
        guard trusted.removeValue(forKey: id) != nil else { return }
        if let data = try? JSONEncoder().encode(trusted) {
            _ = Self.storeKeychain(data, account: Self.trustedAccount)
        }
        peers.removeAll { $0.id == id }
        lastSeen.removeValue(forKey: id)
        if trusted.isEmpty { setEnabled(false) }
        publishNearby()
    }

    func requestTaskLayoutFit() { taskLayoutVersion &+= 1 }

    var onlinePeers: [ClusterNodeReadout] {
        peers.filter { $0.isOnline() && enabled }
    }

    var localNode: ClusterNodeReadout {
        let sample = monitor?.connected == true ? monitor?.sample : nil
        return ClusterNodeReadout(
            id: nodeID,
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            chip: sample?.chip ?? monitor?.hardware ?? "Apple Silicon",
            timestamp: Date(),
            cpu: sample?.cpuUtilization,
            gpu: sample?.gpuUtilization,
            memoryUsedGB: sample?.memory?.usedGiB,
            memoryTotalGB: sample?.memory?.totalGiB,
            chipWatts: sample?.total,
            cpuTemperatureC: sample?.cpuTemperature,
            fanRPM: sample?.fans.map(\.rpm).max(),
            // External GPT/Codex status is authoritative when present.
            // Otherwise scan only the local running OpenFAST process.
            tasks: externalTasks.isEmpty ? observedOpenFASTTasks : externalTasks)
    }

    private var bonjourName: String { "ChipBar-" + String(nodeID.prefix(8)) }

    private func start() {
        guard listener == nil else { return }
        do {
            let service = try NWListener(using: .tcp)
            service.service = NWListener.Service(
                name: bonjourName, type: ClusterSecureWire.serviceType)
            service.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.register(connection, endpointID: nil) }
            }
            service.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if self.nearby.isEmpty {
                            self.status = "正在搜索附近的 Mac…"
                        }
                    case .waiting(let error), .failed(let error):
                        self.status = "共享服务不可用：" + error.localizedDescription
                    default: break
                    }
                }
            }
            listener = service
            service.start(queue: .main)

            // Bonjour also traverses a configured Thunderbolt Bridge without
            // the higher-power Wi-Fi peer-to-peer discovery mode.
            let browser = NWBrowser(
                for: .bonjour(type: ClusterSecureWire.serviceType, domain: nil),
                using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.updateDiscovered(results) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .waiting(let error), .failed(let error):
                        self.status = "搜索不可用：" + error.localizedDescription +
                            "。请检查本地网络授权与雷雳桥接"
                    default: break
                    }
                }
            }
            self.browser = browser
            browser.start(queue: .main)

            tickTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            tickTimer?.tolerance = 0.5
            tick()
        } catch {
            status = "无法搜索局域网设备：" + error.localizedDescription
        }
    }

    private func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.connection.cancel() }
        sessions.removeAll()
        outgoing.removeAll()
        endpoints.removeAll()
        attempts.removeAll()
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint,
               name == bonjourName { continue }
            let id = String(describing: result.endpoint)
            found[id] = result.endpoint
        }
        endpoints = found
        for (id, sessionID) in outgoing.filter({ found[$0.key] == nil }) {
            sessions[sessionID]?.connection.cancel()
            sessions.removeValue(forKey: sessionID)
            outgoing.removeValue(forKey: id)
        }
        connectDiscovered()
        publishNearby()
    }

    private func connectDiscovered() {
        guard enabled || panelVisible else { return }
        let now = Date()
        for (id, endpoint) in endpoints where outgoing[id] == nil {
            if let last = attempts[id], now.timeIntervalSince(last) < 5 { continue }
            attempts[id] = now
            register(NWConnection(to: endpoint, using: .tcp), endpointID: id)
        }
    }

    private func register(_ connection: NWConnection, endpointID: String?) {
        guard enabled || panelVisible, sessions.count < 20 else {
            connection.cancel()
            return
        }
        let session = ClusterPeerSession(connection: connection, endpointID: endpointID)
        sessions[session.id] = session
        if let endpointID { outgoing[endpointID] = session.id }
        connection.stateUpdateHandler = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session,
                      self.sessions[session.id] === session else { return }
                switch state {
                case .ready:
                    self.sendHello(to: session)
                    self.receive(on: session)
                case .failed, .cancelled:
                    self.remove(session)
                case .waiting(let error):
                    self.status = "设备连接等待中：" + error.localizedDescription
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func remove(_ session: ClusterPeerSession) {
        sessions.removeValue(forKey: session.id)
        if let id = session.endpointID, outgoing[id] == session.id {
            outgoing.removeValue(forKey: id)
        }
        session.connection.cancel()
        publishNearby()
    }

    private func sendHello(to session: ClusterPeerSession) {
        let hello = ClusterPeerHello(
            id: nodeID,
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            publicKey: identity.publicKey.rawRepresentation)
        guard let payload = try? JSONEncoder().encode(hello),
              let data = ClusterPacket.encode(type: ClusterPacket.hello, body: payload)
        else { return }
        session.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on session: ClusterPeerSession) {
        session.connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: ClusterSecureWire.maximumFrameBytes) {
            [weak self, weak session] data, _, complete, error in
            Task { @MainActor in
                guard let self, let session,
                      self.sessions[session.id] === session else { return }
                if let data, !data.isEmpty { self.process(data, from: session) }
                if complete || error != nil {
                    self.remove(session)
                } else {
                    self.receive(on: session)
                }
            }
        }
    }

    private func process(_ bytes: Data, from session: ClusterPeerSession) {
        session.buffer.append(bytes)
        if session.buffer.count > ClusterSecureWire.maximumFrameBytes * 2 {
            remove(session)
            return
        }
        while session.buffer.count >= 4 {
            let count = session.buffer.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard count >= 2, count <= ClusterSecureWire.maximumFrameBytes else {
                remove(session)
                return
            }
            let end = Int(count) + 4
            guard session.buffer.count >= end else { break }
            let kind = session.buffer[4]
            let body = Data(session.buffer[5..<end])
            session.buffer.removeSubrange(0..<end)
            switch kind {
            case ClusterPacket.hello: processHello(body, from: session)
            case ClusterPacket.telemetry: processTelemetry(body, from: session)
            case ClusterPacket.approval: processApproval(body, from: session)
            default:
                remove(session)
                return
            }
            guard sessions[session.id] === session else { return }
        }
    }

    private func processHello(_ body: Data, from session: ClusterPeerSession) {
        guard body.count <= 2048,
              let hello = try? JSONDecoder().decode(ClusterPeerHello.self, from: body),
              hello.isValid, hello.id != nodeID,
              let key = try? ClusterPairing.sessionKey(
                privateKey: identity, remotePublicKey: hello.publicKey)
        else {
            remove(session)
            return
        }
        // Never silently replace the public key of an already paired device.
        session.hello = hello
        session.key = key
        publishNearby()
        if trusted[hello.id] == hello.publicKey && enabled {
            sendApproval(to: session)
        }
    }

    private struct Consent: Codable {
        let nodeID: String
        let approved: Bool
    }

    private func sendApproval(to session: ClusterPeerSession) {
        guard enabled, !session.localApprovalSent,
              let hello = session.hello,
              trusted[hello.id] == hello.publicKey,
              let key = session.key,
              let plaintext = try? JSONEncoder().encode(Consent(nodeID: nodeID, approved: true)),
              let sealed = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)),
              let encrypted = sealed.combined,
              let packet = ClusterPacket.encode(type: ClusterPacket.approval, body: encrypted)
        else { return }
        session.localApprovalSent = true
        session.connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func processApproval(_ body: Data, from session: ClusterPeerSession) {
        guard let hello = session.hello,
              let key = session.key,
              let box = try? AES.GCM.SealedBox(combined: body),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let consent = try? JSONDecoder().decode(Consent.self, from: plaintext),
              consent.approved, consent.nodeID == hello.id else { return }
        session.remoteApproved = true
        sendSnapshot(to: session)
    }

    private func processTelemetry(_ body: Data, from session: ClusterPeerSession) {
        guard enabled,
              let hello = session.hello,
              trusted[hello.id] == hello.publicKey,
              let key = session.key,
              let node = try? ClusterSecureWire.open(body, key: key),
              node.id == hello.id else { return }
        if let last = lastSeen[node.id], node.timestamp <= last { return }
        lastSeen[node.id] = node.timestamp
        if let index = peers.firstIndex(where: { $0.id == node.id }) {
            peers[index] = node
        } else if peers.count < 16 {
            peers.append(node)
        }
        if status.hasPrefix("正在搜索") || status.hasPrefix("已信任") {
            status = "已连接 " + hello.name
        }
    }

    private func publishNearby() {
        var devices: [String: ClusterNearbyDevice] = [:]
        for session in sessions.values {
            guard let hello = session.hello else { continue }
            devices[hello.id] = ClusterNearbyDevice(
                id: hello.id,
                name: hello.name,
                paired: trusted[hello.id] == hello.publicKey)
        }
        let latest = devices.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if latest != nearby { nearby = latest }
    }

    private func tick() {
        connectDiscovered()
        // Refresh external GPT/Codex manifest when it changes, without
        // reading it on every SwiftUI body evaluation.
        let updatedExternalTasks = Self.readExternalTasks()
        if updatedExternalTasks != externalTasks { externalTasks = updatedExternalTasks }
        scanOpenFASTIfNeeded()
        sendToTrustedPeers()
        let cutoff = Date().addingTimeInterval(-60)
        peers.removeAll { $0.timestamp < cutoff }
        lastSeen = lastSeen.filter { $0.value >= cutoff }
    }

    /// Background process enumeration is deliberately throttled and never
    /// runs in the main menu sampling path or while Cluster is inactive.
    /// No shell, stdout interception, task submission or process control.
    private func scanOpenFASTIfNeeded(force: Bool = false) {
        guard enabled || panelVisible, openFASTScan == nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastOpenFASTScan) >= 9 else { return }
        lastOpenFASTScan = now
        openFASTScan = Task.detached(priority: .utility) { [weak self] in
            let tasks = await OpenFASTProcessScanner.shared.scan()
            await MainActor.run {
                guard let self else { return }
                if self.enabled || self.panelVisible {
                    if self.observedOpenFASTTasks != tasks {
                        self.observedOpenFASTTasks = tasks
                    }
                } else {
                    self.observedOpenFASTTasks = []
                }
                self.openFASTScan = nil
            }
        }
    }

    private func sendToTrustedPeers() {
        guard enabled else { return }
        for session in sessions.values {
            sendApproval(to: session)
            sendSnapshot(to: session)
        }
    }

    private func sendSnapshot(to session: ClusterPeerSession) {
        guard enabled, session.remoteApproved,
              let hello = session.hello,
              trusted[hello.id] == hello.publicKey,
              let key = session.key,
              let sealed = try? ClusterSecureWire.seal(localNode, key: key),
              let packet = ClusterPacket.encode(
                type: ClusterPacket.telemetry, body: Data(sealed.dropFirst(4)))
        else { return }
        session.connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    /// Simulation lifecycle and progress are exclusively managed by external
    /// users/GPT tools. ChipBar only reads this optional small local file.
    private static func readExternalTasks() -> [ClusterTaskReadout] {
        guard let folder = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let url = folder.appendingPathComponent("ChipBar/cluster-status.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              fileSize <= 64 * 1024,
              let data = try? Data(contentsOf: url),
              data.count <= 64 * 1024 else { return [] }
        struct ExternalStatus: Decodable { let tasks: [ClusterTaskReadout] }
        guard let decoded = try? JSONDecoder().decode(ExternalStatus.self, from: data)
        else { return [] }
        return Array(decoded.tasks.prefix(12))
    }

    private static func identityKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let stored = readKeychain(account: identityAccount),
           let privateKey = try? Curve25519.KeyAgreement.PrivateKey(
               rawRepresentation: stored) { return privateKey }
        let generated = Curve25519.KeyAgreement.PrivateKey()
        _ = storeKeychain(generated.rawRepresentation, account: identityAccount)
        return generated
    }

    private static func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    private static func storeKeychain(_ data: Data, account: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        var record = identity
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let update = SecItemUpdate(identity as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update != errSecItemNotFound { return false }
        return SecItemAdd(record as CFDictionary, nil) == errSecSuccess
    }
}
