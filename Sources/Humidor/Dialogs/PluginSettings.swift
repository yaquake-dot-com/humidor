// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Dialog for editing the settings of a plugin.
@MainActor
@Observable
final class PluginSettingsDialog {

    struct Option: Identifiable {
        let name: String
        let meta: PluginSettingMeta

        var id: String { name }
    }

    private(set) var title = ""
    @ObservationIgnored private(set) var listViews: [String: TreeView] = [:]
    @ObservationIgnored private var listRowIDs: [String: Int] = [:]
    @ObservationIgnored private var pluginID: String?

    private(set) var options: [Option] = []
    var values: [String: JSONValue] = [:]

    func present() {
        AppDelegate.shared.openWindow(.pluginSettings)
    }

    func close() {
        AppDelegate.shared.closeWindow(.pluginSettings)
    }

    func updateSettings(pluginID: String, metaSettings: OrderedDictionary<String, PluginSettingMeta>) {
        let pluginName = core.pluginHandler?.pluginInfo(pluginID)?.name ?? pluginID
        let storedSettings = config.plugins.settings[pluginID.lowercased()] ?? [:]

        self.pluginID = pluginID
        title = String(localized: "\(pluginName) Settings")

        listViews.removeAll()
        listRowIDs.removeAll()
        values = [:]
        options = metaSettings.map { Option(name: $0.key, meta: $0.value) }

        for option in options {
            let value = storedSettings[option.name] ?? .null

            if option.meta.type == .listString {
                addListView(option, items: value.stringArrayValue ?? [])
            } else {
                values[option.name] = value
            }
        }
    }

    // MARK: Values

    func binding(_ name: String) -> Binding<String> {
        Binding(get: { self.values[name]?.stringValue ?? "" }, set: { self.values[name] = .string($0) })
    }

    func binding(_ name: String) -> Binding<Bool> {
        Binding(get: { self.values[name]?.boolValue ?? false }, set: { self.values[name] = .bool($0) })
    }

    func binding(_ name: String) -> Binding<Double> {
        Binding(get: { self.values[name]?.doubleValue ?? 0 }, set: { self.values[name] = .double($0) })
    }

    func binding(_ name: String) -> Binding<Int> {
        Binding(get: { self.values[name]?.intValue ?? 0 }, set: { self.values[name] = .int($0) })
    }

    // MARK: Lists

    private func addListView(_ option: PluginSettingsDialog.Option, items: [String]) {
        let listView = TreeView(
            columns: [
                TreeColumn(id: "description", title: option.meta.description),

                // Hidden data columns
                .data("id_data", isIteratorKey: true, sortOrder: .ascending)
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEdit(option) },
            deleteAccelerator: { [unowned self] _ in onRemove(option) }
        )

        for (index, item) in items.enumerated() {
            listView.addRow([.string(item), .int(index)], selectRow: false)
        }

        listViews[option.name] = listView
        listRowIDs[option.name] = items.count
    }

    func onAdd(_ option: Option) {
        EntryDialog(
            title: String(localized: "Add Item"),
            message: option.meta.description,
            actionButtonLabel: String(localized: "Add")
        ) { [weak self] dialog, _ in
            guard let self, let value = (dialog as? EntryDialog)?.entryValue, !value.isEmpty,
                  let listView = listViews[option.name] else {
                return
            }

            let rowID = (listRowIDs[option.name] ?? 0) + 1
            listRowIDs[option.name] = rowID
            listView.addRow([.string(value), .int(rowID)])
        }.present()
    }

    func onEdit(_ option: Option) {
        guard let listView = listViews[option.name], let row = listView.selectedRows.first else {
            return
        }

        let value = listView.rowValue(row, "description").string
        let rowID = listView.rowValue(row, "id_data")

        EntryDialog(
            title: String(localized: "Edit Item"),
            message: option.meta.description,
            defaultText: value,
            actionButtonLabel: String(localized: "Edit")
        ) { dialog, _ in
            guard let value = (dialog as? EntryDialog)?.entryValue, !value.isEmpty,
                  let row = listView.iterators[rowID] else {
                return
            }

            listView.removeRow(row)
            listView.addRow([.string(value), rowID])
        }.present()
    }

    func onRemove(_ option: Option) {
        guard let listView = listViews[option.name] else {
            return
        }

        for row in listView.selectedRows.reversed() {
            if let originalRow = listView.iterators[listView.rowValue(row, "id_data")] {
                listView.removeRow(originalRow)
            }
        }
    }

    // MARK: Applying

    func onOK() {
        guard let pluginID, let plugin = core.pluginHandler?.enabledPlugins[pluginID] else {
            close()
            return
        }

        for option in options {
            switch option.meta.type {
            case .listString:
                guard let listView = listViews[option.name] else {
                    continue
                }

                let rows = listView.iterators.sorted { $0.key.int < $1.key.int }
                plugin.settings[option.name] = .array(rows.map { .string(listView.rowValue($0.value, "description").string) })

            case .integer:
                plugin.settings[option.name] = .int(values[option.name]?.intValue ?? 0)

            case .float:
                plugin.settings[option.name] = .double(values[option.name]?.doubleValue ?? 0)

            default:
                if let value = values[option.name], value != .null {
                    plugin.settings[option.name] = value
                }
            }
        }

        core.pluginHandler?.savePluginSettings(pluginID)
        close()
    }
}

struct PluginSettingsView: View {

    let dialog: PluginSettingsDialog

    var body: some View {
        content
            .navigationTitle(dialog.title)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(dialog.options) { option in
                    optionView(option)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
        .frame(minWidth: 400, minHeight: 300)
        .bottomBar {
            HStack {
                Spacer()

                Button(String(localized: "Cancel")) { dialog.close() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply")) { dialog.onOK() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func optionView(_ option: PluginSettingsDialog.Option) -> some View {
        let meta = option.meta

        switch meta.type {
        case .integer, .float:
            let minimum = meta.minimum ?? 0
            let maximum = meta.maximum ?? 99999
            let stepSize = meta.stepSize ?? 1

            optionRow(meta.description) {
                HStack(spacing: 4) {
                    if meta.type == .integer {
                        TextField("", value: dialog.binding(option.name) as Binding<Int>, format: .number.grouping(.never))
                            .frame(width: 80)
                        Stepper("", value: dialog.binding(option.name) as Binding<Int>,
                                in: Int(minimum)...Int(maximum), step: Int(stepSize))
                            .labelsHidden()
                    } else {
                        TextField("", value: dialog.binding(option.name) as Binding<Double>,
                                  format: .number.precision(.fractionLength(2)).grouping(.never))
                            .frame(width: 80)
                        Stepper("", value: dialog.binding(option.name) as Binding<Double>,
                                in: minimum...maximum, step: stepSize)
                            .labelsHidden()
                    }
                }
            }

        case .bool:
            optionRow(meta.description) {
                Toggle("", isOn: dialog.binding(option.name) as Binding<Bool>)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

        case .dropdown:
            optionRow(meta.description) {
                Picker("", selection: dialog.binding(option.name) as Binding<String>) {
                    ForEach(meta.options, id: \.self) { item in
                        Text(item).tag(item)
                    }
                }
                .labelsHidden()
            }

        case .string:
            optionRow(meta.description) {
                TextField("", text: dialog.binding(option.name) as Binding<String>)
            }

        case .textView:
            VStack(alignment: .leading, spacing: 6) {
                Text(meta.description)
                TextEditor(text: dialog.binding(option.name) as Binding<String>)
                    .font(.body)
                    .frame(minHeight: 125)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }
            }

        case .listString:
            if let listView = dialog.listViews[option.name] {
                ListBox(listView: listView, height: 125, buttons: [
                    .add { dialog.onAdd(option) },
                    .edit { dialog.onEdit(option) },
                    .remove { dialog.onRemove(option) }
                ])
                .padding(.top, 6)
            }

        case .file, .folder:
            optionRow(meta.description) {
                FileChooserButton(path: dialog.binding(option.name) as Binding<String>,
                                  chooserType: meta.type == .folder ? .folder : .file,
                                  showsOpenButton: !AppDelegate.shared.isolatedMode)
            }
        }
    }

    private func optionRow(_ description: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            if !description.isEmpty {
                Text(description)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content()
        }
    }
}
