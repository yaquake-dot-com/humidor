// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Chat rooms page.
struct ChatRoomsView: View {

    @Bindable var page: ChatRoomsPage

    private var hasTabs: Bool { !page.notebook.pages.isEmpty }

    /// Current room, if it has a list of users
    private var currentRoom: ChatRoomTab? {
        guard let tab = page.notebook.currentPage, !tab.isGlobal else {
            return nil
        }
        return tab
    }

    private var usersInspectorBinding: Binding<Bool> {
        Binding(
            get: { page.isUsersListShown && currentRoom != nil },
            set: { page.isUsersListShown = $0 }
        )
    }

    private var entryBar: some View {
        HStack(spacing: 6) {
            SearchField(placeholder: String(localized: "Join or create room…"), text: $page.roomText,
                        recentTitle: String(localized: "Rooms"), recentItems: page.roomList.roomNames, completions: page.roomList.roomNames, focusRequest: page.roomFocusRequest) {
                page.onCreateRoom()
            }
            .disabled(!page.isRoomEntryEnabled)

            Button {
                page.isRoomListShown.toggle()
            } label: {
                Label(String(localized: "Rooms"), systemImage: "list.bullet")
                    .labelStyle(.titleAndIcon)
            }
            .popover(isPresented: $page.isRoomListShown) {
                RoomListView(roomList: page.roomList)
            }
        }
    }

    var body: some View {
        HSplitView {
            Group {
                if hasTabs {
                    NotebookView(notebook: page.notebook)
                } else {
                    PageStart(
                        systemImage: "bubble.left.and.bubble.right",
                        title: String(localized: "Chat Rooms"),
                        description: String(localized: "Join an existing chat room, or create a new room to chat with other users on the Soulseek network"),
                        recentTitle: String(localized: "Rooms"),
                        recentItems: page.roomList.roomNames,
                        onSelectItem: { room in
                            page.roomText = room
                            page.onCreateRoom()
                        }
                    ) {
                        entryBar
                    }
                }
            }
            .frame(minWidth: 400)
            .layoutPriority(1)

            if page.window.buddies.position == "chatrooms" {
                page.window.buddies.content
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
            }
        }
        .toolbar {
            if hasTabs {
                ToolbarItem(placement: .navigation) {
                    entryBar
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 400)
                }
            }

            ToolbarItem {
                Button {
                    Application.shared.onConfigureChats()
                } label: {
                    Label(String(localized: "Configure Chats"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Chats"))
            }

            if currentRoom != nil {
                ToolbarItem {
                    Toggle(isOn: $page.isUsersListShown) {
                        Label(String(localized: "Users"), systemImage: "sidebar.trailing")
                    }
                    .help(String(localized: "Users"))
                }
            }
        }
        .inspector(isPresented: usersInspectorBinding) {
            if let room = currentRoom {
                RoomUsersView(tab: room)
                    .inspectorColumnWidth(min: 220, ideal: 320, max: 700)
            }
        }
    }
}

/// A single chat room: activity log, chat messages and room users.
struct ChatRoomTabView: View {

    @Bindable var tab: ChatRoomTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.isGlobal {
                tab.chatView.view
            } else {
                VSplitView {
                    tab.activityView.view
                        .frame(minHeight: 48, idealHeight: 80)

                    tab.chatView.view
                        .frame(minHeight: 100)
                        .layoutPriority(1)
                }
            }

            Divider()
            chatEntryRow
        }
    }

    @ViewBuilder private var chatEntryRow: some View {
        if tab.isGlobal {
            HStack {
                Spacer()
                chatButtons
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else {
            ChatEntryBar(chatEntry: tab.chatrooms.chatEntry, interface: .chatroom,
                         helpTooltip: String(localized: "Chat Room Command Help")) {
                chatButtons
            }
        }
    }

    @ViewBuilder private var chatButtons: some View {
        if tab.isLogToggleVisible {
            Toggle(isOn: $tab.isLogEnabled) {
                Image(systemName: "doc.text")
            }
            .toggleStyle(.button)
            .help(String(localized: "Log"))
        }

        if tab.isSpeechToggleVisible {
            Toggle(isOn: $tab.isSpeechEnabled) {
                Image(systemName: "speaker.wave.2")
            }
            .toggleStyle(.button)
            .help(String(localized: "Toggle Text-to-Speech"))
        }
    }

}

/// Users of a chat room, shown in the inspector of the chat rooms page.
struct RoomUsersView: View {

    @Bindable var tab: ChatRoomTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.userCountText, systemImage: "person.2")
                    .help(String(localized: "Users"))

                Spacer()

                Button {
                    tab.isRoomWallShown.toggle()
                } label: {
                    Label(String(localized: "Room Wall"), systemImage: "note.text")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Room Wall"))
                .popover(isPresented: $tab.isRoomWallShown) {
                    RoomWallView(roomWall: tab.roomWall)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
            tab.usersListView.view
        }
    }
}

/// Popover listing the rooms on the server.
struct RoomListView: View {

    @Bindable var roomList: RoomListPopover

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(String(localized: "Search rooms…"), text: $roomList.searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    roomList.onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(String(localized: "Refresh Rooms"))
            }

            ListBox(listView: roomList.listView)

            Toggle(String(localized: "Show feed of public chat room messages"), isOn: $roomList.isPublicFeedEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(String(localized: "Accept private room invitations"), isOn: $roomList.isPrivateRoomsAccepted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(width: 450, height: 500)
    }
}

/// Popover showing the room wall messages.
struct RoomWallView: View {

    @Bindable var roomWall: RoomWall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Write a single message that other room users can read later. Recent messages are shown at the top."))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ComboBox(placeholder: String(localized: "Set wall message…"), text: $roomWall.messageText,
                         focusRequest: roomWall.messageFocusRequest, onSubmit: { roomWall.onSetRoomWallMessage() })

                Button {
                    roomWall.onClearMessage()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }

            roomWall.messageView.view
                .roundedFrame()
        }
        .padding()
        .frame(width: 650, height: 500)
        .onAppear {
            roomWall.onShow()
        }
    }
}
