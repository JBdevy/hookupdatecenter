// Compiled together with the real catalog by test-plugin-catalog.sh.
if CommandLine.arguments.count > 3 && CommandLine.arguments[1] == "--scan-vst3" {
    let module = URL(fileURLWithPath: CommandLine.arguments[2])
    let counter = module.appendingPathExtension("scans")
    let count = (try? String(contentsOf: counter)).flatMap(Int.init) ?? 0
    try String(count + 1).write(to: counter, atomically: true, encoding: .utf8)
    if module.lastPathComponent == "Slow.vst3" { Thread.sleep(forTimeInterval: 31) }
    if module.lastPathComponent == "Stuck.vst3", (try? String(contentsOf: module)) != "recovered" { Thread.sleep(forTimeInterval: 10) }
    let plugin = RecognizedPlugin(classID: "fixture", name: "Kontakt", path: module.path, vendor: "Native Instruments", category: "Instrument|Sampler")
    struct Response: Encodable { let plugins: [RecognizedPlugin]; let error: String }
    try JSONEncoder().encode(Response(plugins: [plugin], error: "")).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}
Task { @MainActor in
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("catlive-catalog-tests-" + UUID().uuidString)
    let suite = "catlive.catalog.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let slow = root.appendingPathComponent("Slow.vst3")
        try "test module".write(to: slow, atomically: true, encoding: .utf8)
        defaults.set([root.path, root.path], forKey: "jaras.plugins.paths")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        @MainActor func wait(_ catalog: PluginCatalog, limit: Double = 40) async throws {
            let deadline = Date().addingTimeInterval(limit)
            while catalog.scanning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!catalog.scanning, "Catalog did not finish")
        }
        let catalog = PluginCatalog(defaults: defaults, executable: executable)
        catalog.scan(); catalog.scan()
        precondition(catalog.scanning)
        try await wait(catalog)
        precondition(catalog.plugins.count == 1 && catalog.totalPlugins == 1 && catalog.completedPlugins == 1, "A plugin taking over 30 seconds must succeed; duplicate roots must not double-scan")
        precondition(catalog.status == "Scan complete.")
        defaults.removeObject(forKey: "jaras.plugins.scanCache") // Simulate upgrading the pre-cache catalog.
        let upgraded = PluginCatalog(defaults: defaults, executable: executable)
        upgraded.scan(); try await wait(upgraded, limit: 3)
        precondition((try? String(contentsOf: slow.appendingPathExtension("scans"))) == "1", "Known legacy plugin was rescanned during migration")
        let restarted = PluginCatalog(defaults: defaults, executable: executable)
        restarted.scan(); try await wait(restarted, limit: 3)
        precondition((try? String(contentsOf: slow.appendingPathExtension("scans"))) == "1", "Cached plugin was loaded again after reopening the catalog")
        let original = PluginScanRecord.fingerprint(slow)
        try "changed test module".write(to: slow, atomically: true, encoding: .utf8)
        precondition(original != PluginScanRecord.fingerprint(slow))
        restarted.scan()
        let startedDeadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: slow.appendingPathExtension("scans"))) != "2" && Date() < startedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition((try? String(contentsOf: slow.appendingPathExtension("scans"))) == "2", "Changed plugin was not rechecked")
        restarted.cancelScan(); try await wait(restarted, limit: 3)
        precondition(restarted.plugins.count == 1 && restarted.status == "Scan cancelled.", "Cancel discarded the known catalog")
        try fm.removeItem(at: slow)
        restarted.scan(); try await wait(restarted, limit: 3)
        precondition(restarted.plugins.isEmpty && restarted.totalPlugins == 0, "Deleted module remained in the catalog")
        let bundle = root.appendingPathComponent("Bundle.vst3")
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let resource = bundle.appendingPathComponent("Contents/resource")
        try "one".write(to: resource, atomically: true, encoding: .utf8)
        let before = PluginScanRecord.fingerprint(bundle)
        try "changed resources".write(to: resource, atomically: true, encoding: .utf8)
        precondition(before != PluginScanRecord.fingerprint(bundle), "Bundle content changes must invalidate the cache")
        let plugin = catalog.plugins[0]
        precondition(plugin.matches(query: "", type: "", vendor: "", allowsInstruments: true))
        precondition(plugin.matches(query: "", type: "Sampler", vendor: "Native Instruments", allowsInstruments: true))
        precondition(!plugin.matches(query: "", type: "Fx", vendor: "Other", allowsInstruments: true))
        precondition(plugin.matches(query: "kontakt", type: "Fx", vendor: "Other", allowsInstruments: true), "Search must ignore categories")
        precondition(plugin.matches(query: "native", type: "Fx", vendor: "Other", allowsInstruments: true))
        precondition(!plugin.matches(query: "kontakt", type: "", vendor: "", allowsInstruments: false), "Search cannot enable unsupported instruments in item FX")
        precondition(PluginCatalog.pluginTimeout == 120, "Production timeout must be two minutes")
        let stuck = root.appendingPathComponent("Stuck.vst3")
        let healthy = root.appendingPathComponent("Healthy.vst3")
        try "stuck".write(to: stuck, atomically: true, encoding: .utf8)
        try "healthy".write(to: healthy, atomically: true, encoding: .utf8)
        defaults.set([stuck.path, healthy.path], forKey: "jaras.plugins.paths")
        let bounded = PluginCatalog(defaults: defaults, executable: executable, timeout: 0.3)
        bounded.scan(); try await wait(bounded, limit: 4)
        precondition(bounded.completedPlugins == 2 && bounded.plugins.count == 1 && bounded.hasFailedPlugins)
        precondition(bounded.status.contains("2 minutes"), "Timeout must be reported")
        let cachedFailure = PluginCatalog(defaults: defaults, executable: executable, timeout: 0.3)
        cachedFailure.scan(); try await wait(cachedFailure, limit: 3)
        precondition((try? String(contentsOf: stuck.appendingPathExtension("scans"))) == "1", "Failed plugin was loaded after reopening")
        cachedFailure.scan(retryFailed: true); try await wait(cachedFailure, limit: 3)
        precondition((try? String(contentsOf: stuck.appendingPathExtension("scans"))) == "2", "Manual retry was ignored")
        try "recovered".write(to: stuck, atomically: true, encoding: .utf8)
        cachedFailure.scan(); try await wait(cachedFailure, limit: 3)
        precondition(cachedFailure.plugins.count == 2 && !cachedFailure.hasFailedPlugins, "Changed plugin did not recover")
        print("Plugin catalog: slow scan, persistent cache, changed/missing bundles, cancellation, filters and global search passed")
    } catch { fatalError("Catalog test failed: \(error)") }
    exit(0)
}
dispatchMain()
