// These tests use encrypted loopback TCP for the real handshake and access
// exchange. Bonjour results are injected, so discovery needs neither another
// device nor Local Network permission on the machine running the suite.
extension DAWRemoteSession {
    fileprivate func isolateLifecycleBrowser() -> NWBrowser {
        guard let browser else { fatalError("Lifecycle discovery was not started") }
        browser.cancel()
        discoveryPathMonitor?.cancel()
        // Retire queued real path callbacks through the production identity
        // guard, keeping deterministic recovery timers available to the test.
        discoveryPathMonitor = NWPathMonitor()
        return browser
    }

    fileprivate func requireLifecycleSuspended(_ context: String) {
        require(enabled && clientSuspended && !connected && !connecting && channel == nil,
                "\(context): background retains intent without an active connection")
        require(browser == nil && discoveryPathMonitor == nil && discoveryRetryTimer == nil && reconnectTimer == nil && stateTimer == nil,
                "\(context): background stops discovery, retry and publication work")
        require(peers.isEmpty && endpoints.isEmpty && !authorizing && accessMode == nil,
                "\(context): background has no stale peers or command authority")
    }

    fileprivate func verifyLifecycle(access: DAWRemoteAccess, pin: String, cycles: Int) throws {
        let label = "\(access) lifecycle"
        let host = DAWRemoteSession(role: .host, name: "Lifecycle PC \(access)")
        defer { stop(); host.stop() }
        if access == .director { require(host.setDirectorPIN(pin), "\(label): set director PIN") }
        if access == .notices { require(host.setNoticesPIN(pin), "\(label): set notices PIN") }
        var revision = "initial"
        var playCommands = 0
        host.stateProviderForSession = { session in
            var state = fixture
            state.message = "\(revision)-panel-\(session.requestedPanel)"
            return state
        }
        host.commandHandler = { command in if command.action == .play { playCommands += 1 } }
        let endpoint = try host.testListen()
        testConnect(endpoint, access: access, pin: pin)
        waitFor("\(label): authorize initial encrypted session") { accessMode == access && remoteState != nil }
        let panel = access == .notices ? 3 : 2
        send(.init(project: project, action: .remotePanel, value: Double(panel)))
        waitFor("\(label): select projection panel") { remoteState?.message == "initial-panel-\(panel)" }

        for cycle in 1...cycles {
            let lastState = remoteState
            let lastPeer = preferredPeer
            let lastAccess = resumeAccess
            guard let retiredChannel = channel else { fatalError("Missing lifecycle transport") }
            suspendForBackground()
            suspendForBackground()
            requireLifecycleSuspended("\(label) \(cycle)")
            require(reconnecting && remoteState == lastState && presentationAccess == access && requestedPanel == panel,
                    "\(label): background preserves workspace, role and selected panel")
            require(preferredPeer?.id == lastPeer?.id && resumeAccess?.mode == lastAccess?.mode && resumeAccess?.pin == lastAccess?.pin,
                    "\(label): background preserves selected PC and accepted credentials")
            // Exercise late connection callbacks while suspended, and every
            // recovery entry point that previously could restart background IO.
            retiredChannel.onReady?("Retired connection")
            retiredChannel.onClose?()
            startReconnecting(); beginBrowsing(); scheduleDiscoveryRecovery(); attemptReconnect()
            discoveryPathChanged(available: false); discoveryPathChanged(available: true)
            send(.init(project: project, action: .play))
            waitFor("\(label): PC releases backgrounded client") { !host.connected && !host.connecting }
            requireLifecycleSuspended("\(label) after retired callbacks")
            require(remoteState == lastState && playCommands == 0, "\(label): background cannot mutate snapshot or execute controls")

            revision = "foreground-\(cycle)"
            // Both the app activation callback and picker onAppear resume
            // the preserved session; test both real entry points.
            if cycle.isMultiple(of: 2) { resumeBrowsing() } else { resumeAfterBackground() }
            let freshBrowser = isolateLifecycleBrowser()
            require(!clientSuspended && reconnecting && reconnectTimer != nil,
                    "\(label): foreground starts fresh discovery and automatic reconnection")
            resumeAfterBackground()
            require(browser === freshBrowser, "\(label): duplicate foreground callback is idempotent")
            let unrelated = NWEndpoint.service(name: "Unrelated PC", type: "_\(DAWRemoteWire.service)._tcp", domain: "local.", interface: nil)
            updateDiscoveredEndpoints([unrelated], from: freshBrowser)
            require(peers.count == 1 && !connecting && channel == nil,
                    "\(label): foreground never reconnects to an unrelated discovered PC")
            testRediscover(endpoint)
            waitFor("\(label): automatic reauthorization restores fresh state and panel after cycle \(cycle)") {
                connected && !reconnecting && accessMode == access && remoteState?.message == "\(revision)-panel-\(panel)"
            }
            require(browser == nil && discoveryRetryTimer == nil && discoveryPathMonitor == nil && reconnectTimer == nil,
                    "\(label): successful reconnection retires all discovery and retry work")
            guard let activeChannel = channel, var staleState = remoteState else { fatalError("Missing resumed lifecycle state") }
            staleState.sequence += 100; staleState.message = "Retired snapshot"
            retiredChannel.onReady?("Retired connection")
            retiredChannel.onPacket?(.state(staleState))
            retiredChannel.onPacket?(.accessStatus(.init(mode: nil, requiresPIN: true, error: "Retired rejection")))
            retiredChannel.onClose?()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            require(channel === activeChannel && connected && !reconnecting && accessMode == access && remoteState?.message == "\(revision)-panel-\(panel)",
                    "\(label): callbacks from the retired channel cannot clear, replace or close the resumed session")
        }

        if access != .observer {
            suspendForBackground()
            waitFor("\(label): disconnect before password change") { !host.connected && !host.connecting }
            let replacementPIN = "5678"
            require(access == .director ? host.setDirectorPIN(replacementPIN) : host.setNoticesPIN(replacementPIN),
                    "\(label): password changes while remote is backgrounded")
            resumeAfterBackground()
            _ = isolateLifecycleBrowser()
            testRediscover(endpoint)
            waitFor("\(label): stale password is rejected after foreground") {
                connected && !reconnecting && accessMode == nil && !accessError.isEmpty
            }
            require(remoteState == nil && presentationAccess == nil && resumeAccess == nil,
                    "\(label): failed reauthorization removes cached workspace and authority")
            requestAccess(access, pin: replacementPIN)
            waitFor("\(label): replacement password restores access") { accessMode == access && remoteState != nil }
        }

        suspendForBackground()
        stop()
        resumeAfterBackground()
        require(!enabled && !clientSuspended && !reconnecting && channel == nil && browser == nil && reconnectTimer == nil && discoveryRetryTimer == nil,
                "\(label): Exit while suspended cannot resurrect a session on foreground")
        require(remoteState == nil && preferredPeer == nil && resumeAccess == nil && requestedPanel == 0,
                "\(label): explicit Exit clears the retained workspace, role, PC and panel")
    }

    fileprivate func verifyPickerLifecycle() {
        let firstEndpoint = NWEndpoint.service(name: "First PC", type: "_\(DAWRemoteWire.service)._tcp", domain: "local.", interface: nil)
        let secondEndpoint = NWEndpoint.service(name: "Second PC", type: "_\(DAWRemoteWire.service)._tcp", domain: "local.", interface: nil)
        browse()
        let first = isolateLifecycleBrowser()
        let lateFirstState = first.stateUpdateHandler
        updateDiscoveredEndpoints([firstEndpoint], from: first)
        require(peers.map(\.displayName) == ["First PC"] && preferredPeer == nil, "picker discovers PC without selecting it")
        suspendForBackground()
        requireLifecycleSuspended("backgrounded picker")
        require(!reconnecting && remoteState == nil && preferredPeer == nil, "picker background does not invent a previously selected PC")
        lateFirstState?(.failed(.posix(.ENETDOWN)))
        updateDiscoveredEndpoints([firstEndpoint], from: first)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        requireLifecycleSuspended("picker after stale discovery callbacks")
        resumeBrowsing()
        let second = isolateLifecycleBrowser()
        require(second !== first && !clientSuspended && !reconnecting && discoveryRetryTimer != nil && reconnectTimer == nil,
                "picker onAppear returns to a new search without unauthorized automatic connection")
        updateDiscoveredEndpoints([firstEndpoint], from: first)
        require(peers.isEmpty, "retired pre-background Bonjour results cannot restore stale picker entries")
        updateDiscoveredEndpoints([secondEndpoint], from: second)
        require(peers.map(\.displayName) == ["Second PC"] && discoveryRetryTimer == nil,
                "fresh foreground discovery replaces the old computer list")
        let lateSecondState = second.stateUpdateHandler
        suspendForBackground(); stop(); resumeAfterBackground()
        lateSecondState?(.waiting(.posix(.ENETDOWN)))
        updateDiscoveredEndpoints([secondEndpoint], from: second)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        require(!enabled && browser == nil && channel == nil && peers.isEmpty && discoveryRetryTimer == nil && reconnectTimer == nil,
                "picker Exit ignores foreground and late discovery callbacks")
    }

    fileprivate func verifyLifecycleBeforeFirstState() throws {
        let host = DAWRemoteSession(role: .host, name: "Early lifecycle PC")
        defer { stop(); host.stop() }
        require(host.setDirectorPIN("1357"), "early lifecycle host uses an actual protected role")
        var publishesState = false
        host.stateProvider = { publishesState ? fixture : nil }
        let endpoint = try host.testListen()

        // Suspend synchronously after creating TCP, before it can complete the
        // handshake or grant any access. Selecting a PC is not authentication.
        testConnect(endpoint, access: nil)
        require(connecting && accessMode == nil && resumeAccess == nil && remoteState == nil,
                "early lifecycle starts with a selected PC but no accepted credentials")
        suspendForBackground()
        requireLifecycleSuspended("during initial connection")
        resumeAfterBackground()
        _ = isolateLifecycleBrowser()
        testRediscover(endpoint)
        waitFor("foreground of unfinished connection reaches access picker") {
            connected && directorRequiresPIN && !reconnecting
        }
        require(accessMode == nil && presentationAccess == nil && remoteState == nil && resumeAccess == nil && !authorizing,
                "foreground never invents an accepted login from an unfinished connection")

        requestAccess(.director, pin: "1357")
        waitFor("protected access can be accepted before the first project snapshot") { accessMode == .director }
        require(remoteState == nil && resumeAccess?.pin == "1357", "accepted credentials are preserved even without a first state")
        suspendForBackground()
        waitFor("PC releases authorized client without a first snapshot") { !host.connected && !host.connecting }
        resumeAfterBackground()
        _ = isolateLifecycleBrowser()
        testRediscover(endpoint)
        waitFor("accepted credentials reauthorize automatically without needing an old snapshot") { connected && accessMode == .director }
        require(reconnecting && remoteState == nil, "reconnection keeps waiting until the new authoritative state arrives")
        publishesState = true
        waitFor("first state after foreground completes authorized reconnection") { remoteState?.project == project && !reconnecting }
    }

    fileprivate func verifyLifecycleImagesAndProjectChange() throws {
        let host = DAWRemoteSession(role: .host, name: "Image lifecycle PC")
        defer { stop(); host.stop() }
        var state = fixture
        let imageIDs = (0..<6).map { _ in UUID() }
        host.stateProviderForSession = { session in
            // Fixed opaque IDs model unchanged image references in the same
            // project across transport generations. Only fixture registration
            // is controlled here; request/reply/validation use production TCP.
            session.setImageProject(state.project)
            for id in imageIDs {
                session.imageSources[id] = .bytes(preparedImage)
                session.images.insert(preparedImage, id: id)
            }
            return state
        }
        let endpoint = try host.testListen()
        testConnect(endpoint, access: .observer)
        waitFor("image lifecycle initial state") { accessMode == .observer && remoteState != nil }
        for id in imageIDs.prefix(3) { requestImage(id: id, project: project) }
        require(imagePending.count == 2 && imageQueue.count == 1,
                "image lifecycle has both in-flight and queued image requests")
        guard let retiredImageChannel = channel else { fatalError("Missing image lifecycle transport") }
        suspendForBackground()
        require(imagePending.isEmpty && Set(imageQueue) == Set(imageIDs.prefix(3)),
                "background returns unfinished image requests to a bounded retry queue")
        waitFor("PC releases image lifecycle connection") { !host.connected && !host.connecting }
        resumeAfterBackground()
        _ = isolateLifecycleBrowser()
        testRediscover(endpoint)
        waitFor("same-project foreground retries pending and queued images after fresh state") {
            connected && !reconnecting && imageIDs.prefix(3).allSatisfy { imageData(id: $0, project: project) == preparedImage }
        }
        require(imagePending.isEmpty && imageQueue.isEmpty && imageFailed.isEmpty,
                "all resumed images finish and cannot leave a permanent loading spinner")
        retiredImageChannel.onPacket?(.imageAsset(.init(project: project, id: imageIDs[0], data: Data())))
        require(imageData(id: imageIDs[0], project: project) == preparedImage,
                "a retired image reply cannot replace an image from the active generation")

        for id in imageIDs.suffix(3) { requestImage(id: id, project: project) }
        require(imagePending.count == 2 && imageQueue.count == 1, "project-change fixture also has queued and in-flight images")
        suspendForBackground()
        waitFor("PC releases client before background project change") { !host.connected && !host.connecting }
        let newProject = UUID()
        state.project = newProject; state.message = "Project switched while backgrounded"
        resumeAfterBackground()
        _ = isolateLifecycleBrowser()
        testRediscover(endpoint)
        waitFor("foreground receives replacement project") { remoteState?.project == newProject && !reconnecting }
        require(imageProject == newProject && imagePending.isEmpty && imageQueue.isEmpty && imageFailed.isEmpty,
                "a replacement project discards old image requests instead of replaying them against another project")
        require(imageIDs.allSatisfy { imageData(id: $0, project: project) == nil && imageData(id: $0, project: newProject) == nil },
                "a replacement project cannot inherit cached images from the old workspace")
    }

    fileprivate func verifyNetworkReconnectImages() throws {
        let host = DAWRemoteSession(role: .host, name: "Image network recovery PC")
        defer { stop(); host.stop() }
        var state = fixture
        let ids = (0..<6).map { _ in UUID() }
        host.stateProviderForSession = { session in
            session.setImageProject(state.project)
            for id in ids {
                session.imageSources[id] = .bytes(preparedImage)
                session.images.insert(preparedImage, id: id)
            }
            return state
        }
        let endpoint = try host.testListen()
        testConnect(endpoint, access: .observer)
        waitFor("network image recovery initial authorized snapshot") { remoteState != nil && accessMode == .observer }

        for cycle in 0..<2 {
            let requested = Array(ids[(cycle * 3)..<(cycle * 3 + 3)])
            for id in requested { requestImage(id: id, project: state.project) }
            require(imagePending.count == 2 && imageQueue.count == 1,
                    "network image recovery starts with both in-flight image slots occupied")
            guard let retired = channel else { fatalError("Missing network recovery channel") }
            // Deliver the production close callback before the main run loop
            // can accept queued image replies; unlike suspension, this is the
            // ordinary Wi-Fi/USB interruption path. Reconnection still uses
            // the real encrypted loopback transport and access exchange.
            retired.onClose?(); retired.close()
            require(reconnecting && !connected && imagePending.isEmpty && Set(imageQueue) == Set(requested),
                    "network disconnect requeues unfinished images instead of retaining occupied slots")
            waitFor("host releases interrupted image connection") { !host.connected && !host.connecting }
            if cycle == 1 { state.project = UUID() }
            testRediscover(endpoint)
            guard let recovering = channel else { fatalError("Missing recovering image channel") }
            let ready = recovering.onReady
            recovering.onReady = { [weak self] name in
                ready?(name)
                guard let self else { return }
                self.sendImageRequests()
                require(self.connected && self.accessMode == nil && self.imagePending.isEmpty,
                        "image requests cannot occupy slots before reconnection access is granted")
            }
            let packet = recovering.onPacket
            recovering.onPacket = { [weak self] received in
                packet?(received)
                guard let self, case .accessStatus(let status) = received, status.mode != nil else { return }
                self.sendImageRequests()
                require(self.reconnecting && self.imagePending.isEmpty,
                        "reauthorized images wait for the fresh project snapshot before dispatch")
            }
            waitFor("network image recovery obtains authoritative state") { connected && !reconnecting && remoteState?.project == state.project }
            if cycle == 0 {
                waitFor("network reconnect downloads every interrupted and queued image") {
                    requested.allSatisfy { imageData(id: $0, project: state.project) == preparedImage }
                }
                require(imagePending.isEmpty && imageQueue.isEmpty && imageFailed.isEmpty,
                        "network image recovery frees both slots after completion")
                retired.onPacket?(.imageAsset(.init(project: state.project, id: requested[0], data: Data())))
                require(imageData(id: requested[0], project: state.project) == preparedImage,
                        "retired network image replies cannot replace recovered images")
            } else {
                require(imagePending.isEmpty && imageQueue.isEmpty && imageFailed.isEmpty,
                        "network reconnect to a replacement project discards interrupted image requests")
            }
        }
    }
    fileprivate func verifyAccessChangeDuringSnapshotEncoding() throws {
        let host = DAWRemoteSession(role: .host, name: "Access generation PC")
        defer { stop(); host.stop() }
        var message = "Initial director"
        host.stateProvider = { var state = fixture; state.message = message; return state }
        let endpoint = try host.testListen()
        testConnect(endpoint, access: .director)
        waitFor("access generation has an initial director snapshot") { accessMode == .director && remoteState?.message == message }
        let publisher = host
        guard let source = publisher.channel, let clientChannel = channel else {
            fatalError("Access generation fixture has no active encrypted channel")
        }
        publisher.stateTimer?.invalidate(); publisher.stateTimer = nil
        waitFor("access generation drains the initial state ACK") { !publisher.sendingState && publisher.waitingForState == nil }
        var snapshots: [DAWRemoteState] = []
        let originalPacket = clientChannel.onPacket
        clientChannel.onPacket = { packet in
            if case .state(let state) = packet { snapshots.append(state) }
            originalPacket?(packet)
        }
        for mode in [DAWRemoteAccess.observer, .notices] {
            let gate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
            publisher.worker.async { started.signal(); gate.wait() }
            require(started.wait(timeout: .now() + 2) == .success, "snapshot encoder fixture starts its controlled wait")
            let retiredMessage = "Retired before \(mode)"
            message = retiredMessage
            publisher.publishState()
            require(publisher.sendingState, "fixture reserves a snapshot under the previous access mode")
            message = "Fresh \(mode)"
            // Model an already decoded request queued for Main while snapshot
            // encoding is pending. The real transport still carries the reply,
            // encrypted snapshots and their ACKs after the worker is released.
            publisher.received(.accessRequest(.init(mode: mode, pin: "")), from: source)
            gate.signal()
            waitFor("new \(mode) gets only its freshly filtered snapshot") {
                accessMode == mode && remoteState?.message == message
            }
            waitFor("new \(mode) snapshot ACK completes") { !publisher.sendingState && publisher.waitingForState == nil }
            require(!snapshots.contains { $0.message == retiredMessage },
                    "a snapshot encoded before an access change must never reach the new presentation")
            require(remoteState?.tracks.isEmpty == true, "restricted snapshots omit director tracks")
            if mode == .notices { require(remoteState?.regions.isEmpty == true, "notices snapshots omit observer regions") }
        }
    }
}

try DAWRemoteSession(role: .client, name: "Director lifecycle iPad").verifyLifecycle(access: .director, pin: "1234", cycles: 3)
try DAWRemoteSession(role: .client, name: "Observer lifecycle phone").verifyLifecycle(access: .observer, pin: "", cycles: 2)
try DAWRemoteSession(role: .client, name: "Notices lifecycle phone").verifyLifecycle(access: .notices, pin: "4321", cycles: 2)
print("REMOTE_BACKGROUND_FOREGROUND_REPEATED_DIRECTOR_OBSERVER_NOTICES_TCP_REAUTH_PANEL_STATE_STALE_CALLBACKS_CHANGED_PIN_AND_EXIT_OK")
DAWRemoteSession(role: .client, name: "Picker lifecycle iPad").verifyPickerLifecycle()
print("REMOTE_PICKER_BACKGROUND_FOREGROUND_FRESH_DISCOVERY_STALE_RESULTS_NO_AUTOCONNECT_AND_EXIT_OK")
try DAWRemoteSession(role: .client, name: "Early lifecycle phone").verifyLifecycleBeforeFirstState()
print("REMOTE_BACKGROUND_DURING_CONNECT_NO_AUTH_ESCALATION_ACCEPTED_LOGIN_BEFORE_FIRST_STATE_AND_FRESH_SNAPSHOT_OK")
try DAWRemoteSession(role: .client, name: "Image lifecycle iPad").verifyLifecycleImagesAndProjectChange()
print("REMOTE_BACKGROUND_IMAGE_INFLIGHT_AND_QUEUED_RETRY_STALE_REPLY_AND_REPLACEMENT_PROJECT_CLEANUP_OK")
try DAWRemoteSession(role: .client, name: "Image network recovery iPad").verifyNetworkReconnectImages()
print("REMOTE_NETWORK_DISCONNECT_IMAGE_INFLIGHT_RETRY_STALE_REPLY_AND_REPLACEMENT_PROJECT_CLEANUP_OK")
try DAWRemoteSession(role: .client, name: "Access generation iPad").verifyAccessChangeDuringSnapshotEncoding()
print("REMOTE_ACCESS_CHANGE_DURING_ENCODING_DROPS_RETIRED_DIRECTOR_OBSERVER_SNAPSHOTS_AND_PRESERVES_ACK_OK")
