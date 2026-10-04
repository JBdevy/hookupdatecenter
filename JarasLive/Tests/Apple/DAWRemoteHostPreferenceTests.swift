// Compiled in the same harness as the production session and loopback helpers.
let hostPreferenceSuite = "catlive.remote.host-test-" + UUID().uuidString
let hostPreferences = UserDefaults(suiteName: hostPreferenceSuite)!
defer { hostPreferences.removePersistentDomain(forName: hostPreferenceSuite) }
func preferenceHost() -> DAWRemoteSession {
    DAWRemoteSession(role: .host, name: "Preference test Mac",
                     policy: DAWRemoteAccessPolicy(preferences: hostPreferences), hostPreferences: hostPreferences)
}
let firstLaunchHost = preferenceHost()
firstLaunchHost.restoreHostPreference()
require(!firstLaunchHost.enabled && hostPreferences.object(forKey: "catlive.remote.enabled") == nil,
        "a fresh installation starts Remote off without inventing a saved preference")
require(firstLaunchHost.setDirectorPIN("0742"), "existing director password can be set before enabling Remote")
let preferenceCredential = hostPreferences.data(forKey: "catlive.remote.directorPIN")
firstLaunchHost.setHostEnabled(true)
require(firstLaunchHost.enabled && hostPreferences.bool(forKey: "catlive.remote.enabled"),
        "explicit enable starts the host and records its global intention")
firstLaunchHost.stop()
require(!firstLaunchHost.enabled && hostPreferences.bool(forKey: "catlive.remote.enabled"),
        "lifecycle shutdown must not overwrite the saved enabled intention")

let nextLaunchHost = preferenceHost()
nextLaunchHost.restoreHostPreference()
require(nextLaunchHost.enabled && nextLaunchHost.directorRequiresPIN,
        "another app launch restores Remote and retains the independent director password")
require(hostPreferences.data(forKey: "catlive.remote.directorPIN") == preferenceCredential,
        "restoring Remote cannot replace or remove the director credential")
nextLaunchHost.stop()
require(hostPreferences.bool(forKey: "catlive.remote.enabled"), "listener teardown also preserves the launch preference")
print("REMOTE_GLOBAL_ENABLE_RELAUNCH_LIFECYCLE_STOP_AND_PIN_PRESERVATION_OK")

// The same preference follows any project and repeated startup/binding work
// must not restart a live connection or revoke its role.
var preferenceFixture = fixture
nextLaunchHost.stateProvider = { preferenceFixture }
let preferenceEndpoint = try nextLaunchHost.testListen()
let preferenceClient = DAWRemoteSession(role: .client, name: "Preference test iPad", hostPreferences: hostPreferences)
preferenceClient.testConnect(preferenceEndpoint, access: .observer)
waitFor("restored host accepts the existing observer role") {
    preferenceClient.remoteState?.project == preferenceFixture.project && preferenceClient.accessMode == .observer
}
preferenceFixture.project = UUID(); preferenceFixture.projectName = "Another global preference project"
nextLaunchHost.restoreHostPreference()
waitFor("restored Remote survives a project switch") { preferenceClient.remoteState?.project == preferenceFixture.project }
require(nextLaunchHost.connected && preferenceClient.connected && preferenceClient.accessMode == .observer &&
        hostPreferences.bool(forKey: "catlive.remote.enabled"),
        "project changes preserve Remote, its saved setting and the connected role")
preferenceClient.setHostEnabled(false)
require(preferenceClient.enabled && hostPreferences.bool(forKey: "catlive.remote.enabled"),
        "a client cannot modify the Mac host preference")
preferenceClient.stop()
require(hostPreferences.bool(forKey: "catlive.remote.enabled"), "leaving an iPad session cannot disable Remote on next Mac launch")

nextLaunchHost.setHostEnabled(false)
require(!nextLaunchHost.enabled && hostPreferences.object(forKey: "catlive.remote.enabled") as? Bool == false,
        "explicit disable stops the host and saves Off")
let disabledLaunchHost = preferenceHost()
disabledLaunchHost.restoreHostPreference()
require(!disabledLaunchHost.enabled && disabledLaunchHost.directorRequiresPIN,
        "the next launch stays off while preserving its password configuration")
disabledLaunchHost.stop()
require(hostPreferences.object(forKey: "catlive.remote.enabled") as? Bool == false,
        "shutdown preserves an explicit Off preference too")
print("REMOTE_GLOBAL_PROJECT_SWITCH_IDEMPOTENT_RESTORE_CLIENT_ISOLATION_AND_OFF_RELAUNCH_OK")

extension DAWRemoteSession { var testAdvertisedName: String? { listener?.service?.name } }
let namedHost = preferenceHost()
namedHost.stateProvider = { preferenceFixture }
let namedEndpoint = try namedHost.testListen()
let namedClient = DAWRemoteSession(role: .client, name: "Test phone")
namedClient.testConnect(namedEndpoint, access: .observer)
waitFor("initial name connection") { namedClient.remoteState != nil }
let chosenName = "PC do palco - " + String(repeating: "A", count: 42)
namedHost.setHostName(chosenName)
require(namedHost.testAdvertisedName == chosenName, "Bonjour uses the full chosen name, including more than 40 characters")
require(namedClient.connected && namedClient.accessMode == .observer, "naming the host preserves existing remote clients")
let renamedClient = DAWRemoteSession(role: .client, name: "Second phone")
renamedClient.testConnect(namedEndpoint, access: .observer)
waitFor("chosen name handshake") { renamedClient.remoteState != nil }
require(renamedClient.peerName == chosenName, "connected PC name matches the device list and discovery")
renamedClient.stop(); namedClient.stop(); namedHost.stop()
print("REMOTE_CHOSEN_DEVICE_NAME_DISCOVERY_HANDSHAKE_AND_CONNECTION_PRESERVATION_OK")
