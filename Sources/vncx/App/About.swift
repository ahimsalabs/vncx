import AppKit

/// Build identity stamped into Info.plist by `task bundle`.
enum BuildInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = info["CFBundleVersion"] as? String ?? "0"
    /// Full commit hash, possibly with a "-dirty" suffix; nil when run outside a stamped bundle (swift run).
    static let commit = info["VNCXGitCommit"] as? String
    static let buildDate = info["VNCXBuildDate"] as? String

    static var shortCommit: String? {
        guard let commit else { return nil }
        let dirty = commit.hasSuffix("-dirty")
        let hash = commit.replacingOccurrences(of: "-dirty", with: "")
        return String(hash.prefix(7)) + (dirty ? "-dirty" : "")
    }

    /// One line for bug reports: "vncx 0.1.0 (21) e98a754, built 2026-10-03T18:40Z".
    static var summary: String {
        var s = "vncx \(version) (\(build))"
        if let shortCommit { s += " \(shortCommit)" }
        if let buildDate { s += ", built \(buildDate)" }
        return s
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        if let commit {
            let short = String(commit.replacingOccurrences(of: "-dirty", with: "").prefix(7))
            credits.append(NSAttributedString(string: "Commit ", attributes: base))
            var link = base
            let hash = commit.replacingOccurrences(of: "-dirty", with: "")
            link[.link] = URL(string: "https://github.com/ahimsalabs/vncx/commit/\(hash)")
            link[.foregroundColor] = NSColor.linkColor
            credits.append(NSAttributedString(string: short, attributes: link))
            if commit.hasSuffix("-dirty") {
                credits.append(NSAttributedString(string: " (with uncommitted changes)", attributes: base))
            }
        } else {
            credits.append(NSAttributedString(string: "Development build (not bundled)", attributes: base))
        }
        if let buildDate {
            credits.append(NSAttributedString(string: "\nBuilt \(buildDate)", attributes: base))
        }
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .version: build, // AppKit shows this in parentheses after the version
            .credits: credits,
        ])
    }
}
