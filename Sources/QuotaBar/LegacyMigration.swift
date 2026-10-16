import Foundation

/// One-time carry-over from the app's previous name (DeskApp, bundle id `asia.solarapp.deskapp`):
/// preferences and the Application Support folder (limit history, Claude Code scan cache).
enum LegacyMigration {
    private static let oldBundleID = "asia.solarapp.deskapp"
    private static let doneKey = "migratedFromDeskApp"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = defaults.persistentDomain(forName: oldBundleID) {
            // The app now forces English itself; everything else is copied unless already set.
            for (key, value) in old where key != "AppleLanguages" && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("DeskApp")
        let newFolder = support.appendingPathComponent("QuotaBar")
        if fm.fileExists(atPath: oldFolder.path), !fm.fileExists(atPath: newFolder.path) {
            try? fm.moveItem(at: oldFolder, to: newFolder)
        }
    }
}
