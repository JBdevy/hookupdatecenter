// Compiled beside the production session so recovery can be driven without
// relying on Bonjour devices, Wi-Fi or Local Network permission on the test Mac.
extension DAWRemoteSession {
    fileprivate func verifyDiscoveryRecovery() {
        var stateCallbacks: [ObjectIdentifier: (NWBrowser.State) -> Void] = [:]
        func isolateBrowser() -> NWBrowser {
            guard let browser else { fatalError("Discovery browser was not started") }
            guard let stateCallback = browser.stateUpdateHandler else { fatalError("Missing discovery state handler") }
            stateCallbacks[ObjectIdentifier(browser)] = stateCallback
            browser.cancel()
            discoveryPathMonitor?.cancel()
            // Keep a non-running monitor installed. Queued callbacks from the
            // cancelled monitor cannot pass the production identity check.
            discoveryPathMonitor = NWPathMonitor()
            return browser
        }
        func expireSearch() -> NWBrowser {
            guard let timer = discoveryRetryTimer else { fatalError("Missing automatic discovery recovery") }
            // Invalidating before fire would suppress Timer's callback. Fire
            // first, then invalidate the expired one-shot to avoid real waits.
            timer.fire(); timer.invalidate()
            return isolateBrowser()
        }
        let endpoint = NWEndpoint.service(name: "Recovery PC", type: "_\(DAWRemoteWire.service)._tcp", domain: "local.", interface: nil)
        browse()
        let first = isolateBrowser()
        require(enabled && peers.isEmpty && (5.5...6.1).contains(discoveryRetryTimer?.fireDate.timeIntervalSinceNow ?? 0), "initial empty search schedules its own recovery")
        let second = expireSearch()
        require(second !== first && discoveryRetryAttempt == 1 && (11.5...12.1).contains(discoveryRetryTimer?.fireDate.timeIntervalSinceNow ?? 0),
                "silent empty browser is replaced without manual refresh and backs off")
        updateDiscoveredEndpoints([endpoint], from: first)
        require(peers.isEmpty, "late results from cancelled browser cannot replace current discovery")
        updateDiscoveredEndpoints([endpoint], from: second)
        require(peers.count == 1 && peers[0].displayName == "Recovery PC" && discoveryRetryTimer == nil,
                "fresh discovery publishes host and stops periodic recovery")
        require(discoveryRetryAttempt == 0, "finding a PC resets discovery backoff")
        updateDiscoveredEndpoints([], from: second)
        require(peers.isEmpty && discoveryRetryTimer != nil, "losing all advertised PCs resumes bounded recovery")
        let third = expireSearch()
        let fourth = expireSearch()
        require(third !== fourth && discoveryRetryAttempt == 2 && (19.5...20.1).contains(discoveryRetryTimer?.fireDate.timeIntervalSinceNow ?? 0),
                "empty discovery backs off to capped retry cadence")

        // Exercise the actual Network.framework callback wiring, including a
        // terminal failure that used to leave the spinner stuck permanently.
        updateDiscoveredEndpoints([endpoint], from: fourth)
        require(discoveryRetryTimer == nil, "visible peer has no polling timer before browser failure")
        stateCallbacks[ObjectIdentifier(fourth)]?(.failed(.posix(.ENETDOWN)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        require(discoveryRetryTimer != nil && peers.isEmpty, "failed Bonjour browser clears stale peers and schedules automatic recovery")
        let recovered = expireSearch()
        require(recovered !== fourth, "terminally failed browser is replaced")
        updateDiscoveredEndpoints([endpoint], from: recovered)
        stateCallbacks[ObjectIdentifier(recovered)]?(.waiting(.posix(.ENETDOWN)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        require(peers.isEmpty && discoveryRetryTimer != nil, "waiting browser discards stale peers and schedules recovery")
        resumeBrowsing()
        let foreground = isolateBrowser()
        require(foreground !== recovered && discoveryRetryAttempt == 0, "foreground/permission return refreshes stalled enabled search")
        discoveryHasPath = false
        discoveryPathChanged(available: true)
        require(browser === foreground, "initial path notification does not restart an already fresh search")
        discoveryPathChanged(available: false)
        require(browser === foreground, "no Internet route does not prevent local discovery")
        discoveryPathChanged(available: true)
        let networkRecovered = isolateBrowser()
        require(networkRecovered !== foreground, "a restored network restarts discovery immediately")

        connecting = true
        resumeBrowsing(); discoveryPathChanged(available: true)
        require(browser === networkRecovered, "refresh never interrupts an in-flight connection")
        connecting = false; connected = true
        resumeBrowsing(); discoveryPathChanged(available: true)
        require(browser === networkRecovered, "refresh never interrupts an established connection")
        connected = false
        stopDiscovery()
        require(browser == nil && discoveryRetryTimer == nil && discoveryPathMonitor == nil,
                "successful connection teardown stops all discovery work")
        beginBrowsing()
        let finalBrowser = isolateBrowser()
        let lateState = stateCallbacks[ObjectIdentifier(finalBrowser)]
        stop()
        lateState?(.failed(.posix(.ENETDOWN)))
        updateDiscoveredEndpoints([endpoint], from: finalBrowser)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        require(!enabled && browser == nil && peers.isEmpty && discoveryRetryTimer == nil && discoveryPathMonitor == nil,
                "exit rejects stale callbacks and never resurrects discovery")
    }
}
DAWRemoteSession(role: .client, name: "Discovery recovery test").verifyDiscoveryRecovery()
print("REMOTE_DISCOVERY_EMPTY_FAILED_WAITING_FOREGROUND_NETWORK_RECOVERY_CONNECTION_GUARDS_AND_EXIT_OK")
