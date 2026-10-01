import SwiftUI
import Network
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DAWRemotePeer: Hashable { let id: String; let displayName: String }
enum DAWRemoteRole: UInt8 { case host = 1, client = 2 }

private func remoteName(_ value: String) -> String {
    var name = ""
    for character in value.prefix(40) {
        guard name.utf8.count + String(character).utf8.count <= 160 else { break }
        name.append(character)
    }
    return name.isEmpty ? "Jaras" : name
}

/// TCP may split a packet anywhere or deliver several together. Reject its
/// declared length before allocating a payload.
struct DAWRemoteFrames {
    static let maximum = DAWRemoteWire.maximumPacket + 64
    private var buffer = Data()
    mutating func receive(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= Self.maximum + 4, buffer.count <= Self.maximum + 4 else { throw DAWRemoteWire.Failure.invalid }
        buffer.append(bytes)
        var offset = 0, result: [Data] = []
        while buffer.count - offset >= 4 {
            let length = buffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            guard length > 0, length <= Self.maximum else { throw DAWRemoteWire.Failure.invalid }
            guard buffer.count - offset - 4 >= length else { break }
            result.append(buffer.subdata(in: (offset + 4)..<(offset + 4 + length)))
            offset += 4 + length
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        guard buffer.count <= Self.maximum + 4 else { throw DAWRemoteWire.Failure.invalid }
        return result
    }
    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximum else { throw DAWRemoteWire.Failure.invalid }
        var size = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }; data.append(payload)
        return data
    }
}

/// Fresh keys for each direct connection. Application packets are always
/// authenticated and encrypted; direction-specific keys and counters reject
/// reflection and replay. Like the previous automatic invitation, discovery
/// identifies the selected nearby device without a provisioned identity.
final class DAWRemoteCipher {
    private let key = Curve25519.KeyAgreement.PrivateKey()
    private let role: DAWRemoteRole
    private let name: String
    private var outgoing: SymmetricKey?
    private var incoming: SymmetricKey?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    init(role: DAWRemoteRole, name: String) { self.role = role; self.name = remoteName(name) }
    func hello() -> Data {
        var data = Data([0x4a, 0x44, 1, DAWRemoteWire.version, role.rawValue])
        data.append(key.publicKey.rawRepresentation); data.append(Data(name.utf8))
        return data
    }
    func accept(_ hello: Data) throws -> String {
        guard incoming == nil, hello.count >= 38, hello.count <= 197,
              Array(hello.prefix(4)) == [0x4a, 0x44, 1, DAWRemoteWire.version],
              let peerRole = DAWRemoteRole(rawValue: hello[4]), peerRole != role,
              let peerName = String(data: hello.dropFirst(37), encoding: .utf8), !peerName.isEmpty else { throw DAWRemoteWire.Failure.invalid }
        let peerBytes = hello.subdata(in: 5..<37)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBytes)
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        var transcript = Data("Jaras Live Direct 1".utf8)
        transcript.append(role == .host ? self.hello() : hello)
        transcript.append(role == .host ? hello : self.hello())
        let salt = Data(SHA256.hash(data: transcript))
        let toClient = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("host-to-client".utf8), outputByteCount: 32)
        let toHost = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("client-to-host".utf8), outputByteCount: 32)
        outgoing = role == .host ? toClient : toHost; incoming = role == .host ? toHost : toClient
        return peerName
    }
    private func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var counter = counter.bigEndian
        var bytes = Data(repeating: 0, count: 4); withUnsafeBytes(of: &counter) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
    func seal(_ payload: Data) throws -> Data {
        guard let outgoing, sent < UInt64.max, !payload.isEmpty, payload.count <= DAWRemoteWire.maximumPacket + 1 else { throw DAWRemoteWire.Failure.invalid }
        sent += 1
        var counter = sent.bigEndian
        var header = Data([2]); withUnsafeBytes(of: &counter) { header.append(contentsOf: $0) }
        let sealed = try ChaChaPoly.seal(payload, using: outgoing, nonce: nonce(sent), authenticating: header)
        var result = header; result.append(sealed.ciphertext); result.append(sealed.tag)
        return result
    }
    func open(_ envelope: Data) throws -> Data {
        guard let incoming, envelope.count >= 26, envelope.count <= DAWRemoteFrames.maximum, envelope[0] == 2,
              received < UInt64.max else { throw DAWRemoteWire.Failure.invalid }
        let counter = envelope.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self)) }
        guard counter == received + 1 else { throw DAWRemoteWire.Failure.invalid }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: envelope.subdata(in: 9..<(envelope.count - 16)), tag: envelope.suffix(16))
        let payload = try ChaChaPoly.open(box, using: incoming, authenticating: envelope.prefix(9))
        received = counter
        return payload
    }
}

private func remoteMain(_ body: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, body)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// Same Network.framework peer-to-peer path as VS Hook, carrying native
/// Remote packets directly. All mutable transport fields belong to queue.
final class DAWRemoteChannel {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let cipher: DAWRemoteCipher
    private var frames = DAWRemoteFrames()
    private var receivedHello = false
    private var ready = false
    private var closed = false
    private var name = ""
    private var pendingBytes = 0
    private var timeout: DispatchWorkItem?
    var onReady: ((String) -> Void)?
    var onPacket: ((DAWRemoteWire.Packet) -> Void)?
    var onClose: (() -> Void)?
    init(connection: NWConnection, role: DAWRemoteRole, name: String, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue; cipher = DAWRemoteCipher(role: role, name: name)
    }
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                do { self.write(try DAWRemoteFrames.encode(self.cipher.hello())); self.read() }
                catch { self.finish() }
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.start(queue: queue)
    }
    func send(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard self.ready, !self.closed, data.count <= DAWRemoteWire.maximumPacket else {
                if let completion { remoteMain { completion(false) } }; return
            }
            do {
                var payload = Data([1]); payload.append(data)
                self.write(try DAWRemoteFrames.encode(self.cipher.seal(payload)), completion: completion)
            } catch { self.finish(); if let completion { remoteMain { completion(false) } } }
        }
    }
    func close() { queue.async { self.finish() } }
    private func write(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        guard !closed, pendingBytes + data.count <= 4 * DAWRemoteFrames.maximum else {
            finish(); if let completion { remoteMain { completion(false) } }; return
        }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            if error != nil { self.finish() }
            if let completion { remoteMain { completion(error == nil) } }
        })
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let bytes {
                    for packet in try self.frames.receive(bytes) {
                        if !self.receivedHello {
                            self.name = try self.cipher.accept(packet); self.receivedHello = true
                            self.write(try DAWRemoteFrames.encode(self.cipher.seal(Data([0]))))
                        } else {
                            let payload = try self.cipher.open(packet)
                            if !self.ready {
                                guard payload == Data([0]) else { throw DAWRemoteWire.Failure.invalid }
                                self.ready = true; self.timeout?.cancel(); self.timeout = nil
                                if let callback = self.onReady { let name = self.name; remoteMain { callback(name) } }
                            } else {
                                guard payload.first == 1, payload.count > 1 else { throw DAWRemoteWire.Failure.invalid }
                                let decoded = try DAWRemoteWire.decode(Data(payload.dropFirst()))
                                if let callback = self.onPacket { remoteMain { callback(decoded) } }
                            }
                        }
                    }
                }
                if complete || error != nil { self.finish() } else { self.read() }
            } catch { self.finish() }
        }
    }
    private func finish() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); timeout = nil; connection.cancel()
        if let callback = onClose { remoteMain(callback) }
    }
}

/// Still images are derived only when requested. ImageIO never opens a video
/// decoder, and multiframe/animated images are excluded as well.
enum DAWRemoteStillImage {
    enum Source { case file(URL), bytes(Data) }
    static let edge = 1600
    static func supports(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
    static func prepare(_ input: Source) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        switch input {
        case .file(let url):
            guard supports(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 64 * 1024 * 1024 else { return nil }
            source = CGImageSourceCreateWithURL(url as CFURL, options)
        case .bytes(let data):
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, options)
        }
        guard let source, CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              Int64(width) * Int64(height) <= 268_435_456 else { return nil }
        for dimension in [edge, 1280, 1024, 768, 512] {
            let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
            let alpha = image.alphaInfo == .first || image.alphaInfo == .last || image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
            let types = alpha ? [UTType.png] : (type as String == UTType.png.identifier ? [.png, .jpeg] : [.jpeg])
            for type in types {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= DAWRemoteImageAsset.maximumBytes {
                    return output as Data
                }
            }
        }
        return nil
    }
    static func valid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= DAWRemoteImageAsset.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...edge).contains(width) && (1...edge).contains(height)
    }
}

/// Small deterministic LRU; image data is never part of the 10 Hz state packet.
final class DAWRemoteImageCache {
    private var values: [UUID: Data] = [:]
    private var order: [UUID] = []
    private(set) var bytes = 0
    let limit: Int
    init(limit: Int = 32 * 1024 * 1024) { self.limit = limit }
    func data(_ id: UUID) -> Data? {
        guard let data = values[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return data
    }
    func insert(_ data: Data, id: UUID) {
        if let old = values.removeValue(forKey: id) { bytes -= old.count }
        order.removeAll { $0 == id }
        guard !data.isEmpty, data.count <= limit else { return }
        while bytes + data.count > limit || order.count >= 32 {
            let removed = order.removeFirst(); bytes -= values.removeValue(forKey: removed)?.count ?? 0
        }
        values[id] = data; order.append(id); bytes += data.count
    }
    func clear() { values = [:]; order = []; bytes = 0 }
}

/// Nearby discovery, one encrypted client, and bounded state/ACK flow.
final class DAWRemoteSession: NSObject, ObservableObject {
    #if os(macOS)
    static let shared = DAWRemoteSession(role: .host, name: Host.current().localizedName ?? "Jaras Mac")
    #else
    static let shared = DAWRemoteSession(role: .client, name: UIDevice.current.name)
    #endif
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var peers: [DAWRemotePeer] = []
    @Published private(set) var peerName = ""
    @Published private(set) var status = ""
    @Published private(set) var remoteState: DAWRemoteState?
    @Published private(set) var imageRevision: UInt64 = 0
    private let worker = DispatchQueue(label: "com.jaras.remote.state", qos: .userInitiated)
    private let imageWorker = DispatchQueue(label: "com.jaras.remote.still-images", qos: .utility)
    private let role: DAWRemoteRole
    private let name: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var channel: DAWRemoteChannel?
    private var connectionGeneration = UUID()
    var stateProvider: (() -> DAWRemoteState?)?
    var commandHandler: ((DAWRemoteCommand) -> Void)?
    private var stateTimer: Timer?
    private var sendingState = false
    private var waitingForState: UInt64?
    private var sentAt = Date.distantPast
    private var stateSequence: UInt64 = 0
    private var receivedStateSequence: UInt64 = 0
    private var handledCommands: [UUID] = []
    private var invitationAttempts: [Date] = []
    private var imageProject: UUID?
    private var imageKeys: [String: UUID] = [:]
    private var imageSources: [UUID: DAWRemoteStillImage.Source] = [:]
    private var imageSourceOrder: [UUID] = []
    private var imageSourceBytes = 0
    private let images = DAWRemoteImageCache()
    private var imagePending: Set<UUID> = []
    private var imageFailed: Set<UUID> = []
    private var imageQueue: [UUID] = []

    init(role: DAWRemoteRole, name: String) {
        self.role = role; self.name = remoteName(name)
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
    }
    /// Called by the host presentation builder with a known static media URL.
    /// Registration is metadata-only: no image is read or decoded here.
    func imageID(for url: URL, project: UUID) -> UUID? {
        guard role == .host, DAWRemoteStillImage.supports(url) else { return nil }
        return registerImage(.file(url.standardizedFileURL), key: "file:" + url.standardizedFileURL.path, project: project)
    }
    /// The caller supplies a stable revision key, such as a notice's send time.
    /// This avoids hashing or decoding the same notice image on every snapshot.
    func imageID(for data: Data, project: UUID, key: String) -> UUID? {
        guard role == .host, !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        return registerImage(.bytes(data), key: "data:" + key, project: project)
    }
    private func registerImage(_ source: DAWRemoteStillImage.Source, key: String, project: UUID) -> UUID {
        setImageProject(project)
        if let id = imageKeys[key] {
            imageSourceOrder.removeAll { $0 == id }; imageSourceOrder.append(id)
            return id
        }
        let cost: Int
        if case .bytes(let data) = source { cost = data.count } else { cost = 0 }
        while imageSourceOrder.count >= 64 || imageSourceBytes + cost > 32 * 1024 * 1024 {
            let removed = imageSourceOrder.removeFirst()
            if case .bytes(let data) = imageSources.removeValue(forKey: removed) { imageSourceBytes -= data.count }
            imageKeys = imageKeys.filter { $0.value != removed }
            imageFailed.remove(removed)
        }
        let id = UUID(); imageKeys[key] = id; imageSources[id] = source
        imageSourceOrder.append(id); imageSourceBytes += cost
        return id
    }
    func imageData(id: UUID, project: UUID) -> Data? { imageProject == project ? images.data(id) : nil }
    func imageUnavailable(id: UUID, project: UUID) -> Bool { imageProject == project && imageFailed.contains(id) }
    func requestImage(id: UUID, project: UUID) {
        guard role == .client, connected, remoteState?.project == project, imageProject == project,
              images.data(id) == nil, !imageFailed.contains(id), !imagePending.contains(id),
              !imageQueue.contains(id), imageQueue.count < 32 else { return }
        imageQueue.append(id); sendImageRequests()
    }
    private func sendImageRequests() {
        guard role == .client, connected, let project = imageProject else { return }
        while imagePending.count < 2, !imageQueue.isEmpty {
            let id = imageQueue.removeFirst(); imagePending.insert(id)
            send(.init(project: project, action: .requestImage, target: id))
        }
    }
    private func setImageProject(_ project: UUID?) {
        guard imageProject != project else { return }
        imageProject = project; images.clear(); imagePending = []; imageFailed = []; imageQueue = []
        imageKeys = [:]; imageSources = [:]; imageSourceOrder = []; imageSourceBytes = 0
        imageRevision &+= 1
    }
    private func failedImage(_ id: UUID) {
        if imageFailed.count >= 128, let oldest = imageFailed.first { imageFailed.remove(oldest) }
        imageFailed.insert(id)
    }
    private func serveImage(_ command: DAWRemoteCommand, to channel: DAWRemoteChannel) {
        guard let id = command.target, command.project == imageProject else { return }
        func unavailable() {
            if let packet = try? DAWRemoteWire.imageAsset(.init(project: command.project, id: id, data: Data())) { channel.send(packet) }
        }
        guard let source = imageSources[id] else { unavailable(); return }
        if let data = images.data(id) {
            if let packet = try? DAWRemoteWire.imageAsset(.init(project: command.project, id: id, data: data)) { channel.send(packet) }
            return
        }
        if imageFailed.contains(id) { unavailable(); return }
        guard !imagePending.contains(id) else { return }
        guard imagePending.count < 4 else { unavailable(); return }
        imagePending.insert(id)
        let generation = connectionGeneration
        imageWorker.async { [weak self, weak channel] in
            let data = autoreleasepool { DAWRemoteStillImage.prepare(source) ?? Data() }
            remoteMain {
                guard let self, let channel, self.channel === channel, self.connected,
                      self.connectionGeneration == generation, self.imageProject == command.project else { return }
                self.imagePending.remove(id)
                guard self.imageSources[id] != nil else {
                    if let packet = try? DAWRemoteWire.imageAsset(.init(project: command.project, id: id, data: Data())) { channel.send(packet) }
                    return
                }
                if data.isEmpty { self.failedImage(id) } else { self.images.insert(data, id: id) }
                if let packet = try? DAWRemoteWire.imageAsset(.init(project: command.project, id: id, data: data)) { channel.send(packet) }
            }
        }
    }
    private func receiveImage(_ asset: DAWRemoteImageAsset, from source: DAWRemoteChannel) {
        guard role == .client, asset.project == imageProject, imagePending.contains(asset.id) else { return }
        let generation = connectionGeneration
        imageWorker.async { [weak self, weak source] in
            let valid = autoreleasepool { DAWRemoteStillImage.valid(asset.data) }
            remoteMain {
                guard let self, let source, self.channel === source, self.connected,
                      self.connectionGeneration == generation, self.imageProject == asset.project,
                      self.imagePending.remove(asset.id) != nil else { return }
                if valid { self.images.insert(asset.data, id: asset.id) } else { self.failedImage(asset.id) }
                self.imageRevision &+= 1
                self.sendImageRequests()
            }
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        connectionGeneration = UUID()
        stateTimer?.invalidate(); stateTimer = nil; waitingForState = nil; sendingState = false
        handledCommands.removeAll()
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        channel?.close(); channel = nil; endpoints = [:]
        enabled = false; connected = false; connecting = false; remoteState = nil; receivedStateSequence = 0
        peers = []; peerName = ""; status = ""
        setImageProject(nil)
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
    #if os(iOS)
    @objc private func suspend() { stop() }
    #endif
    func startHost() {
        guard role == .host else { return }
        stop(); enabled = true; status = "Waiting for iPad"
        do {
            let listener = try NWListener(using: DAWRemoteChannel.parameters())
            listener.service = NWListener.Service(name: name, type: "_\(DAWRemoteWire.service)._tcp")
            startListener(listener)
        } catch { enabled = false; status = error.localizedDescription }
    }
    private func startListener(_ listener: NWListener) {
        self.listener = listener
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            remoteMain {
                guard let self, let listener else { connection.cancel(); return }
                self.accept(connection, from: listener)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .failed(let error) = state {
                remoteMain {
                    guard let self, self.listener === listener else { return }
                    self.stop(); self.status = error.localizedDescription
                }
            }
        }
        listener.start(queue: worker)
    }
    private func accept(_ connection: NWConnection, from listener: NWListener) {
        invitationAttempts.removeAll { Date().timeIntervalSince($0) > 60 }
        guard role == .host, enabled, self.listener === listener, channel == nil, invitationAttempts.count < 5 else { connection.cancel(); return }
        invitationAttempts.append(Date())
        attach(connection)
    }
    func browse() {
        guard role == .client else { return }
        stop(); enabled = true; beginBrowsing()
    }
    private func beginBrowsing() {
        guard role == .client, enabled else { return }
        browser?.cancel(); peers = []; endpoints = [:]
        status = "Searching for nearby Macs…"
        let browser = NWBrowser(for: .bonjour(type: "_\(DAWRemoteWire.service)._tcp", domain: nil), using: DAWRemoteChannel.parameters())
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            remoteMain {
                guard let self, self.browser === browser, !self.connected else { return }
                var endpoints: [String: NWEndpoint] = [:], peers: [DAWRemotePeer] = []
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    let id = result.endpoint.debugDescription
                    endpoints[id] = result.endpoint; peers.append(.init(id: id, displayName: name))
                }
                self.endpoints = endpoints; self.peers = peers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                if !self.connecting && !peers.isEmpty { self.status = "Tap the computer to connect." }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            if case .failed(let error) = state {
                remoteMain { guard let self, self.browser === browser else { return }; self.status = error.localizedDescription }
            }
        }
        browser.start(queue: worker)
    }
    func connect(_ peer: DAWRemotePeer) {
        guard role == .client, enabled, !connecting, !connected, let endpoint = endpoints[peer.id] else { return }
        peerName = peer.displayName
        attach(NWConnection(to: endpoint, using: DAWRemoteChannel.parameters()))
    }
    private func attach(_ connection: NWConnection) {
        let channel = DAWRemoteChannel(connection: connection, role: role, name: name, queue: worker)
        self.channel = channel; receivedStateSequence = 0; connecting = true; status = "Connecting…"
        channel.onReady = { [weak self, weak channel] name in
            guard let self, let channel, self.channel === channel, self.enabled else { return }
            self.connected = true; self.connecting = false; self.peerName = name; self.status = "Connected"
            if self.role == .host {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.publishState() }
                self.stateTimer = timer; RunLoop.main.add(timer, forMode: .common); self.publishState()
            } else {
                self.browser?.cancel(); self.browser = nil; self.remoteState = nil
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = true
                #endif
            }
        }
        channel.onPacket = { [weak self, weak channel] packet in
            guard let self, let channel else { return }; self.received(packet, from: channel)
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel else { return }
            let wasConnected = self.connected
            self.channel = nil; self.connectionGeneration = UUID()
            self.connected = false; self.connecting = false; self.remoteState = nil; self.receivedStateSequence = 0
            self.stateTimer?.invalidate(); self.stateTimer = nil; self.waitingForState = nil; self.sendingState = false
            self.handledCommands.removeAll()
            self.setImageProject(nil)
            if self.role == .client { self.beginBrowsing() }
            self.status = wasConnected ? "Disconnected" : "Connection failed. Keep the devices nearby and enable Remote on the Mac."
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        channel.start()
    }
    func send(_ command: DAWRemoteCommand) {
        guard role == .client, connected, command.valid, let data = try? DAWRemoteWire.command(command) else { return }
        channel?.send(data)
    }
    private func received(_ packet: DAWRemoteWire.Packet, from source: DAWRemoteChannel) {
        guard channel === source, connected, enabled else { return }
        switch packet {
        case .command(let command):
            guard role == .host, !handledCommands.contains(command.id) else { return }
            handledCommands.append(command.id)
            if handledCommands.count > 512 { handledCommands.removeFirst() }
            if command.action == .requestImage { serveImage(command, to: source); return }
            commandHandler?(command)
        case .state(let state):
            guard role == .client else { return }
            if state.sequence > receivedStateSequence {
                receivedStateSequence = state.sequence
                setImageProject(state.project)
                var comparable = state
                comparable.sequence = remoteState?.sequence ?? state.sequence
                // The iPad timer advances locally. An unchanged timer revision
                // must not publish the entire workspace for each network tick.
                if let current = remoteState?.timer, var timer = comparable.timer, timer.revision == current.revision {
                    timer.remainingSeconds = current.remainingSeconds
                    if timer == current { comparable.timer = timer }
                }
                if comparable != remoteState { remoteState = state }
            }
            if let data = try? DAWRemoteWire.acknowledge(state.sequence) { source.send(data) }
        case .acknowledge(let sequence):
            if role == .host, sequence == waitingForState { waitingForState = nil }
        case .imageAsset(let asset):
            receiveImage(asset, from: source)
        }
    }
    private func publishState() {
        guard role == .host, connected, let channel, !sendingState else { return }
        if waitingForState != nil {
            if Date().timeIntervalSince(sentAt) > 10 { channel.close() }
            return
        }
        // DAWRemoteWire.state validates the immutable snapshot on the worker.
        // Walking every clip here repeats that work on the UI thread at 10 Hz.
        guard var state = stateProvider?() else { return }
        setImageProject(state.project)
        stateSequence &+= 1; state.sequence = stateSequence
        waitingForState = state.sequence; sentAt = Date(); sendingState = true
        let generation = connectionGeneration
        worker.async { [self] in
            let encoded = try? DAWRemoteWire.state(state)
            if let encoded {
                channel.send(encoded) { [weak self] _ in
                    guard let self, self.connectionGeneration == generation else { return }; self.sendingState = false
                }
            } else {
                remoteMain {
                    guard self.connectionGeneration == generation else { return }
                    self.sendingState = false; self.waitingForState = nil; self.status = "Remote project is too large"
                }
            }
        }
    }
}
