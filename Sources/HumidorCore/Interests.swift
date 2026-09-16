// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension EventName where Payload == String {
    static var addInterest: Self { .init("add-interest") }
    static var addDislike: Self { .init("add-dislike") }
    static var removeInterest: Self { .init("remove-interest") }
    static var removeDislike: Self { .init("remove-dislike") }
}

public struct SimilarUser {
    public let username: String
    public let rating: Int?
}

@MainActor
public final class Interests {

    public private(set) var similarUsers = OrderedDictionary<String, SimilarUser>()

    init() {
        events.connect(.itemSimilarUsers) { [self] msg in
            updateSimilarUsers(msg.users.map { ($0, nil) })
        }
        events.connect(.quit) { [self] in similarUsers.removeAll() }
        events.connect(.serverLogin) { msg in Self.serverLogin(msg) }
        events.connect(.similarUsers) { [self] msg in
            updateSimilarUsers(msg.users.map { ($0.key, $0.value) })
        }
    }

    private static func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for item in config.interests.likes {
            let item = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if !item.isEmpty {
                core.sendMessageToServer(AddThingILike(thing: item))
            }
        }

        for item in config.interests.dislikes {
            let item = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if !item.isEmpty {
                core.sendMessageToServer(AddThingIHate(thing: item))
            }
        }
    }

    public func addThingILike(_ item: String) {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !item.isEmpty, !config.interests.likes.contains(item) else {
            return
        }

        config.interests.likes.append(item)
        config.writeConfiguration()
        core.sendMessageToServer(AddThingILike(thing: item))

        events.emit(.addInterest, item)
    }

    public func addThingIHate(_ item: String) {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !item.isEmpty, !config.interests.dislikes.contains(item) else {
            return
        }

        config.interests.dislikes.append(item)
        config.writeConfiguration()
        core.sendMessageToServer(AddThingIHate(thing: item))

        events.emit(.addDislike, item)
    }

    public func removeThingILike(_ item: String) {
        guard config.interests.likes.contains(item) else {
            return
        }

        config.interests.likes.removeAll { $0 == item }
        config.writeConfiguration()
        core.sendMessageToServer(RemoveThingILike(thing: item))

        events.emit(.removeInterest, item)
    }

    public func removeThingIHate(_ item: String) {
        guard config.interests.dislikes.contains(item) else {
            return
        }

        config.interests.dislikes.removeAll { $0 == item }
        config.writeConfiguration()
        core.sendMessageToServer(RemoveThingIHate(thing: item))

        events.emit(.removeDislike, item)
    }

    public func requestGlobalRecommendations() {
        core.sendMessageToServer(GlobalRecommendations())
    }

    public func requestItemRecommendations(_ item: String) {
        core.sendMessageToServer(ItemRecommendations(thing: item))
    }

    public func requestItemSimilarUsers(_ item: String) {
        core.sendMessageToServer(ItemSimilarUsers(thing: item))
    }

    public func requestRecommendations() {
        core.sendMessageToServer(Recommendations())
    }

    public func requestSimilarUsers() {
        core.sendMessageToServer(SimilarUsers())
    }

    /// Server codes 110 and 112.
    private func updateSimilarUsers(_ users: [(username: String, rating: Int?)]) {
        let newUsers = Set(users.map(\.username))

        // Unwatch and remove old users
        for username in similarUsers.keys where !newUsers.contains(username) {
            core.users.unwatchUser(username, context: "interests")
        }

        similarUsers.removeAll()

        // Add new users
        for (username, rating) in users {
            similarUsers[username] = SimilarUser(username: username, rating: rating)

            // Request user status, speed and number of shared files
            core.users.watchUser(username, context: "interests")
        }
    }
}
