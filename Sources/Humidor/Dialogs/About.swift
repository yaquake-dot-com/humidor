// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
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

    init() {
        events.connect(.checkLatestVersion) { [unowned self] in onCheckLatestVersion($0) }
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

    func onShow() {
        guard let updateChecker = core.updateChecker, !isVersionOutdated else {
            // Update checker is not loaded, or no need to check latest version again
            return
        }

        versionStatus = .checking
        updateChecker.check()
    }
}

struct AboutView: View {

    let about: About

    var body: some View {
        content
            .onAppear {
                about.onShow()
            }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("\(Application.name) \(Application.version)")
                    .font(.title2.bold())
                    .textSelection(.enabled)

                Text(verbatim: "Swift \(swiftVersion)   •   macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let status = about.versionStatus {
                    versionStatusView(status)
                }

                Text(String(localized: "Based on \(Application.originalName), a graphical client for the Soulseek network"))
                    .font(.callout)
                    .multilineTextAlignment(.center)

                Link(Application.originalName,
                     destination: URL(string: Application.originalWebsiteURL)!)

                Text(Application.copyright)
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
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.orange)
                Link(destination: URL(string: Application.latestReleaseURL)!) {
                    Text(message)
                }

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
