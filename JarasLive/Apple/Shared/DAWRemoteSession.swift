import SwiftUI
import Combine
import Network
import CryptoKit
import Security
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DAWRemotePeer: Hashable { let id: String; let displayName: String }
enum DAWRemoteRole: UInt8 { case host = 1, client = 2 }

enum DAWRemoteSnapshotComparison {
    /// Transport changes on almost every playback packet. Test its small
    /// values before synthesized equality walks all freshly decoded clips.
    /// Full equality still detects every edit when the transport is unchanged.
    static func differs(_ candidate: DAWRemoteState, from current: DAWRemoteState?) -> Bool {
        guard let current else { return true }
        if candidate.position != current.position || candidate.subPlayPosition != current.subPlayPosition ||
            candidate.editPosition != current.editPosition || candidate.playing != current.playing ||
            candidate.paused != current.paused || candidate.subPlaying != current.subPlaying ||
            candidate.loop != current.loop || candidate.currentRegion != current.currentRegion ||
            candidate.queuedRegion != current.queuedRegion || candidate.focusedRegion != current.focusedRegion ||
            candidate.sectionPlayback != current.sectionPlayback || candidate.footerLoopBeatPhase != current.footerLoopBeatPhase {
            return true
        }
        return candidate != current
    }
}

private func remoteName(_ value: String) -> String {
    var name = ""
    for character in value {
        guard name.utf8.count + String(character).utf8.count <= 63 else { break }
        name.append(character)
    }
    return name.isEmpty ? "CatLive" : name
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

/// The four-digit PIN is stored as a salted digest, never sent in snapshots.
/// All peers share the retry budget so reconnecting cannot bypass the delay.
final class DAWRemoteAccessPolicy {
    private struct Credential: Codable { var salt: Data; var digest: Data }
    private var credentials: [DAWRemoteAccess: Credential] = [:]
    private let preferences: UserDefaults?
    private var failures: [DAWRemoteAccess: Int] = [:]
    private var blockedUntil: [DAWRemoteAccess: Date] = [:]
    var requiresPIN: Bool { requiresPIN(for: .director) }
    func requiresPIN(for mode: DAWRemoteAccess) -> Bool { credentials[mode] != nil }
    private func key(_ mode: DAWRemoteAccess) -> String { "catlive.remote.\(mode.rawValue)PIN" }
    init(preferences: UserDefaults? = nil) {
        self.preferences = preferences
        for mode in [DAWRemoteAccess.director, .notices] {
            if let data = preferences?.data(forKey: key(mode)),
               let value = try? JSONDecoder().decode(Credential.self, from: data), value.salt.count == 16, value.digest.count == 32 {
                credentials[mode] = value
            }
        }
    }
    @discardableResult func setPIN(_ pin: String, mode: DAWRemoteAccess = .director) -> Bool {
        guard mode != .observer, DAWRemoteAccessRequest(mode: mode, pin: pin).valid else { return false }
        if pin.isEmpty { credentials[mode] = nil; preferences?.removeObject(forKey: key(mode)) }
        else {
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let value = Credential(salt: salt, digest: Data(SHA256.hash(data: salt + Data(pin.utf8))))
            credentials[mode] = value
            if let data = try? JSONEncoder().encode(value) { preferences?.set(data, forKey: key(mode)) }
        }
        failures[mode] = 0; blockedUntil[mode] = nil
        return true
    }
    func matchesPIN(_ pin: String, mode: DAWRemoteAccess = .director) -> Bool {
        guard let value = credentials[mode], DAWRemoteAccessRequest(mode: mode, pin: pin).valid else { return false }
        let received = Data(SHA256.hash(data: value.salt + Data(pin.utf8)))
        return zip(received, value.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func authorize(_ request: DAWRemoteAccessRequest, now: Date = Date()) -> DAWRemoteAccessStatus {
        func status(_ mode: DAWRemoteAccess?, _ error: String? = nil) -> DAWRemoteAccessStatus {
            .init(mode: mode, requiresPIN: requiresPIN, noticesRequiresPIN: requiresPIN(for: .notices), error: error)
        }
        guard request.valid else { return status(nil, "Digite quatro números.") }
        let mode = request.mode
        if mode == .observer || credentials[mode] == nil { return status(mode) }
        guard now >= (blockedUntil[mode] ?? .distantPast) else { return status(nil, "Aguarde 30 segundos antes de tentar novamente.") }
        if matchesPIN(request.pin, mode: mode) { failures[mode] = 0; return status(mode) }
        failures[mode, default: 0] += 1
        if failures[mode, default: 0] >= 5 { failures[mode] = 0; blockedUntil[mode] = now.addingTimeInterval(30) }
        return status(nil, "Senha incorreta.")
    }
}

/// Encrypted clients have independent access, TP subscriptions and state/ACK flow.
final class DAWRemoteSession: NSObject, ObservableObject {
    #if os(macOS)
    static let shared = DAWRemoteSession(role: .host, name: Host.current().localizedName ?? "CatLive PC", policy: DAWRemoteAccessPolicy(preferences: .standard), hostPreferences: .standard)
    #else
    static let shared = DAWRemoteSession(role: .client, name: UIDevice.current.name)
    #endif
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var reconnecting = false
    private var reconnectTimer: Timer?
    private var preferredPeer: DAWRemotePeer?
    private var resumeAccess: DAWRemoteAccessRequest?
    private var pendingAccess: DAWRemoteAccessRequest?
    var presentationAccess: DAWRemoteAccess? { accessMode ?? (reconnecting ? resumeAccess?.mode : nil) }
    @Published private(set) var peers: [DAWRemotePeer] = []
    @Published private(set) var peerName = ""
    @Published private(set) var status = ""
    @Published private(set) var remoteState: DAWRemoteState?
    @Published private(set) var accessMode: DAWRemoteAccess?
    @Published private(set) var directorRequiresPIN = false
    @Published private(set) var noticesRequiresPIN = false
    @Published private(set) var accessError = ""
    @Published private(set) var authorizing = false
    private let accessPolicy: DAWRemoteAccessPolicy
    private let hostPreferences: UserDefaults?
    private var channelReady = false
    private weak var parentHost: DAWRemoteSession?
    private var clients: [UUID: DAWRemoteSession] = [:]
    private(set) var requestedPanel = 0
    var stateProviderForSession: ((DAWRemoteSession) -> DAWRemoteState?)?
    @Published private(set) var imageRevision: UInt64 = 0
    private let worker = DispatchQueue(label: "com.jaras.remote.state", qos: .userInitiated)
    private let imageWorker = DispatchQueue(label: "com.jaras.remote.still-images", qos: .utility)
    private let role: DAWRemoteRole
    private var name: String
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

    init(role: DAWRemoteRole, name: String, policy: DAWRemoteAccessPolicy = DAWRemoteAccessPolicy(), hostPreferences: UserDefaults? = nil) {
        self.role = role; self.name = remoteName(name); self.accessPolicy = policy
        self.hostPreferences = role == .host ? hostPreferences : nil
        self.directorRequiresPIN = policy.requiresPIN
        self.noticesRequiresPIN = policy.requiresPIN(for: .notices)
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
    }
    func setHostName(_ value: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard role == .host, parentHost == nil else { return }
        let updated = remoteName(value)
        guard updated != name else { return }
        name = updated
        // Update Bonjour in place: naming a PC must not stop its transport or
        // disconnect tablets already controlling the current project.
        if let listener { listener.service = NWListener.Service(name: name, type: "_\(DAWRemoteWire.service)._tcp") }
        for child in clients.values { child.name = updated }
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
    #if os(macOS)
    /// Only an explicit host toggle changes the app-wide preference. Teardown,
    /// a connection failure and child sessions must leave that intention intact.
    func setHostEnabled(_ enabled: Bool) {
        guard role == .host, parentHost == nil else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        hostPreferences?.set(enabled, forKey: "catlive.remote.enabled")
        if enabled {
            if !self.enabled { startHost() }
        } else { stop() }
    }
    func restoreHostPreference() {
        guard role == .host, parentHost == nil, !enabled,
              hostPreferences?.bool(forKey: "catlive.remote.enabled") == true else { return }
        startHost()
    }
    #endif
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        reconnectTimer?.invalidate(); reconnectTimer = nil; reconnecting = false
        preferredPeer = nil; resumeAccess = nil; pendingAccess = nil
        for child in clients.values { child.stop() }; clients.removeAll()
        connectionGeneration = UUID(); channelReady = false
        accessMode = nil; accessError = ""; authorizing = false; requestedPanel = 0
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
        guard role == .host, enabled, self.listener === listener, clients.count < 15, invitationAttempts.count < 30 else { connection.cancel(); return }
        invitationAttempts.append(Date())
        if channel == nil { attach(connection) }
        else {
            let id = UUID()
            let child = DAWRemoteSession(role: .host, name: name, policy: accessPolicy)
            child.parentHost = self; child.enabled = true
            // Resolve the current project bindings for every client. Copying closures
            // here can strand a client on the startup/previous project's provider.
            child.stateProvider = { [weak self] in self?.stateProvider?() }
            child.stateProviderForSession = { [weak self] client in self?.stateProviderForSession?(client) }
            child.commandHandler = { [weak self] command in self?.commandHandler?(command) }
            clients[id] = child; child.attach(connection)
        }
    }
    func browse() {
        guard role == .client else { return }
        stop(); enabled = true; beginBrowsing()
    }
    private func beginBrowsing() {
        guard role == .client, enabled else { return }
        browser?.cancel(); peers = []; endpoints = [:]
        status = "Searching for nearby PCs…"
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
    private func startReconnecting() {
        guard role == .client, enabled else { return }
        reconnecting = true
        reconnectTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.attemptReconnect() }
        reconnectTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func attemptReconnect() {
        guard reconnecting, enabled, !connected, !connecting, let preferredPeer else { return }
        // Discovery endpoints may change after the Mac restarts; only resume the
        // selected service, never the first unrelated Mac that appears.
        let matches = peers.filter { $0.displayName == preferredPeer.displayName }
        if let peer = peers.first(where: { $0.id == preferredPeer.id }) ?? (matches.count == 1 ? matches.first : nil) {
            connect(peer)
        }
    }
    func connect(_ peer: DAWRemotePeer) {
        guard role == .client, enabled, !connecting, !connected, let endpoint = endpoints[peer.id] else { return }
        preferredPeer = peer
        peerName = peer.displayName
        attach(NWConnection(to: endpoint, using: DAWRemoteChannel.parameters()))
    }
    private func attach(_ connection: NWConnection) {
        let channel = DAWRemoteChannel(connection: connection, role: role, name: name, queue: worker)
        self.channel = channel; receivedStateSequence = 0; connecting = true; status = "Connecting…"
        channel.onReady = { [weak self, weak channel] name in
            guard let self, let channel, self.channel === channel, self.enabled else { return }
            self.channelReady = true
            self.connected = true; self.connecting = false; self.peerName = name; self.status = "Connected"
            self.accessMode = nil
            if self.role == .host { self.requestedPanel = 0 }
            self.parentHost?.refreshHostPresence()
            if self.role == .host {
                self.sendAccessStatus(.init(mode: nil, requiresPIN: self.accessPolicy.requiresPIN))
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.publishState() }
                self.stateTimer = timer; RunLoop.main.add(timer, forMode: .common); self.publishState()
            } else {
                self.browser?.cancel(); self.browser = nil
                if !self.reconnecting { self.remoteState = nil }
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
            let resume = self.role == .client && self.enabled && (self.reconnecting || (wasConnected && self.remoteState != nil))
            if resume { self.startReconnecting() }
            self.channel = nil; self.channelReady = false; self.connectionGeneration = UUID()
            self.accessMode = nil; self.accessError = ""; self.authorizing = false; self.pendingAccess = nil
            if self.role == .host { self.requestedPanel = 0 }
            self.connected = false; self.connecting = false; self.receivedStateSequence = 0
            if !resume { self.remoteState = nil }
            self.stateTimer?.invalidate(); self.stateTimer = nil; self.waitingForState = nil; self.sendingState = false
            self.handledCommands.removeAll()
            if !resume { self.setImageProject(nil) }
            if self.role == .client { self.beginBrowsing() }
            self.status = wasConnected ? "Disconnected" : "Connection failed. Keep the devices nearby and enable Remote on the PC."
            if self.role == .host { self.refreshHostPresence(); self.parentHost?.refreshHostPresence() }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        channel.start()
    }
    func send(_ command: DAWRemoteCommand) {
        guard role == .client, connected, DAWRemoteAccessRules.allows(command, mode: accessMode), let data = try? DAWRemoteWire.command(command) else { return }
        if command.action == .remotePanel { requestedPanel = Int(command.value) }
        channel?.send(data)
    }
    private func received(_ packet: DAWRemoteWire.Packet, from source: DAWRemoteChannel) {
        guard channel === source, connected, enabled else { return }
        switch packet {
        case .command(let command):
            guard role == .host, DAWRemoteAccessRules.allows(command, mode: accessMode), !handledCommands.contains(command.id) else { return }
            handledCommands.append(command.id)
            if handledCommands.count > 512 { handledCommands.removeFirst() }
            if command.action == .requestImage { serveImage(command, to: source); return }
            if command.action == .remotePanel {
                guard command.project == imageProject else { return }
                requestedPanel = Int(command.value); return
            }
            commandHandler?(command)
        case .state(let state):
            guard role == .client, accessMode != nil else { return }
            if state.sequence > receivedStateSequence {
                receivedStateSequence = state.sequence
                setImageProject(state.project)
                var comparable = state
                comparable.sequence = remoteState?.sequence ?? state.sequence
                // The iPad timer advances locally. An unchanged timer revision
                // must not publish the entire workspace for each network tick.
                if !reconnecting, let current = remoteState?.timer, var timer = comparable.timer, timer.revision == current.revision {
                    timer.remainingSeconds = current.remainingSeconds
                    if timer == current { comparable.timer = timer }
                }
                if DAWRemoteSnapshotComparison.differs(comparable, from: remoteState) { remoteState = state }
            }
            if reconnecting {
                reconnecting = false; reconnectTimer?.invalidate(); reconnectTimer = nil
                if requestedPanel != 0 { send(.init(project: state.project, action: .remotePanel, value: Double(requestedPanel))) }
            }
            if let data = try? DAWRemoteWire.acknowledge(state.sequence) { source.send(data) }
        case .acknowledge(let sequence):
            if role == .host, sequence == waitingForState { waitingForState = nil }
        case .imageAsset(let asset):
            receiveImage(asset, from: source)
        case .accessRequest(let request):
            guard role == .host else { return }
            let result = accessPolicy.authorize(request)
            if let mode = result.mode, accessPolicy.requiresPIN(for: mode) { _ = (parentHost ?? self).storePIN(request.pin, mode: mode) }
            accessMode = result.mode; requestedPanel = 0
            // The client discards the old workspace on an access change. Never
            // wait for an ACK belonging to that discarded presentation.
            waitingForState = nil; sendingState = false
            sendAccessStatus(result)
            if accessMode != nil { publishState() }
        case .accessStatus(let result):
            guard role == .client else { return }
            directorRequiresPIN = result.requiresPIN; noticesRequiresPIN = result.noticesRequiresPIN ?? false; accessError = result.error ?? ""
            accessMode = result.mode; authorizing = false
            if result.mode != nil {
                if let pendingAccess { resumeAccess = pendingAccess }
                pendingAccess = nil
            } else if result.error?.isEmpty != false, pendingAccess != nil {
                // The host greeting can arrive after our access request was sent.
                // It is not a rejection; retain that request until its reply.
                authorizing = true
            } else if reconnecting, result.error?.isEmpty != false, let resumeAccess {
                requestAccess(resumeAccess.mode, pin: resumeAccess.pin)
            } else {
                reconnecting = false; reconnectTimer?.invalidate(); reconnectTimer = nil
                resumeAccess = nil; pendingAccess = nil
                remoteState = nil; setImageProject(nil)
            }
        }
    }
    private func refreshHostPresence() {
        clients = clients.filter { $0.value.channel != nil }
        connected = channelReady || clients.values.contains { $0.connected }
        connecting = (channel != nil && !channelReady) || clients.values.contains { $0.connecting }
        if connected { status = "Connected" }
    }
    private func sendAccessStatus(_ status: DAWRemoteAccessStatus) {
        var status = status
        status.requiresPIN = accessPolicy.requiresPIN
        status.noticesRequiresPIN = accessPolicy.requiresPIN(for: .notices)
        if let data = try? DAWRemoteWire.accessStatus(status) { channel?.send(data) }
    }
    func requestAccess(_ mode: DAWRemoteAccess, pin: String = "") {
        guard role == .client, connected,
              let data = try? DAWRemoteWire.accessRequest(.init(mode: mode, pin: pin)) else { return }
        pendingAccess = .init(mode: mode, pin: pin)
        accessError = ""; authorizing = true; channel?.send(data)
    }
    private func pinKeychainQuery(_ mode: DAWRemoteAccess) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.catlive.remote", kSecAttrAccount as String: "\(mode.rawValue)PIN"]
    }
    var savedDirectorPIN: String { savedPIN(.director) }
    var savedNoticesPIN: String { savedPIN(.notices) }
    private func savedPIN(_ mode: DAWRemoteAccess) -> String {
        guard hostPreferences === UserDefaults.standard, accessPolicy.requiresPIN(for: mode) else { return "" }
        var query = pinKeychainQuery(mode); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        let pin = String(data: data, encoding: .utf8) ?? ""
        return accessPolicy.matchesPIN(pin, mode: mode) ? pin : ""
    }
    @discardableResult func setDirectorPIN(_ pin: String) -> Bool { setPIN(pin, mode: .director) }
    @discardableResult func setNoticesPIN(_ pin: String) -> Bool { setPIN(pin, mode: .notices) }
    private func setPIN(_ pin: String, mode: DAWRemoteAccess) -> Bool {
        guard role == .host, mode != .observer, DAWRemoteAccessRequest(mode: mode, pin: pin).valid else { return false }
        guard storePIN(pin, mode: mode) else { return false }
        guard accessPolicy.setPIN(pin, mode: mode) else { return false }
        directorRequiresPIN = accessPolicy.requiresPIN
        noticesRequiresPIN = accessPolicy.requiresPIN(for: .notices)
        for session in [self] + Array(clients.values) where session.channelReady {
            if session.accessMode == mode {
                session.accessMode = nil; session.requestedPanel = 0
                session.waitingForState = nil; session.sendingState = false
            }
            session.sendAccessStatus(.init(mode: session.accessMode, requiresPIN: accessPolicy.requiresPIN))
        }
        return true
    }
    private func storePIN(_ pin: String, mode: DAWRemoteAccess) -> Bool {
        if hostPreferences === UserDefaults.standard {
            let query = pinKeychainQuery(mode)
            var result: OSStatus
            if pin.isEmpty { result = SecItemDelete(query as CFDictionary) }
            else {
                let value = [kSecValueData as String: Data(pin.utf8)]
                result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
                if result == errSecItemNotFound {
                    var insert = query; insert[kSecValueData as String] = Data(pin.utf8)
                    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    result = SecItemAdd(insert as CFDictionary, nil)
                }
            }
            guard result == errSecSuccess || (pin.isEmpty && result == errSecItemNotFound) else {
                status = "Não foi possível salvar a senha no Chaves do macOS."; return false
            }
        }
        return true
    }
    private func publishState() {
        guard role == .host, connected, accessMode != nil, let channel, !sendingState else { return }
        if waitingForState != nil {
            if Date().timeIntervalSince(sentAt) > 10 { channel.close() }
            return
        }
        // DAWRemoteWire.state validates the immutable snapshot on the worker.
        // Walking every clip here repeats that work on the UI thread at 10 Hz.
        guard var state = stateProviderForSession?(self) ?? stateProvider?() else { return }
        if accessMode == .observer || accessMode == .notices {
            state.tracks = []; state.playlists = nil; state.projects = nil; state.gridTempo = nil
        }
        if accessMode == .notices {
            state.regions = []; state.timelineRegions = []; state.markers = nil
            state.teleprompters = nil; state.sectionPlayback = nil
        }
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
                    self.sendingState = false; self.waitingForState = nil; self.status = "Remote project could not be sent"
                    self.sendAccessStatus(.init(mode: self.accessMode, requiresPIN: self.accessPolicy.requiresPIN, error: "Não foi possível enviar o projeto ao iPad. / Could not send the project to the iPad."))
                }
            }
        }
    }
}
