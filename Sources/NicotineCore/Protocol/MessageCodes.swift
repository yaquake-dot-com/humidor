// SPDX-License-Identifier: GPL-3.0-or-later

/// Bidirectional mapping between message classes and protocol codes.
struct MessageCodeTable: Sendable {
    private let codes: [ObjectIdentifier: Int]
    private let classes: [Int: SlskMessage.Type]

    init(_ entries: [(SlskMessage.Type, Int)]) {
        var codes: [ObjectIdentifier: Int] = [:]
        var classes: [Int: SlskMessage.Type] = [:]

        for (messageClass, code) in entries {
            codes[ObjectIdentifier(messageClass)] = code
            classes[code] = messageClass
        }

        self.codes = codes
        self.classes = classes
    }

    func code(for message: SlskMessage) -> Int? {
        codes[ObjectIdentifier(type(of: message))]
    }

    func messageClass(for code: Int) -> SlskMessage.Type? {
        classes[code]
    }
}

enum MessageCodes {

    static let server = MessageCodeTable([
        (Login.self, 1),
        (SetWaitPort.self, 2),
        (GetPeerAddress.self, 3),
        (WatchUser.self, 5),
        (UnwatchUser.self, 6),
        (GetUserStatus.self, 7),
        (IgnoreUser.self, 11),
        (UnignoreUser.self, 12),
        (SayChatroom.self, 13),
        (JoinRoom.self, 14),
        (LeaveRoom.self, 15),
        (UserJoinedRoom.self, 16),
        (UserLeftRoom.self, 17),
        (ConnectToPeer.self, 18),
        (MessageUser.self, 22),
        (MessageAcked.self, 23),
        (FileSearchRoom.self, 25),           // Obsolete
        (FileSearch.self, 26),
        (SetStatus.self, 28),
        (ServerPing.self, 32),
        (SendConnectToken.self, 33),         // Obsolete
        (SendDownloadSpeed.self, 34),        // Obsolete
        (SharedFoldersFiles.self, 35),
        (GetUserStats.self, 36),
        (QueuedDownloads.self, 40),          // Obsolete
        (Relogged.self, 41),
        (UserSearch.self, 42),
        (SimilarRecommendations.self, 50),   // Obsolete
        (AddThingILike.self, 51),            // Deprecated
        (RemoveThingILike.self, 52),         // Deprecated
        (Recommendations.self, 54),          // Deprecated
        (MyRecommendations.self, 55),        // Obsolete
        (GlobalRecommendations.self, 56),    // Deprecated
        (UserInterests.self, 57),            // Deprecated
        (AdminCommand.self, 58),             // Obsolete
        (PlaceInLineResponse.self, 60),      // Obsolete
        (RoomAdded.self, 62),                // Obsolete
        (RoomRemoved.self, 63),              // Obsolete
        (RoomList.self, 64),
        (ExactFileSearch.self, 65),          // Obsolete
        (AdminMessage.self, 66),
        (GlobalUserList.self, 67),           // Obsolete
        (TunneledMessage.self, 68),          // Obsolete
        (PrivilegedUsers.self, 69),
        (HaveNoParent.self, 71),
        (SearchParent.self, 73),             // Deprecated
        (ParentMinSpeed.self, 83),
        (ParentSpeedRatio.self, 84),
        (ParentInactivityTimeout.self, 86),  // Obsolete
        (SearchInactivityTimeout.self, 87),  // Obsolete
        (MinParentsInCache.self, 88),        // Obsolete
        (DistribPingInterval.self, 90),      // Obsolete
        (AddToPrivileged.self, 91),          // Obsolete
        (CheckPrivileges.self, 92),
        (EmbeddedMessage.self, 93),
        (AcceptChildren.self, 100),
        (PossibleParents.self, 102),
        (WishlistSearch.self, 103),
        (WishlistInterval.self, 104),
        (SimilarUsers.self, 110),            // Deprecated
        (ItemRecommendations.self, 111),     // Deprecated
        (ItemSimilarUsers.self, 112),        // Deprecated
        (RoomTickerState.self, 113),
        (RoomTickerAdd.self, 114),
        (RoomTickerRemove.self, 115),
        (RoomTickerSet.self, 116),
        (AddThingIHate.self, 117),           // Deprecated
        (RemoveThingIHate.self, 118),        // Deprecated
        (RoomSearch.self, 120),
        (SendUploadSpeed.self, 121),
        (UserPrivileged.self, 122),          // Deprecated
        (GivePrivileges.self, 123),
        (NotifyPrivileges.self, 124),        // Deprecated
        (AckNotifyPrivileges.self, 125),     // Deprecated
        (BranchLevel.self, 126),
        (BranchRoot.self, 127),
        (ChildDepth.self, 129),              // Deprecated
        (ResetDistributed.self, 130),
        (PrivateRoomUsers.self, 133),
        (PrivateRoomAddUser.self, 134),
        (PrivateRoomRemoveUser.self, 135),
        (PrivateRoomCancelMembership.self, 136),
        (PrivateRoomDisown.self, 137),
        (PrivateRoomSomething.self, 138),    // Obsolete
        (PrivateRoomAdded.self, 139),
        (PrivateRoomRemoved.self, 140),
        (PrivateRoomToggle.self, 141),
        (ChangePassword.self, 142),
        (PrivateRoomAddOperator.self, 143),
        (PrivateRoomRemoveOperator.self, 144),
        (PrivateRoomOperatorAdded.self, 145),
        (PrivateRoomOperatorRemoved.self, 146),
        (PrivateRoomOperators.self, 148),
        (MessageUsers.self, 149),
        (JoinGlobalRoom.self, 150),          // Deprecated
        (LeaveGlobalRoom.self, 151),         // Deprecated
        (GlobalRoomMessage.self, 152),       // Deprecated
        (RelatedSearch.self, 153),           // Obsolete
        (ExcludedSearchPhrases.self, 160),
        (CantConnectToPeer.self, 1001),
        (CantCreateRoom.self, 1003)
    ])

    static let peerInit = MessageCodeTable([
        (PierceFireWall.self, 0),
        (PeerInit.self, 1)
    ])

    static let peer = MessageCodeTable([
        (SharedFileListRequest.self, 4),
        (SharedFileListResponse.self, 5),
        (FileSearchRequest.self, 8),         // Obsolete
        (FileSearchResponse.self, 9),
        (UserInfoRequest.self, 15),
        (UserInfoResponse.self, 16),
        (PMessageUser.self, 22),             // Obsolete
        (FolderContentsRequest.self, 36),
        (FolderContentsResponse.self, 37),
        (TransferRequest.self, 40),
        (TransferResponse.self, 41),
        (PlaceholdUpload.self, 42),          // Obsolete
        (QueueUpload.self, 43),
        (PlaceInQueueResponse.self, 44),
        (UploadFailed.self, 46),
        (UploadDenied.self, 50),
        (PlaceInQueueRequest.self, 51),
        (UploadQueueNotification.self, 52),  // Deprecated
        (UnknownPeerMessage.self, 12547)
    ])

    static let distributed = MessageCodeTable([
        (DistribPing.self, 0),               // Deprecated
        (DistribSearch.self, 3),
        (DistribBranchLevel.self, 4),
        (DistribBranchRoot.self, 5),
        (DistribChildDepth.self, 7),         // Deprecated
        (DistribEmbeddedMessage.self, 93)
    ])
}
