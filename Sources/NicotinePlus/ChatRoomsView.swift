// SPDX-License-Identifier: GPL-3.0-or-later

import NicotineCore
import SwiftUI

/// Chat rooms page.
struct ChatRoomsView: View {

    @Bindable var page: ChatRoomsPage

    var body: some View {
        HSplitView {
            Group {
                if page.notebook.pages.isEmpty {
                    PageDescription(
                        systemImage: "bubble.left.and.bubble.right",
                        title: String(localized: "Chat Rooms"),
                        description: String(localized: "Join an existing chat room, or create a new room to chat with other users on the Soulseek network")
                    )
                } else {
                    NotebookView(notebook: page.notebook)
                }
            }
            .frame(minWidth: 400)
            .layoutPriority(1)

            if config.ui.buddyListInChatrooms == "chatrooms" {
                page.window.buddies.content
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    ComboBox(placeholder: String(localized: "Join or create room…"), text: $page.roomText,
                             items: page.roomList.roomNames, focusRequest: page.roomFocusRequest,
                             onSubmit: { page.onCreateRoom() }, onSelectItem: { page.onCreateRoom() })
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 400)
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

            ToolbarItem {
                Button {
                    Application.shared.onConfigureChats()
                } label: {
                    Label(String(localized: "Configure Chats"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Chats"))
            }
        }
    }
}

/// A single chat room: activity log, chat messages and room users.
struct ChatRoomTabView: View {

    @Bindable var tab: ChatRoomTab

    var body: some View {
        HSplitView {
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
            .frame(minWidth: 300)
            .layoutPriority(1)

            if !tab.isGlobal {
                usersList
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 400)
            }
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

    private var usersList: some View {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

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

            roomList.listView.view
                .border(Color(nsColor: .separatorColor))

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
                .border(Color(nsColor: .separatorColor))
        }
        .padding()
        .frame(width: 650, height: 500)
        .onAppear {
            roomWall.onShow()
        }
    }
}
