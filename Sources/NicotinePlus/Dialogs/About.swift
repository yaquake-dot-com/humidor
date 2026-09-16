// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// About dialog, with version information, credits and license.
@MainActor
@Observable
final class About {

    enum VersionStatus {
        case checking
        case error(String)
        case outdated(String)
        case upToDate
    }

    private(set) var versionStatus: VersionStatus?
    @ObservationIgnored private var isVersionOutdated = false
    @ObservationIgnored private var dialog: DialogWindow!

    init() {
        dialog = DialogWindow(title: String(localized: "About"), width: 425, height: 540) { [unowned self] in
            AboutView(about: self)
        }
        dialog.showCallback = { [unowned self] in onShow() }

        events.connect(.checkLatestVersion) { [unowned self] in onCheckLatestVersion($0) }
    }

    func present() {
        dialog.present()
    }

    private func onCheckLatestVersion(_ info: LatestVersionInfo) {
        if let error = info.errorMessage {
            versionStatus = .error(String(localized: "Error checking latest version: \(error)"))
        } else if info.isOutdated {
            versionStatus = .outdated(String(localized: "New release available: \(info.latestVersion ?? "")"))
        } else {
            versionStatus = .upToDate
        }

        isVersionOutdated = info.isOutdated
    }

    private func onShow() {
        guard let updateChecker = core.updateChecker, !isVersionOutdated else {
            // Update checker is not loaded, or no need to check latest version again
            return
        }

        versionStatus = .checking
        updateChecker.check()
    }
}

private struct AboutView: View {

    let about: About

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("\(NicotineCore.Application.name) \(NicotineCore.Application.version)")
                    .font(.title2.bold())
                    .textSelection(.enabled)

                Text(verbatim: "Swift \(swiftVersion)   •   macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let status = about.versionStatus {
                    versionStatusView(status)
                }

                Text(String(localized: "Based on \(NicotineCore.Application.originalName), a graphical client for the Soulseek network"))
                    .font(.callout)
                    .multilineTextAlignment(.center)

                Link(NicotineCore.Application.originalName,
                     destination: URL(string: NicotineCore.Application.originalWebsiteURL)!)

                Text(NicotineCore.Application.copyright)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                creditsSection(String(localized: "Created by"), About.authors)
                creditsSection(String(localized: "Translated by"), About.translators)
                creditsSection(String(localized: "License"), About.license)
            }
            .padding(24)
        }
    }

    private var swiftVersion: String {
        #if swift(>=6.2)
        "6.2"
        #elseif swift(>=6.1)
        "6.1"
        #else
        "6.0"
        #endif
    }

    @ViewBuilder private func versionStatusView(_ status: About.VersionStatus) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Checking latest version…"))

            case let .error(message):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(message)

            case let .outdated(message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)

            case .upToDate:
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                Text(String(localized: "Up to date"))
            }
        }
        .font(.callout)
    }

    private func creditsSection(_ title: String, _ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Text((try? AttributedString(markdown: entry, options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
