// SPDX-License-Identifier: GPL-3.0-or-later

/// Application metadata.
public enum Application {
    public static let name = "Humidor"
    public static let identifier = "org.humidor.Humidor"
    public static let version = "3.3.10"

    /// The application this one is derived from
    public static let originalName = "Nicotine+"
    public static let originalWebsiteURL = "https://nicotine-plus.org"

    public static let copyright = """
        © 2004–2025 Nicotine+ Contributors
        © 2003–2004 Nicotine Contributors
        © 2001–2003 PySoulSeek Contributors
        """
    public static let websiteURL = "https://nicotine-plus.org"
    public static func privilegesURL(username: String) -> String {
        "https://www.slsknet.org/qtlogin.php?username=\(username)"
    }

    public static func portCheckerURL(port: Int) -> String {
        "https://www.slsknet.org/porttest.php?port=\(String(port))"
    }
    public static let issueTrackerURL = "https://github.com/nicotine-plus/nicotine-plus/issues"
    public static let translationsURL = "https://nicotine-plus.org/doc/TRANSLATIONS"
}
