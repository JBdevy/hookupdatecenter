#if os(macOS)
import Foundation
import Network
import SystemConfiguration
import CryptoKit
import AppKit
import SwiftUI

struct ProjectSyncMessage: Codable {
    struct Tab: Codable { var project: UUID; var name: String; var transport: Data; var age: Double? = nil; var focusedRegion: UUID? = nil }
    var version = 1
    var type: String
    var node: UUID
    var name: String? = nil
    var role: String? = nil
    var request: UUID? = nil
    var nonce: UUID? = nil
    var proof: Data? = nil
    var token: String? = nil
    var independent: Bool? = nil
    var sequence: UInt64? = nil
    var time: Double? = nil
    var echo: Double? = nil
    var active: UUID? = nil
    var tabs: [Tab]? = nil
    var error: String? = nil
    var valid: Bool {
        version == 1 && ["hello","auth","pair","accepted","rejected","resume","resumed","ready","state","ping","pong","release","error"].contains(type) &&
        (name?.utf8.count ?? 0) <= 256 && (error?.utf8.count ?? 0) <= 1024 && (token?.utf8.count ?? 0) <= 128 &&
        (role == nil || role == "A" || role == "B") && (proof == nil || proof?.count == 32) &&
        (time == nil || (time!.isFinite && time! >= 0)) && (echo == nil || (echo!.isFinite && echo! >= 0)) &&
        (tabs?.count ?? 0) <= 64 && (tabs ?? []).allSatisfy { $0.name.utf8.count <= 512 && $0.transport.count <= 131072 && ($0.age == nil || ($0.age!.isFinite && $0.age! >= 0 && $0.age! <= 1)) } &&
        Set((tabs ?? []).map(\.project)).count == (tabs?.count ?? 0)
    }
}

// A direct cable normally gets IPv4 link-local addresses from the OS. If an
// adapter retains an old static configuration, add a temporary address instead
// of replacing its DHCP, gateway, DNS or the Wi-Fi configuration.
private enum ProjectSyncCable {
    struct Adapter: Sendable, Equatable { let name: String; let id: String; let title: String; let connected: Bool; let addresses: [String] }
    static func adapters(connectedOnly: Bool = true) -> [Adapter] {
        let hardware = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { value -> Adapter? in
            guard SCNetworkInterfaceGetInterfaceType(value) == kSCNetworkInterfaceTypeEthernet,
                  let name = SCNetworkInterfaceGetBSDName(value) as String? else { return nil }
            let link = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any]
            let connected = link?["Active"] as? Bool == true
            if connectedOnly && !connected { return nil }
            return Adapter(name: name, id: (SCNetworkInterfaceGetHardwareAddressString(value) as String?) ?? name,
                           title: (SCNetworkInterfaceGetLocalizedDisplayName(value) as String?) ?? name, connected: connected, addresses: [])
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String: [String]] = [:]
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee, name = String(cString: value.ifa_name)
            guard hardware.contains(where: { $0.name == name }), value.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = value.ifa_addr else { continue }
            if addresses[name] == nil { addresses[name] = [] }
            if address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name, default: []].append(String(cString: host))
                }
            }
        }
        return hardware.map { Adapter(name: $0.name, id: $0.id, title: $0.title, connected: $0.connected, addresses: addresses[$0.name] ?? []) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func prepare(node: UUID, selected: String) throws -> Bool {
        let values = adapters().filter { selected.isEmpty || $0.id == selected }
        if values.contains(where: { $0.addresses.contains(where: { $0.hasPrefix("169.254.") }) }) { return true }
        guard let adapter = values.first else { return false }
        // Only an OS-provided interface name enters the privileged command.
        guard adapter.name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil else { return false }
        let hash = Array(SHA256.hash(data: Data(node.uuidString.utf8)))
        let address = "169.254.\(1 + Int(hash[0]) % 254).\(1 + Int(hash[1]) % 254)"
        let command = "/sbin/ifconfig \(adapter.name) inet \(address) netmask 255.255.0.0 alias"
        let process = Process(), failure = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges with prompt \"O CatLive precisa preparar o adaptador Ethernet para conectar os dois computadores pelo cabo.\""]
        process.standardOutput = FileHandle.nullDevice; process.standardError = failure
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CatLive.ProjectSync.Cable", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "A preparação do cabo não foi autorizada. Clique em Buscar na rede para tentar novamente."])
        }
        return true
    }
}

// Hook Center also discovers the peer with small UDP broadcasts. Discovery
// contains no project/transport state; that only crosses the authenticated TCP
// connection after the user accepts pairing. Both sockets stay on Ethernet.
private final class ProjectSyncCableDiscovery: @unchecked Sendable {
    struct Peer: Sendable { var id: UUID; var name: String; var address: String; var port: UInt16; var seen: Double }
    private struct Beacon: Codable { var magic = "CATLIVE_PROJECT_SYNC"; var version = 1; var node: UUID; var name: String; var port: UInt16 }
    private let queue = DispatchQueue(label: "CatLive cable discovery", qos: .utility)
    private var timer: DispatchSourceTimer?, receiveFD: Int32 = -1, sendFD: Int32 = -1
    private var found: [UUID: Peer] = [:]
    func stop() { queue.async { self.close() } }
    private func close() {
        timer?.cancel(); timer = nil
        if receiveFD >= 0 { Darwin.close(receiveFD); receiveFD = -1 }
        if sendFD >= 0 { Darwin.close(sendFD); sendFD = -1 }
        found.removeAll()
    }
    func start(adapter: ProjectSyncCable.Adapter, node: UUID, name: String, port: UInt16,
               update: @escaping @Sendable ([Peer], Int32?) -> Void) {
        queue.async {
            self.close()
            var index = if_nametoindex(adapter.name), yes: Int32 = 1
            guard index != 0, let address = adapter.addresses.first(where: { $0.hasPrefix("169.254.") }) ?? adapter.addresses.first else { return }
            self.receiveFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            self.sendFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard self.receiveFD >= 0, self.sendFD >= 0 else { let error = errno; self.close(); update([], error); return }
            func option(_ fd: Int32, _ level: Int32, _ key: Int32, _ value: inout Int32) -> Bool {
                setsockopt(fd, level, key, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
            }
            var interface = Int32(index)
            guard option(self.receiveFD, IPPROTO_IP, IP_BOUND_IF, &interface), option(self.sendFD, IPPROTO_IP, IP_BOUND_IF, &interface),
                  option(self.receiveFD, SOL_SOCKET, SO_REUSEADDR, &yes), option(self.sendFD, SOL_SOCKET, SO_BROADCAST, &yes) else {
                let error = errno; self.close(); update([], error); return
            }
            func bindAddress(_ fd: Int32, _ ip: String, _ port: UInt16) -> Bool {
                var value = sockaddr_in(); value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); value.sin_family = sa_family_t(AF_INET); value.sin_port = port.bigEndian
                guard inet_pton(AF_INET, ip, &value.sin_addr) == 1 else { return false }
                return withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            }
            guard bindAddress(self.receiveFD, "0.0.0.0", 47839), bindAddress(self.sendFD, address, 0) else {
                let error = errno; self.close(); update([], error); return
            }
            _ = fcntl(self.receiveFD, F_SETFL, O_NONBLOCK)
            let beacon = try! JSONEncoder().encode(Beacon(node: node, name: String(name.prefix(80)), port: port))
            var destination = sockaddr_in(); destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET); destination.sin_port = UInt16(47839).bigEndian; destination.sin_addr.s_addr = INADDR_BROADCAST
            var lastSend = 0.0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for _ in 0..<32 {
                    var bytes = [UInt8](repeating: 0, count: 1025), source = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &source) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(self.receiveFD, &bytes, bytes.count, 0, $0, &length) } }
                    guard count > 0 else { break }
                    guard count <= 1024, let value = try? JSONDecoder().decode(Beacon.self, from: Data(bytes.prefix(count))),
                          value.magic == "CATLIVE_PROJECT_SYNC", value.version == 1, value.node != node, value.port > 0, value.name.utf8.count <= 256,
                          self.found.count < 32 || self.found[value.node] != nil else { continue }
                    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &source.sin_addr, &host, socklen_t(host.count)) != nil else { continue }
                    self.found[value.node] = Peer(id: value.node, name: value.name, address: String(cString: host), port: value.port, seen: now)
                }
                if now - lastSend >= 1 {
                    lastSend = now
                    let sent = beacon.withUnsafeBytes { bytes in withUnsafePointer(to: &destination) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(self.sendFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                    self.found = self.found.filter { now - $0.value.seen < 4 }
                    update(Array(self.found.values), sent < 0 ? errno : nil)
                }
            }
            self.timer = timer; timer.resume()
        }
    }
}

@MainActor final class ProjectSyncController: ObservableObject {
    static let shared = ProjectSyncController()
    struct Peer: Identifiable { var id: UUID; var name: String; var endpoint: NWEndpoint }
    private struct Pair: Codable { var id: UUID; var name: String; var role: String; var token: String }
    private final class Link {
        let id = UUID(), nonce = UUID()
        let channel: DAWRemoteChannel
        var node: UUID?, peerNonce: UUID?, name = ""
        var authenticated = false, ready = false, lastRx = ProcessInfo.processInfo.systemUptime
        var request: UUID?, desiredRole: String?, resuming = false, prompting = false
        var sequence: UInt64 = 0
        var latency = 0.005
        var applied: Set<UUID> = []
        init(_ channel: DAWRemoteChannel) { self.channel = channel }
    }
    struct CableOption: Identifiable { var id: String; var name: String; var connected: Bool }
    @Published private(set) var adapters: [CableOption] = []
    @Published private(set) var selectedAdapter = ""
    func chooseAdapter(_ id: String) {
        selectedAdapter = id; defaults.set(id, forKey: "catlive.sync.adapter")
        refreshCable(force: true)
    }
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var status = "Não pareado"
    @Published private(set) var preparingCable = false
    @Published private(set) var needsNetworkPermission = false
    @Published private(set) var following = false
    @Published private(set) var enabled = false
    var pairedName: String { pair?.name ?? "" }
    var role: String { pair?.role ?? "A" }
    var paired: Bool { pair != nil }
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "CatLive Project Sync", qos: .userInitiated)
    private let node: UUID
    private var pair: Pair?
    private var independent: Bool
    private var listener: NWListener?, timer: Timer?
    private let discovery = ProjectSyncCableDiscovery()
    private var cable: ProjectSyncCable.Adapter?
    private var checkingCable = false, lastCableCheck = 0.0
    private var links: [UUID: Link] = [:]
    private var active: Link?
    private var sent: UInt64 = 0
    private var lastPing = 0.0, lastConnect = 0.0
    private var leaderDevice = ""
    private var lastProblem = ""
    // Project Sync is wired-only. The regular Remote channel keeps its existing
    // Wi-Fi/peer-to-peer parameters for iPad and phone clients.
    private static func networkParameters() -> NWParameters {
        let value = NWParameters.tcp
        value.requiredInterfaceType = .wiredEthernet
        value.includePeerToPeer = false
        return value
    }
    private func connectionParameters() -> NWParameters {
        let parameters = Self.networkParameters()
        if let address = cable?.addresses.first(where: { $0.hasPrefix("169.254.") }) ?? cable?.addresses.first {
            parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
        }
        return parameters
    }
    private init() {
        node = defaults.string(forKey: "catlive.sync.node").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(node.uuidString, forKey: "catlive.sync.node")
        pair = defaults.data(forKey: "catlive.sync.pair").flatMap { try? JSONDecoder().decode(Pair.self, from: $0) }
        independent = defaults.bool(forKey: "catlive.sync.independent")
        selectedAdapter = defaults.string(forKey: "catlive.sync.adapter") ?? ""
        if pair != nil { status = independent ? "Independente · sincronize novamente" : "Aguardando computador pareado" }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if !value {
            if let active { send(.init(type: "release", node: node), on: active) }
            failover("Remote desativado · controle independente")
            listener?.cancel(); listener = nil; discovery.stop(); cable = nil
            for link in links.values { link.channel.close() }; links.removeAll(); active = nil
            peers = []; timer?.invalidate(); timer = nil; enabled = false; return
        }
        enabled = true
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
        search(prepareCable: false)
    }
    private func refreshCable(force: Bool = false) {
        guard enabled, !checkingCable else { return }
        checkingCable = true; lastCableCheck = ProcessInfo.processInfo.systemUptime
        Task {
            let adapters = await Task.detached(priority: .utility) { ProjectSyncCable.adapters(connectedOnly: false) }.value
            checkingCable = false
            guard enabled else { return }
            self.adapters = adapters.map { CableOption(id: $0.id, name: $0.title, connected: $0.connected) }
            let connected = adapters.filter { $0.connected && (selectedAdapter.isEmpty || $0.id == selectedAdapter) }
            let next = connected.first(where: { $0.name == cable?.name }) ?? connected.first
            guard next != cable || force || listener == nil else { return }
            if next != cable {
                failover("Cabo Ethernet desconectado · controle independente")
                for link in links.values { link.channel.close() }; links.removeAll(); active = nil
            }
            listener?.cancel(); listener = nil; discovery.stop(); cable = next; peers = []
            guard let next, let address = next.addresses.first(where: { $0.hasPrefix("169.254.") }) ?? next.addresses.first else {
                status = "Conecte os computadores por cabo Ethernet"; return
            }
            do {
                let parameters = Self.networkParameters()
                parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
                let server = try NWListener(using: parameters)
                server.newConnectionHandler = { [weak self] connection in DispatchQueue.main.async { self?.attach(connection, role: .host) } }
                server.stateUpdateHandler = { [weak self, weak server] state in
                    DispatchQueue.main.async {
                        guard let self, let server, self.listener === server else { return }
                        switch state {
                        case .ready:
                            guard let port = server.port else { return }
                            self.discovery.start(adapter: next, node: self.node, name: Host.current().localizedName ?? "Mac", port: port.rawValue) { [weak self] peers, error in
                                DispatchQueue.main.async {
                                    guard let self, self.enabled, self.cable == next else { return }
                                    if let error {
                                        self.needsNetworkPermission = error == EACCES || error == EPERM
                                        self.status = self.needsNetworkPermission ? "Permita o acesso do CatLive à Rede Local nos Ajustes do Sistema e busque novamente." : "Não foi possível buscar pelo cabo Ethernet (\(error))."
                                    } else {
                                        self.needsNetworkPermission = false
                                        self.peers = peers.map { Peer(id: $0.id, name: $0.name, endpoint: .hostPort(host: .init($0.address), port: .init(rawValue: $0.port)!)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                                    }
                                }
                            }
                        case .failed(let error): self.status = error.localizedDescription
                        default: break
                        }
                    }
                }
                listener = server; server.start(queue: queue)
                status = independent ? "Independente · sincronize novamente" : "Buscando computadores pelo cabo Ethernet"
            } catch { status = error.localizedDescription }
        }
    }
    func search(prepareCable: Bool = true) {
        guard !preparingCable else { return }
        if prepareCable {
            preparingCable = true; status = "Preparando conexão pelo cabo Ethernet…"
            let identity = node, selected = selectedAdapter
            Task {
                do {
                    let ready = try await Task.detached(priority: .userInitiated) { try ProjectSyncCable.prepare(node: identity, selected: selected) }.value
                    preparingCable = false
                    guard enabled else { return }
                    if ready { refreshCable(force: true) }
                    else { status = "Conecte os computadores por cabo Ethernet" }
                } catch { preparingCable = false; status = error.localizedDescription }
            }
            return
        }
        guard enabled else { status = "Ative o Remote para buscar computadores"; return }
        needsNetworkPermission = false
        refreshCable(force: active == nil)
    }
    func request(_ peer: Peer, role: String) {
        guard enabled, role == "A" || role == "B", !following else { return }
        let connection = NWConnection(to: peer.endpoint, using: connectionParameters())
        let link = attach(connection, role: .client)
        link.desiredRole = role; link.request = UUID(); status = "Aguardando aceitação em " + peer.name
    }
    func resume() {
        guard let active, active.authenticated, pair != nil else { status = "Aguardando computador pareado"; return }
        active.request = UUID(); active.resuming = true
        send(.init(type: "resume", node: node, request: active.request), on: active)
        status = "Aguardando confirmação para sincronizar"
    }
    @discardableResult private func attach(_ connection: NWConnection, role: DAWRemoteRole) -> Link {
        let channel = DAWRemoteChannel(connection: connection, role: role, name: Host.current().localizedName ?? "Mac", queue: queue)
        let link = Link(channel); links[link.id] = link
        if links.count > 8 { channel.close(); links.removeValue(forKey: link.id); return link }
        channel.onReady = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.send(.init(type: "hello", node: self.node, name: Host.current().localizedName ?? "Mac", role: self.pair?.role, nonce: link.nonce, independent: self.independent), on: link)
        }
        channel.onPacket = { [weak self, weak link] packet in
            guard let self, let link, case .projectSync(let data) = packet,
                  let message = try? JSONDecoder().decode(ProjectSyncMessage.self, from: data), message.valid else { return }
            self.receive(message, on: link)
        }
        channel.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.links.removeValue(forKey: link.id)
            if self.active === link { self.failover("Conexão perdida · controle independente"); self.active = nil }
        }
        channel.start(); return link
    }
    private func send(_ message: ProjectSyncMessage, on link: Link) {
        guard let data = try? JSONEncoder().encode(message), let packet = try? DAWRemoteWire.projectSync(data) else { return }
        link.channel.send(packet)
    }
    private func proof(for link: Link, token: String) -> Data? {
        guard let remote = link.node, let nonce = link.peerNonce else { return nil }
        let ids = [node.uuidString, remote.uuidString].sorted()
        let nonces = [link.nonce.uuidString, nonce.uuidString].sorted()
        let text = "CatLive Project Sync 1|" + ids.joined(separator: "|") + "|" + nonces.joined(separator: "|") + "|" + link.channel.sessionBinding.map { String(format: "%02x", $0) }.joined()
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(token.utf8))))
    }
    private func persistPair(_ value: Pair) {
        pair = value; defaults.set(try? JSONEncoder().encode(value), forKey: "catlive.sync.pair")
        independent = false; defaults.set(false, forKey: "catlive.sync.independent")
        leaderDevice = AudioDeviceSettings.shared.selectedUID
    }
    private func authenticate(_ link: Link) {
        if let active, active !== link { active.channel.close() }
        active = link; link.authenticated = true; link.lastRx = ProcessInfo.processInfo.systemUptime
        status = independent ? "Independente · sincronize novamente" : "Pareado · PC " + role
        if role == "B", !independent { send(.init(type: "ready", node: node), on: link) }
    }
    private func confirm(_ message: String, link: Link, completion: @escaping (Bool) -> Void) {
        guard !link.prompting, let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) else { completion(false); return }
        link.prompting = true
        let alert = NSAlert(); alert.messageText = "Project Sync"; alert.informativeText = message
        alert.addButton(withTitle: JarasLocalization.string("Aceitar")); alert.addButton(withTitle: JarasLocalization.string("Cancelar"))
        alert.beginSheetModal(for: window) { [weak link] response in
            link?.prompting = false; completion(response == .alertFirstButtonReturn)
        }
    }
    private func receive(_ m: ProjectSyncMessage, on link: Link) {
        guard m.node != node else { link.channel.close(); return }
        if m.type == "hello" {
            guard link.node == nil, let nonce = m.nonce else { return }
            link.node = m.node; link.peerNonce = nonce; link.name = m.name ?? "CatLive"
            if let desired = link.desiredRole, let request = link.request {
                send(.init(type: "pair", node: node, role: desired, request: request), on: link)
            } else if let pair, pair.id == m.node, let proof = proof(for: link, token: pair.token) {
                send(.init(type: "auth", node: node, role: role, proof: proof, independent: independent), on: link)
            }
            return
        }
        guard link.node == m.node else { return }
        if m.type == "pair", let requested = m.role, let request = m.request, !following {
            guard !link.prompting else { return }
            let localRole = requested == "A" ? "B" : "A"
            confirm(link.name + " solicita o pareamento. Este computador será o PC " + localRole + ".", link: link) { [weak self, weak link] accepted in
                guard let self, let link, self.links[link.id] != nil else { return }
                guard accepted else { self.send(.init(type: "rejected", node: self.node, request: request), on: link); return }
                let token = UUID().uuidString + UUID().uuidString
                self.persistPair(.init(id: m.node, name: link.name, role: localRole, token: token))
                self.send(.init(type: "accepted", node: self.node, role: localRole, request: request, token: token), on: link)
                self.authenticate(link)
            }; return
        }
        if m.type == "accepted", m.request == link.request, let desired = link.desiredRole,
           m.role != desired, let token = m.token, token.count >= 64 {
            persistPair(.init(id: m.node, name: link.name, role: desired, token: token)); link.request = nil; link.desiredRole = nil
            authenticate(link); return
        }
        if m.type == "rejected", m.request == link.request { status = "Pareamento recusado"; link.request = nil; return }
        if m.type == "auth", let pair, pair.id == m.node, m.role != pair.role,
           let expected = proof(for: link, token: pair.token), let received = m.proof,
           expected.count == received.count, zip(expected,received).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 {
            authenticate(link)
            if m.independent == true { status = "Computador pareado independente · sincronize novamente" }
            return
        }
        guard link.authenticated, active === link, pair?.id == m.node else { return }
        link.lastRx = ProcessInfo.processInfo.systemUptime
        switch m.type {
        case "resume":
            guard let request = m.request else { return }
            confirm(link.name + " deseja sincronizar novamente os projetos.", link: link) { [weak self, weak link] ok in
                guard let self, let link, ok, self.active === link else { return }
                self.independent = false; self.defaults.set(false, forKey: "catlive.sync.independent")
                self.leaderDevice = AudioDeviceSettings.shared.selectedUID; link.applied = []
                self.send(.init(type: "resumed", node: self.node, request: request), on: link)
                if self.role == "B" { self.send(.init(type: "ready", node: self.node), on: link) }
            }
        case "resumed":
            guard link.resuming, m.request == link.request else { return }
            link.resuming = false; link.request = nil; independent = false; defaults.set(false, forKey: "catlive.sync.independent")
            leaderDevice = AudioDeviceSettings.shared.selectedUID; link.applied = []
            if role == "B" { send(.init(type: "ready", node: node), on: link) }
        case "ready": if role == "A", !independent { link.ready = true; leaderDevice = AudioDeviceSettings.shared.selectedUID; status = "PC A · sincronizando" }
        case "ping": send(.init(type: "pong", node: node, echo: m.time), on: link)
        case "pong": if let echo = m.echo { let rtt = ProcessInfo.processInfo.systemUptime - echo; if rtt >= 0 && rtt < 1 { link.latency = min(0.25, rtt / 2) } }
        case "release": failover("PC A indisponível · controle independente")
        case "error": status = m.error ?? "Abra o mesmo projeto no outro computador"
        case "state":
            guard role == "B", !independent, let sequence = m.sequence, sequence > link.sequence, let tabs = m.tabs else { return }
            link.sequence = sequence
            let open = DesktopProjectTabs.shared.projects
            var problems: [String] = []
            for tab in tabs {
                guard let target = open.first(where: { $0.documents.ready && $0.show.snapshot.project.projectSyncID == tab.project }) else { problems.append(tab.name); continue }
                do {
                    try target.show.applyProjectSync(tab.transport, elapsed: min(1, link.latency + (tab.age ?? 0)), first: !link.applied.contains(tab.project), focused: tab.focusedRegion)
                    link.applied.insert(tab.project)
                } catch { problems.append(tab.name) }
            }
            if let id = m.active, let index = open.firstIndex(where: { $0.show.snapshot.project.projectSyncID == id }) { if DesktopProjectTabs.shared.selected != index { DesktopProjectTabs.shared.select(index) } }
            if !link.applied.isEmpty { setFollowing(true) }
            if !problems.isEmpty {
                let text = "Abra este projeto também no PC B: " + problems.joined(separator: ", ")
                status = text
                if lastProblem != text { lastProblem = text; send(.init(type: "error", node: node, error: text), on: link) }
            } else { lastProblem = ""; status = "PC B · seguindo o PC A" }
        default: break
        }
    }
    private func setFollowing(_ value: Bool) {
        if value && !following { FXWindows.shared.closeAll() }
        following = value; ProjectSyncControl.following = value; JarasCoreBridge.setProjectSyncFollowing(value)
    }
    private func failover(_ reason: String) {
        if following || active?.ready == true {
            independent = true; defaults.set(true, forKey: "catlive.sync.independent")
        }
        setFollowing(false); active?.ready = false; active?.applied = []; status = reason
        // Deliberately do not send Stop, reload the project or close the device.
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCableCheck > 1 { refreshCable() }
        for link in links.values where !link.authenticated && !link.prompting && now - link.lastRx > 45 { link.channel.close() }
        guard let active, active.authenticated else {
            if let pair, now-lastConnect > 4, node.uuidString < pair.id.uuidString,
               let peer = peers.first(where: { $0.id == pair.id }), links.isEmpty {
                lastConnect = now; attach(NWConnection(to: peer.endpoint, using: connectionParameters()), role: .client)
            }; return
        }
        if now-active.lastRx > 1.5 { failover("Conexão perdida · controle independente"); active.channel.close(); return }
        if now-lastPing > 0.4 { lastPing = now; send(.init(type: "ping", node: node, time: now), on: active) }
        guard role == "A", active.ready, !independent else { return }
        let settings = AudioDeviceSettings.shared
        guard settings.outputDeviceIsBound, settings.selectedUID == leaderDevice else {
            send(.init(type: "release", node: node), on: active); failover("Interface de áudio indisponível · PC B independente"); return
        }
        let projects = DesktopProjectTabs.shared.projects
        guard let current = DesktopProjectTabs.shared.active, current.documents.ready else { return }
        guard let id = current.show.snapshot.project.projectSyncID else { status = "Salve o projeto uma vez para habilitar o Project Sync"; return }
        let tabs = projects.filter { $0.documents.ready }.compactMap { project -> ProjectSyncMessage.Tab? in
            guard let id = project.show.snapshot.project.projectSyncID, let data = try? project.show.projectSyncFrame() else { return nil }
            return .init(project: id, name: project.show.snapshot.project.name, transport: data, age: project.show.isPlaying ? min(1, max(0, now - project.show.timelinePlaybackSampleTime)) : 0, focusedRegion: project.show.focusedRegion)
        }
        sent &+= 1; send(.init(type: "state", node: node, sequence: sent, time: now, active: id, tabs: tabs), on: active)
    }
}

struct ProjectSyncPanel: View {
    @ObservedObject private var sync = ProjectSyncController.shared
    @State private var selected = ""
    @State private var role = "A"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Project Sync").font(.jarasHeadline)
            Text("Conecte os dois computadores por cabo Ethernet. O Remote do app continua disponível pelo Wi-Fi.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            Text(LocalizedStringKey(sync.status)).font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            if sync.paired { Text(verbatim: "PC " + sync.role + " · " + sync.pairedName).font(.jarasCaption) }
            Picker("Adaptador Ethernet", selection: Binding(get: { sync.selectedAdapter }, set: { sync.chooseAdapter($0) })) {
                Text("Automático").tag("")
                if !sync.selectedAdapter.isEmpty && !sync.adapters.contains(where: { $0.id == sync.selectedAdapter }) {
                    Text("Adaptador desconectado").tag(sync.selectedAdapter)
                }
                ForEach(sync.adapters) { adapter in
                    Text(verbatim: adapter.name + (adapter.connected ? "" : " · " + JarasLocalization.string("Desconectado"))).tag(adapter.id)
                }
            }.disabled(sync.preparingCable)
            Button("Buscar na rede") {
                DAWRemoteSession.shared.setHostEnabled(true); sync.search()
            }
            .disabled(sync.preparingCable)
            if sync.preparingCable { ProgressView().controlSize(.small) }
            if sync.needsNetworkPermission {
                Button("Abrir ajustes de Rede Local") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
                }
            }
            if !sync.peers.isEmpty {
                Picker("Computador", selection: $selected) {
                    Text("Selecione um computador").tag("")
                    ForEach(sync.peers) { peer in Text(verbatim: peer.name).tag(peer.id.uuidString) }
                }
                Picker("Este computador", selection: $role) {
                    Text(verbatim: "PC A").tag("A"); Text(verbatim: "PC B").tag("B")
                }.pickerStyle(.segmented)
                Button("Solicitar pareamento") {
                    if let peer = sync.peers.first(where: { $0.id.uuidString == selected }) { sync.request(peer, role: role) }
                }.disabled(selected.isEmpty || sync.following)
            }
            if sync.paired { Button("Sincronizar novamente") { sync.resume() } }
            Text("PC A controla o transporte. PC B continua tocando de forma independente se o A falhar.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
        }
    }
}
#endif
