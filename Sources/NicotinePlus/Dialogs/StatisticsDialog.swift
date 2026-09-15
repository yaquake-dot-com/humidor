// SPDX-License-Identifier: GPL-3.0-or-later

import NicotineCore
import Observation
import SwiftUI

/// Transfer statistics dialog.
@MainActor
@Observable
final class StatisticsDialog {

    private(set) var sessionValues: [StatisticID: String] = [:]
    private(set) var totalValues: [StatisticID: String] = [:]
    private(set) var totalSinceText = String(localized: "Total")
    @ObservationIgnored private var dialog: DialogWindow!

    init() {
        dialog = DialogWindow(title: String(localized: "Transfer Statistics"), isResizable: false) { [unowned self] in
            StatisticsView(statistics: self)
        }
        dialog.showCallback = { core.statistics.updateStats() }

        events.connect(.updateStat) { [unowned self] in updateStat($0) }
    }

    func present() {
        dialog.present()
    }

    private func updateStat(_ update: StatUpdate) {
        switch update.statID {
        case .downloadedSize, .uploadedSize:
            sessionValues[update.statID] = humanSize(update.sessionValue)
            totalValues[update.statID] = humanSize(update.totalValue)

        case .sinceTimestamp:
            if update.totalValue > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(update.totalValue))
                totalSinceText = String(localized: "Total Since \(formatTimestamp("%x", date: date))")
            }

        default:
            sessionValues[update.statID] = humanize(update.sessionValue)
            totalValues[update.statID] = humanize(update.totalValue)
        }
    }

    func onResetStatistics() {
        OptionDialog(
            title: String(localized: "Reset Transfer Statistics?"),
            message: String(localized: "Do you really want to reset transfer statistics?"),
            destructiveResponse: "ok"
        ) { _, _ in
            core.statistics.resetStats()
        }.present()
    }
}

private struct StatisticsView: View {

    let statistics: StatisticsDialog

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(String(localized: "Current Session"), values: statistics.sessionValues)
            section(statistics.totalSinceText, values: statistics.totalValues)

            HStack {
                Button(String(localized: "Reset…")) {
                    statistics.onResetStatistics()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 425)
    }

    private func section(_ title: String, values: [StatisticID: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row(String(localized: "Completed Downloads"), values[.completedDownloads])
                row(String(localized: "Downloaded Size"), values[.downloadedSize])
                row(String(localized: "Completed Uploads"), values[.completedUploads])
                row(String(localized: "Uploaded Size"), values[.uploadedSize])
            }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value ?? "0")
                .textSelection(.enabled)
        }
    }
}
