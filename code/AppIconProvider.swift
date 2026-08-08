import AppKit
import UniformTypeIdentifiers

final class AppIconProvider {
    static let shared = AppIconProvider()

    private var cache: [String: NSImage] = [:]

    func icon(for processName: String) -> NSImage {
        if let cached = cache[processName] { return cached }
        // Only cache a genuine match. A process sampled before its owning app
        // finishes registering with NSWorkspace (e.g. still launching) would
        // otherwise get the generic fallback icon cached permanently, even
        // after the real app shows up in runningApplications moments later.
        guard let icon = lookupIcon(for: processName) else { return fallbackIcon }
        cache[processName] = icon
        return icon
    }

    private func lookupIcon(for processName: String) -> NSImage? {
        let apps = NSWorkspace.shared.runningApplications
        // Prefer an exact name match over a partial one, so a short/ambiguous
        // process name (e.g. "Terminal") can't pick up some unrelated app's
        // icon just because that app's name happens to be a prefix/suffix.
        if let exact = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(processName) == .orderedSame }) {
            return exact.icon
        }
        if let partial = apps.first(where: { app in
            guard let name = app.localizedName, !name.isEmpty else { return false }
            return processName.hasPrefix(name) || name.hasPrefix(processName)
        }) {
            return partial.icon
        }
        return nil
    }

    private var fallbackIcon: NSImage {
        NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
