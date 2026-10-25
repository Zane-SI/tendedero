import CaptureSettings
import Foundation

/// Checks ThirdPartyCapture against a stand-in preference domain, so a real
/// screenshot app is never touched. scripts/build-app.sh runs this target
/// and stops the build when a check fails. Prints one line per check.

let domain = "com.tendedero.third-party-capture.check"
let key = "screenshotSaveDirectory" as CFString
let domainCF = domain as CFString
let app = ThirdPartyCapture.App(
    id: domain, name: "Stand-in", directoryKey: "screenshotSaveDirectory", defaultDirectory: nil)

func fail(_ message: String) -> Never {
    fputs("FAIL \(message)\n", stderr)
    exit(1)
}

func archive(_ folder: URL) -> Data {
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: folder as NSURL, requiringSecureCoding: true) else {
        fail("could not archive \(folder.path)")
    }
    return data
}

func stored() -> Data? {
    CFPreferencesCopyAppValue(key, domainCF) as? Data
}

@main
enum CheckThirdParty {
    static func main() throws {
        try run()
    }
}

private func run() throws {
let own = FileManager.default.temporaryDirectory
    .appendingPathComponent("tendedero-own-\(UUID().uuidString)", isDirectory: true)
defer {
    CFPreferencesSetAppValue(key, nil, domainCF)
    CFPreferencesAppSynchronize(domainCF)
    try? FileManager.default.removeItem(at: own)
    UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
}
try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
CFPreferencesSetAppValue(key, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")

// A folder the app already had comes back unchanged, not re-archived.
let before = archive(own)
CFPreferencesSetAppValue(key, before as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
ThirdPartyCapture.apply(to: app)
if ThirdPartyCapture.saveDirectory(of: app)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point the app at Tendedero")
}
ThirdPartyCapture.restore(app)
if stored() != before { fail("restore changed the folder the app had") }
print("restore keeps the previous folder")

// No key means the app's own default. Turning the option off removes the key.
CFPreferencesSetAppValue(key, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: app)
if ThirdPartyCapture.saveDirectory(of: app)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point an unset app at Tendedero")
}
ThirdPartyCapture.restore(app)
if stored() != nil { fail("restore left Tendedero's folder where none was set") }
print("restore clears a folder that was never set")

// A folder the user picks while the option is on is left alone.
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: app)
let moved = archive(own)
CFPreferencesSetAppValue(key, moved as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
ThirdPartyCapture.restore(app)
if stored() != moved { fail("restore overwrote a folder the user chose") }
print("restore leaves a folder the user moved")

print("ok")
}
