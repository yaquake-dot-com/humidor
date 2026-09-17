// SPDX-License-Identifier: GPL-3.0-or-later

/// Application metadata.
public enum Application {
    public static let name = "Humidor"
    public static let identifier = "org.humidor.Humidor"
    public static let version = "1.1.2"

    /// Address returning the latest released version, as the "tag_name" of a GitHub release.
    /// No version check is made while this is empty.
    public static let latestVersionURL: String? = "https://api.github.com/repos/yaquake-dot-com/humidor/releases/latest"

    /// The application this one is derived from
    public static let originalName = "Nicotine+"
    public static let originalWebsiteURL = "https://nicotine-plus.org"

    public static let copyright = """
        © 2026 Ivan Eresko
        © 2004–2025 Nicotine+ Contributors
        © 2003–2004 Nicotine Contributors
        © 2001–2003 PySoulSeek Contributors
        """
    public static let websiteURL = "https://github.com/yaquake-dot-com/humidor"
    public static func privilegesURL(username: String) -> String {
        "https://www.slsknet.org/qtlogin.php?username=\(username)"
    }

    public static func portCheckerURL(port: Int) -> String {
        "https://www.slsknet.org/porttest.php?port=\(String(port))"
    }
    public static let issueTrackerURL = "https://github.com/nicotine-plus/nicotine-plus/issues"
    public static let translationsURL = "https://nicotine-plus.org/doc/TRANSLATIONS"
}
