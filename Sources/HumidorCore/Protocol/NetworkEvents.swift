// SPDX-License-Identifier: GPL-3.0-or-later

/// A received network message that is delivered to the rest of the application
/// as an event.
protocol NetworkEventMessage: SlskMessage {
    static var event: EventName<Self> { get }
}

extension NetworkEventMessage {
    func emitMainThread() {
        events.emitMainThread(Self.event, self)
    }
}

extension SlskMessage {
    /// Emits the event associated with the message class, if any.
    func emitNetworkMessageEvent() {
        (self as? any NetworkEventMessage)?.emitMainThread()
    }
}

// MARK: - Event Names

public extension EventName where Payload == AdminMessage { static var adminMessage: Self { .init("admin-message") } }
public extension EventName where Payload == ChangePassword { static var changePassword: Self { .init("change-password") } }
public extension EventName where Payload == CheckPrivileges { static var checkPrivileges: Self { .init("check-privileges") } }
public extension EventName where Payload == ConnectToPeer { static var connectToPeer: Self { .init("connect-to-peer") } }
public extension EventName where Payload == DistribSearch {
    static var fileSearchRequestDistributed: Self { .init("file-search-request-distributed") }
}
public extension EventName where Payload == ExcludedSearchPhrases {
    static var excludedSearchPhrases: Self { .init("excluded-search-phrases") }
}
public extension EventName where Payload == FileSearch {
    static var fileSearchRequestServer: Self { .init("file-search-request-server") }
}
public extension EventName where Payload == FileSearchResponse {
    static var fileSearchResponse: Self { .init("file-search-response") }
}
public extension EventName where Payload == FileTransferInit { static var fileTransferInit: Self { .init("file-transfer-init") } }
public extension EventName where Payload == FolderContentsRequest {
    static var folderContentsRequest: Self { .init("folder-contents-request") }
}
public extension EventName where Payload == FolderContentsResponse {
    static var folderContentsResponse: Self { .init("folder-contents-response") }
}
public extension EventName where Payload == GetPeerAddress { static var peerAddress: Self { .init("peer-address") } }
public extension EventName where Payload == GetUserStats { static var userStats: Self { .init("user-stats") } }
public extension EventName where Payload == GetUserStatus { static var userStatus: Self { .init("user-status") } }
public extension EventName where Payload == GlobalRecommendations {
    static var globalRecommendations: Self { .init("global-recommendations") }
}
public extension EventName where Payload == GlobalRoomMessage { static var globalRoomMessage: Self { .init("global-room-message") } }
public extension EventName where Payload == ItemRecommendations {
    static var itemRecommendations: Self { .init("item-recommendations") }
}
public extension EventName where Payload == ItemSimilarUsers { static var itemSimilarUsers: Self { .init("item-similar-users") } }
public extension EventName where Payload == JoinRoom { static var joinRoom: Self { .init("join-room") } }
public extension EventName where Payload == LeaveRoom { static var leaveRoom: Self { .init("leave-room") } }
public extension EventName where Payload == Login { static var serverLogin: Self { .init("server-login") } }
public extension EventName where Payload == MessageUser { static var messageUser: Self { .init("message-user") } }
public extension EventName where Payload == PlaceInQueueRequest {
    static var placeInQueueRequest: Self { .init("place-in-queue-request") }
}
public extension EventName where Payload == PlaceInQueueResponse {
    static var placeInQueueResponse: Self { .init("place-in-queue-response") }
}
public extension EventName where Payload == PrivateRoomAddOperator {
    static var privateRoomAddOperator: Self { .init("private-room-add-operator") }
}
public extension EventName where Payload == PrivateRoomAddUser { static var privateRoomAddUser: Self { .init("private-room-add-user") } }
public extension EventName where Payload == PrivateRoomAdded { static var privateRoomAdded: Self { .init("private-room-added") } }
public extension EventName where Payload == PrivateRoomOperatorAdded {
    static var privateRoomOperatorAdded: Self { .init("private-room-operator-added") }
}
public extension EventName where Payload == PrivateRoomOperatorRemoved {
    static var privateRoomOperatorRemoved: Self { .init("private-room-operator-removed") }
}
public extension EventName where Payload == PrivateRoomOperators {
    static var privateRoomOperators: Self { .init("private-room-operators") }
}
public extension EventName where Payload == PrivateRoomRemoveOperator {
    static var privateRoomRemoveOperator: Self { .init("private-room-remove-operator") }
}
public extension EventName where Payload == PrivateRoomRemoveUser {
    static var privateRoomRemoveUser: Self { .init("private-room-remove-user") }
}
public extension EventName where Payload == PrivateRoomRemoved { static var privateRoomRemoved: Self { .init("private-room-removed") } }
public extension EventName where Payload == PrivateRoomToggle { static var privateRoomToggle: Self { .init("private-room-toggle") } }
public extension EventName where Payload == PrivateRoomUsers { static var privateRoomUsers: Self { .init("private-room-users") } }
public extension EventName where Payload == PrivilegedUsers { static var privilegedUsers: Self { .init("privileged-users") } }
public extension EventName where Payload == QueueUpload { static var queueUpload: Self { .init("queue-upload") } }
public extension EventName where Payload == Recommendations { static var recommendations: Self { .init("recommendations") } }
public extension EventName where Payload == RoomList { static var roomList: Self { .init("room-list") } }
public extension EventName where Payload == RoomTickerAdd { static var tickerAdd: Self { .init("ticker-add") } }
public extension EventName where Payload == RoomTickerRemove { static var tickerRemove: Self { .init("ticker-remove") } }
public extension EventName where Payload == RoomTickerState { static var tickerState: Self { .init("ticker-state") } }
public extension EventName where Payload == SayChatroom { static var sayChatRoom: Self { .init("say-chat-room") } }
public extension EventName where Payload == SharedFileListRequest {
    static var sharedFileListRequest: Self { .init("shared-file-list-request") }
}
public extension EventName where Payload == SharedFileListResponse {
    static var sharedFileListResponse: Self { .init("shared-file-list-response") }
}
public extension EventName where Payload == SimilarUsers { static var similarUsers: Self { .init("similar-users") } }
public extension EventName where Payload == TransferRequest { static var transferRequest: Self { .init("transfer-request") } }
public extension EventName where Payload == TransferResponse { static var transferResponse: Self { .init("transfer-response") } }
public extension EventName where Payload == UploadDenied { static var uploadDenied: Self { .init("upload-denied") } }
public extension EventName where Payload == UploadFailed { static var uploadFailed: Self { .init("upload-failed") } }
public extension EventName where Payload == UserInfoRequest { static var userInfoRequest: Self { .init("user-info-request") } }
public extension EventName where Payload == UserInfoResponse { static var userInfoResponse: Self { .init("user-info-response") } }
public extension EventName where Payload == UserInterests { static var userInterests: Self { .init("user-interests") } }
public extension EventName where Payload == UserJoinedRoom { static var userJoinedRoom: Self { .init("user-joined-room") } }
public extension EventName where Payload == UserLeftRoom { static var userLeftRoom: Self { .init("user-left-room") } }
public extension EventName where Payload == WatchUser { static var watchUser: Self { .init("watch-user") } }
public extension EventName where Payload == WishlistInterval { static var setWishlistInterval: Self { .init("set-wishlist-interval") } }

// MARK: - Message Events

extension AdminMessage: NetworkEventMessage { static var event: EventName<AdminMessage> { .adminMessage } }
extension ChangePassword: NetworkEventMessage { static var event: EventName<ChangePassword> { .changePassword } }
extension CheckPrivileges: NetworkEventMessage { static var event: EventName<CheckPrivileges> { .checkPrivileges } }
extension ConnectToPeer: NetworkEventMessage { static var event: EventName<ConnectToPeer> { .connectToPeer } }
extension DistribSearch: NetworkEventMessage {
    static var event: EventName<DistribSearch> { .fileSearchRequestDistributed }
}
extension ExcludedSearchPhrases: NetworkEventMessage {
    static var event: EventName<ExcludedSearchPhrases> { .excludedSearchPhrases }
}
extension FileSearch: NetworkEventMessage { static var event: EventName<FileSearch> { .fileSearchRequestServer } }
extension FileSearchResponse: NetworkEventMessage { static var event: EventName<FileSearchResponse> { .fileSearchResponse } }
extension FileTransferInit: NetworkEventMessage { static var event: EventName<FileTransferInit> { .fileTransferInit } }
extension FolderContentsRequest: NetworkEventMessage {
    static var event: EventName<FolderContentsRequest> { .folderContentsRequest }
}
extension FolderContentsResponse: NetworkEventMessage {
    static var event: EventName<FolderContentsResponse> { .folderContentsResponse }
}
extension GetPeerAddress: NetworkEventMessage { static var event: EventName<GetPeerAddress> { .peerAddress } }
extension GetUserStats: NetworkEventMessage { static var event: EventName<GetUserStats> { .userStats } }
extension GetUserStatus: NetworkEventMessage { static var event: EventName<GetUserStatus> { .userStatus } }
extension GlobalRecommendations: NetworkEventMessage {
    static var event: EventName<GlobalRecommendations> { .globalRecommendations }
}
extension GlobalRoomMessage: NetworkEventMessage { static var event: EventName<GlobalRoomMessage> { .globalRoomMessage } }
extension ItemRecommendations: NetworkEventMessage { static var event: EventName<ItemRecommendations> { .itemRecommendations } }
extension ItemSimilarUsers: NetworkEventMessage { static var event: EventName<ItemSimilarUsers> { .itemSimilarUsers } }
extension JoinRoom: NetworkEventMessage { static var event: EventName<JoinRoom> { .joinRoom } }
extension LeaveRoom: NetworkEventMessage { static var event: EventName<LeaveRoom> { .leaveRoom } }
extension Login: NetworkEventMessage { static var event: EventName<Login> { .serverLogin } }
extension MessageUser: NetworkEventMessage { static var event: EventName<MessageUser> { .messageUser } }
extension PlaceInQueueRequest: NetworkEventMessage { static var event: EventName<PlaceInQueueRequest> { .placeInQueueRequest } }
extension PlaceInQueueResponse: NetworkEventMessage {
    static var event: EventName<PlaceInQueueResponse> { .placeInQueueResponse }
}
extension PrivateRoomAddOperator: NetworkEventMessage {
    static var event: EventName<PrivateRoomAddOperator> { .privateRoomAddOperator }
}
extension PrivateRoomAddUser: NetworkEventMessage { static var event: EventName<PrivateRoomAddUser> { .privateRoomAddUser } }
extension PrivateRoomAdded: NetworkEventMessage { static var event: EventName<PrivateRoomAdded> { .privateRoomAdded } }
extension PrivateRoomOperatorAdded: NetworkEventMessage {
    static var event: EventName<PrivateRoomOperatorAdded> { .privateRoomOperatorAdded }
}
extension PrivateRoomOperatorRemoved: NetworkEventMessage {
    static var event: EventName<PrivateRoomOperatorRemoved> { .privateRoomOperatorRemoved }
}
extension PrivateRoomOperators: NetworkEventMessage {
    static var event: EventName<PrivateRoomOperators> { .privateRoomOperators }
}
extension PrivateRoomRemoveOperator: NetworkEventMessage {
    static var event: EventName<PrivateRoomRemoveOperator> { .privateRoomRemoveOperator }
}
extension PrivateRoomRemoveUser: NetworkEventMessage {
    static var event: EventName<PrivateRoomRemoveUser> { .privateRoomRemoveUser }
}
extension PrivateRoomRemoved: NetworkEventMessage { static var event: EventName<PrivateRoomRemoved> { .privateRoomRemoved } }
extension PrivateRoomToggle: NetworkEventMessage { static var event: EventName<PrivateRoomToggle> { .privateRoomToggle } }
extension PrivateRoomUsers: NetworkEventMessage { static var event: EventName<PrivateRoomUsers> { .privateRoomUsers } }
extension PrivilegedUsers: NetworkEventMessage { static var event: EventName<PrivilegedUsers> { .privilegedUsers } }
extension QueueUpload: NetworkEventMessage { static var event: EventName<QueueUpload> { .queueUpload } }
extension Recommendations: NetworkEventMessage { static var event: EventName<Recommendations> { .recommendations } }
extension RoomList: NetworkEventMessage { static var event: EventName<RoomList> { .roomList } }
extension RoomTickerAdd: NetworkEventMessage { static var event: EventName<RoomTickerAdd> { .tickerAdd } }
extension RoomTickerRemove: NetworkEventMessage { static var event: EventName<RoomTickerRemove> { .tickerRemove } }
extension RoomTickerState: NetworkEventMessage { static var event: EventName<RoomTickerState> { .tickerState } }
extension SayChatroom: NetworkEventMessage { static var event: EventName<SayChatroom> { .sayChatRoom } }
extension SharedFileListRequest: NetworkEventMessage {
    static var event: EventName<SharedFileListRequest> { .sharedFileListRequest }
}
extension SharedFileListResponse: NetworkEventMessage {
    static var event: EventName<SharedFileListResponse> { .sharedFileListResponse }
}
extension SimilarUsers: NetworkEventMessage { static var event: EventName<SimilarUsers> { .similarUsers } }
extension TransferRequest: NetworkEventMessage { static var event: EventName<TransferRequest> { .transferRequest } }
extension TransferResponse: NetworkEventMessage { static var event: EventName<TransferResponse> { .transferResponse } }
extension UploadDenied: NetworkEventMessage { static var event: EventName<UploadDenied> { .uploadDenied } }
extension UploadFailed: NetworkEventMessage { static var event: EventName<UploadFailed> { .uploadFailed } }
extension UserInfoRequest: NetworkEventMessage { static var event: EventName<UserInfoRequest> { .userInfoRequest } }
extension UserInfoResponse: NetworkEventMessage { static var event: EventName<UserInfoResponse> { .userInfoResponse } }
extension UserInterests: NetworkEventMessage { static var event: EventName<UserInterests> { .userInterests } }
extension UserJoinedRoom: NetworkEventMessage { static var event: EventName<UserJoinedRoom> { .userJoinedRoom } }
extension UserLeftRoom: NetworkEventMessage { static var event: EventName<UserLeftRoom> { .userLeftRoom } }
extension WatchUser: NetworkEventMessage { static var event: EventName<WatchUser> { .watchUser } }
extension WishlistInterval: NetworkEventMessage { static var event: EventName<WishlistInterval> { .setWishlistInterval } }
