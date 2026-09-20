import Foundation
import Network
import Darwin

private let serviceType = "_vshook._tcp"
private let queue = DispatchQueue(label: "com.hookdeveloper.hookcenter.apple-peer")

private struct Configuration {
    let directorPort: UInt16
    let musiciansPort: UInt16
    let serviceName: String

    static func read() -> Configuration {
        var directorPort: UInt16 = 47831
        var musiciansPort: UInt16 = 47832
        var serviceName = Host.current().localizedName ?? "Hook Center"
        var index = 1
        let arguments = CommandLine.arguments
        while index < arguments.count {
            let key = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch key {
            case "--director-port": directorPort = UInt16(value) ?? directorPort
            case "--musicians-port": musiciansPort = UInt16(value) ?? musiciansPort
            case "--name": serviceName = value
            default: index -= 1
            }
            index += 2
        }
        let cleaned = serviceName
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Configuration(
            directorPort: directorPort,
            musiciansPort: musiciansPort,
            serviceName: String((cleaned.isEmpty ? "Hook Center" : cleaned).prefix(58))
        )
    }
}

private final class PeerForwardTunnel {
    private let peer: NWConnection
    private let config: Configuration
    private var upstream: NWConnection?
    private var handshake = Data()
    private var closed = false
    var onClose: (() -> Void)?

    init(peer: NWConnection, config: Configuration) {
        self.peer = peer
        self.config = config
    }

    func start() {
        peer.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.close() }
            if case .cancelled = state { self.close() }
        }
        peer.start(queue: queue)
        readHandshake()
    }

    private func readHandshake() {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.handshake.append(data) }
            if self.handshake.count > 8192 {
                self.close()
                return
            }
            if let newline = self.handshake.firstIndex(of: 0x0a) {
                let headerData = self.handshake.prefix(upTo: newline)
                let remainderStart = self.handshake.index(after: newline)
                let remainder = Data(self.handshake.suffix(from: remainderStart))
                let header = String(data: headerData, encoding: .utf8) ?? ""
                self.openUpstream(header: header, initialData: remainder)
                return
            }
            if complete || error != nil { self.close() }
            else { self.readHandshake() }
        }
    }

    private func openUpstream(header: String, initialData: Data) {
        let parts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "VSHOOK/1" else {
            close()
            return
        }
        let channel = String(parts[1]).lowercased()
        let targetPort = channel == "musicians" ? config.musiciansPort :
            (channel == "director" ? config.directorPort : 0)
        guard targetPort > 0, let port = NWEndpoint.Port(rawValue: targetPort) else {
            close()
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                let beginPipes = {
                    self.pipe(from: self.peer, to: connection)
                    self.pipe(from: connection, to: self.peer)
                }
                if initialData.isEmpty {
                    beginPipes()
                } else {
                    connection.send(content: initialData, completion: .contentProcessed { error in
                        if error == nil { beginPipes() } else { self.close() }
                    })
                }
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || complete || error != nil { self.close() }
                    else { self.pipe(from: source, to: destination) }
                })
            } else if complete || error != nil {
                self.close()
            } else {
                self.pipe(from: source, to: destination)
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        peer.cancel()
        upstream?.cancel()
        onClose?()
        onClose = nil
    }
}

private final class PeerBridgeServer {
    private let config: Configuration
    private let listener: NWListener
    private var tunnels: [ObjectIdentifier: PeerForwardTunnel] = [:]

    init(config: Configuration) throws {
        self.config = config
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: config.serviceName, type: serviceType)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                FileHandle.standardOutput.write(Data("READY\n".utf8))
            case .failed(let error):
                FileHandle.standardError.write(Data("FAILED \(error)\n".utf8))
                exit(2)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let tunnel = PeerForwardTunnel(peer: connection, config: self.config)
            let key = ObjectIdentifier(tunnel)
            self.tunnels[key] = tunnel
            tunnel.onClose = { [weak self] in self?.tunnels.removeValue(forKey: key) }
            tunnel.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        tunnels.values.forEach { $0.onClose = nil }
        tunnels.removeAll()
    }
}

private let configuration = Configuration.read()
do {
    let server = try PeerBridgeServer(config: configuration)
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    termination.setEventHandler {
        server.stop()
        exit(0)
    }
    termination.resume()
    server.start()
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("FAILED \(error)\n".utf8))
    exit(1)
}
