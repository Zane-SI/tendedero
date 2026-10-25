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
enum ThirdPartyCapture {
    /// One app whose new screenshots can be sent to Tendedero's folder.
    struct App: Equatable {
        /// Stable id, also the UserDefaults domain the app reads.
        let id: String
        /// What the menu shows. The app's own name, not a translation.
        let name: String
        /// `screenshotSaveDirectory` in Clip: a keyed-archive of a file URL.
        /// Absent means the app is still on its own default folder.
        let directoryKey: String
        /// Where captures go while the key is absent. `nil` when that default
        /// is not a folder Tendedero can watch, so the app is skipped until
        /// the user has chosen one.
        let defaultDirectory: URL?

        fileprivate var domain: CFString { id as CFString }
        fileprivate var key: CFString { directoryKey as CFString }
    }

    /// Clip (`com.chengffei.clip`) stores the folder chosen in its settings.
    /// Until one is chosen the key is absent and captures stay in the app.
    static let known: [App] = [
        App(id: "com.chengffei.clip", name: "Clip",
            directoryKey: "screenshotSaveDirectory", defaultDirectory: nil),
    ]

    private static let enabledKey = "thirdPartyCaptureEnabled"
    private static let savedKey = "thirdPartyCaptureSaved"

    /// The user's choice, kept across launches. Nothing is written to another
    /// app until this is on and that app is actually installed.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Known apps that are on this Mac. Detection is the bundle id, so a
    /// renamed copy still counts and an unrelated app does not.
    static func installed() -> [App] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var found: [App] = []
        for app in known where bundleExists(id: app.id, in: roots) {
            found.append(app)
        }
        return found
    }

    /// Points every installed app at Tendedero's folder, remembering what
    /// each one had. An app already pointing there is left out of that
    /// memory, so a crash cannot save Tendedero's own folder as the user's.
    static func apply() {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        for app in installed() { apply(to: app) }
    }

    /// One app, so a test can drive a stand-in domain instead of whatever is
    /// installed on the machine. Same rule: a folder that already points at
    /// Tendedero is not remembered over the user's own.
    static func apply(to app: App) {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        guard !isRedirected(app) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        saved[app.id] = snapshot(of: app)
        UserDefaults.standard.set(saved, forKey: savedKey)
        write(Inbox.folder, to: app)
    }

    /// Puts back only the apps still pointing at Tendedero. One the user
    /// moved somewhere else while the option was on is theirs again.
    static func restore() {
        for app in installed() { restore(app) }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Puts one app back and drops it from the memory. The others stay.
    static func restore(_ app: App) {
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if isRedirected(app) { writeBack(saved[app.id] as? [String: Any], to: app) }
        saved[app.id] = nil
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedKey)
        } else {
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
    }

    /// Where an app saves right now: the preference when it has one, otherwise
    /// its default folder. `nil` when there is nothing to watch.
    static func saveDirectory(of app: App) -> URL? {
        if let stored = readURL(app) { return stored }
        guard let fallback = app.defaultDirectory else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return fallback
    }

    /// Whether this app's preference currently names Tendedero's folder.
    static func isRedirected(_ app: App) -> Bool {
        guard let current = readURL(app) else { return false }
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

    /// The folder stored for this app, when the value is an archived file URL
    /// and the folder is still there. Anything else is left unread.
    private static func readURL(_ app: App) -> URL? {
        guard let data = CFPreferencesCopyAppValue(app.key, app.domain) as? Data,
              let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?,
              url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    private static func bundleExists(id: String, in roots: [URL]) -> Bool {
        for root in roots {
            guard let apps = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for app in apps where app.pathExtension == "app" {
                let info = app.appendingPathComponent("Contents/Info.plist")
                guard let bundleID = NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String,
                      bundleID == id else { continue }
                return true
            }
        }
        return false
    }
}
