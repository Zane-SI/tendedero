import AppKit
import Foundation

/// Third-party screenshot apps Tendedero can take over the same way it takes
/// over macOS: by pointing their save folder at its own, and putting the
/// previous value back when the option is turned off or the app quits.
///
/// An app is offered only when it is installed and its save folder is a
/// preference another process can read and write. CleanShot X and Shottr are
/// not. Neither publishes a save-folder preference: Shottr asks for the
/// folder in its own settings, and CleanShot's is not a key another app can
/// set. Taking either over would mean driving its windows, which Tendedero
/// does not do, so both are left alone.
public enum ThirdPartyCapture {
    /// One app whose new screenshots can be sent to Tendedero's folder.
    public struct App: Equatable {
        /// Stable id, also the UserDefaults domain the app reads.
        public let id: String
        /// What the menu shows. The app's own name, not a translation.
        public let name: String
        /// `screenshotSaveDirectory` in Clip: a keyed-archive of a file URL.
        /// Absent means the app is still on its own default folder.
        public let directoryKey: String

        public init(id: String, name: String, directoryKey: String) {
            self.id = id
            self.name = name
            self.directoryKey = directoryKey
        }

        fileprivate var domain: CFString { id as CFString }
        fileprivate var key: CFString { directoryKey as CFString }
    }

    /// Clip (`com.chengffei.clip`) stores the folder chosen in its settings.
    /// Until one is chosen the key is absent and captures stay in the app.
    public static let known: [App] = [
        App(id: "com.chengffei.clip", name: "Clip",
            directoryKey: "screenshotSaveDirectory"),
    ]

    private static let enabledKey = "thirdPartyCaptureEnabled"
    private static let savedKey = "thirdPartyCaptureSaved"

    /// The user's choice, kept across launches. Nothing is written to another
    /// app until this is on and that app is actually installed.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Known apps that are on this Mac. Launch Services matches the bundle id
    /// wherever the app lives, so a renamed or nested copy still counts and an
    /// unrelated app does not.
    public static func installed() -> [App] {
        known.filter { bundleExists(id: $0.id) }
    }

    /// Points every installed app at Tendedero's folder, remembering what
    /// each one had. An app already pointing there is left out of that
    /// memory, so a crash cannot save Tendedero's own folder as the user's.
    public static func apply() {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        for app in installed() { apply(to: app) }
    }

    /// One app, so a test can drive a stand-in domain instead of whatever is
    /// installed on the machine. Same rule: a folder that already points at
    /// Tendedero is not remembered over the user's own.
    public static func apply(to app: App) {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        guard !isRedirected(app) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        saved[app.id] = snapshot(of: app)
        UserDefaults.standard.set(saved, forKey: savedKey)
        // The snapshot has to reach disk before the other app is redirected.
        // A kill in between would leave the redirect and forget the folder.
        guard UserDefaults.standard.synchronize() else { return }
        write(Inbox.folder, to: app)
    }

    /// Puts back every known app we redirected, from the snapshot, even when
    /// it is not on this Mac right now. A later reinstall gets its own folder.
    /// One the user moved somewhere else is left alone.
    public static func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        for id in saved.keys {
            guard let app = known.first(where: { $0.id == id }) else { continue }
            restore(app)
        }
    }

    /// Puts one app back and drops it from the memory. The others stay.
    public static func restore(_ app: App) {
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if isRedirected(app) { writeBack(saved[app.id] as? [String: Any], to: app) }
        saved[app.id] = nil
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedKey)
        } else {
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
    }

    /// Where an app saves right now, when that folder is still on disk.
    /// `nil` when the key is absent or the folder is gone, so there is nothing
    /// to watch.
    public static func saveDirectory(of app: App) -> URL? {
        guard let stored = storedURL(app) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stored.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return stored
    }

    /// Whether this app's preference names Tendedero's folder, even if that
    /// folder has since been removed. A missing folder is not a folder the
    /// user picked.
    public static func isRedirected(_ app: App) -> Bool {
        guard let current = storedURL(app) else { return false }
        return current.standardizedFileURL == Inbox.folder.standardizedFileURL
    }

    // MARK: - Reading and writing one preference

    /// What to put back. `present` is false when the key was absent, which is
    /// the app's own default and not the same as an empty path.
    private static func snapshot(of app: App) -> [String: Any] {
        guard let data = CFPreferencesCopyAppValue(app.key, app.domain) as? Data else {
            return ["present": false]
        }
        return ["present": true, "archive": data]
    }

    private static func write(_ folder: URL, to app: App) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: folder as NSURL, requiringSecureCoding: true) else { return }
        CFPreferencesSetAppValue(app.key, data as CFData, app.domain)
        CFPreferencesAppSynchronize(app.domain)
    }

    /// A snapshot with no archive removes the key, back to the app's default.
    private static func writeBack(_ snapshot: [String: Any]?, to app: App) {
        let archive = snapshot?["archive"] as? Data
        CFPreferencesSetAppValue(app.key, archive as CFData?, app.domain)
        CFPreferencesAppSynchronize(app.domain)
    }

    /// The archived folder, whether or not it is still on disk.
    private static func storedURL(_ app: App) -> URL? {
        guard let data = CFPreferencesCopyAppValue(app.key, app.domain) as? Data,
              let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?,
              url.isFileURL else { return nil }
        return url
    }

    private static func bundleExists(id: String) -> Bool {
        !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).isEmpty
    }
}
