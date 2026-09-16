// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Chat rooms page.
struct ChatRoomsView: View {

    @Bindable var page: ChatRoomsPage

    private var hasTabs: Bool { !page.notebook.pages.isEmpty }

    /// Current room, if it has a list of users.
    private var currentRoom: ChatRoomTab? {
        guard let tab = page.notebook.currentPage, !tab.isGlobal else {
            return nil
        }
        return tab
    }

    private var showsBuddies: Bool {
        page.window.buddies.position == "chatrooms"
    }

    private var showsUsers: Bool {
        page.isUsersListShown && currentRoom != nil
    }

    private var entryBar: some View {
        HStack(spacing: 6) {
            entryField
            entryButton
        }
    }

    private var entryField: some View {
        SearchField(placeholder: String(localized: "Join or create room…"), text: $page.roomText,
                    recentTitle: String(localized: "Rooms"), recentItems: page.roomList.roomNames, completions: page.roomList.roomNames, focusRequest: page.roomFocusRequest) {
            page.onCreateRoom()
        }
        .disabled(!page.isRoomEntryEnabled)
    }

    private var entryButton: some View {
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

    @ViewBuilder private var roomsContent: some View {
        if hasTabs {
            NotebookView(notebook: page.notebook)
        } else {
            PageStart(
                systemImage: "bubble.left.and.bubble.right",
                title: String(localized: "Chat Rooms"),
                description: String(localized: "Join an existing chat room, or create a new room to chat with other users on the Soulseek network"),
                recentTitle: String(localized: "Rooms"),
                recentItems: page.roomList.popularRoomNames,
                onSelectItem: { room in
                    page.roomText = room
                    page.onCreateRoom()
                }
            ) {
                entryBar
            }
        }
    }

    var body: some View {
        SplitPane("ChatRooms.Users", edge: .trailing, range: 200...700, idealLength: 280,
                  isPaneVisible: showsUsers) {
            SplitPane("ChatRooms.Buddies", edge: .trailing, range: 180...600, idealLength: 250,
                      isPaneVisible: showsBuddies) {
                roomsContent
            } pane: {
                page.window.buddies.content
            }
        } pane: {
            if let currentRoom {
                RoomUsersView(tab: currentRoom)
            }
        }
        .toolbar {
            if hasTabs {
                ToolbarItem(placement: .navigation) {
                    entryField
                        .environment(\.searchFieldHasBackground, false)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 400)
                }

                ToolbarItem(placement: .navigation) {
                    entryButton
                }
            }


            if currentRoom != nil {
                ToolbarItem {
                    Button {
                        page.isUsersListShown.toggle()
                    } label: {
                        Label(String(localized: "Users"), systemImage: "sidebar.trailing")
                    }
                    .help(String(localized: "Users"))
                }
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
                SplitPane("ChatRooms.Activity", edge: .top, range: 48...400, idealLength: 80) {
                    tab.chatView.view
                } pane: {
                    tab.activityView.view
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

/// Users of a chat room, shown in the trailing pane of the chat rooms split view.
struct RoomUsersView: View {

    @Bindable var tab: ChatRoomTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(String(localized: "Users"), systemImage: "person.2")
                    .font(.headline)

                Spacer()

                Text(tab.userCountText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    tab.isRoomWallShown.toggle()
                } label: {
                    Label(String(localized: "Room Wall"), systemImage: "note.text")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Room Wall"))
                .popover(isPresented: $tab.isRoomWallShown) {
                    RoomWallView(roomWall: tab.roomWall)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: notebookTabBarHeight)
            .background(.bar)

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
