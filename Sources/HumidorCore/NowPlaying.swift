// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Retrieves information about the song currently playing in a media player.
@MainActor
public final class NowPlaying {

    public private(set) var title: [String: String] = [:]

    init() {
        titleClear()
    }

    private func titleClear() {
        title = [
            "title": "",
            "artist": "",
            "comment": "",
            "year": "",
            "album": "",
            "track": "",
            "length": "",
            "nowplaying": "",
            "bitrate": "",
            "filename": "",
            "program": ""
        ]
    }

    /// Returns the formatted title of the song currently playing, if any.
    public func nowPlaying(player: String? = nil, command: String? = nil, format: String? = nil) async -> String? {
        titleClear()

        var player = player ?? config.players.npPlayer

        if player == "mpris" {
            // MPRIS is not available on Apple platforms
            player = "lastfm"
        }

        let command = command ?? config.players.npOtherCommand
        var result = false

        switch player {
        case "lastfm":
            result = await lastFM(command)
        case "listenbrainz":
            result = await listenBrainz(command)
        case "other":
            result = other(command)
        default:
            result = false
        }

        guard result else {
            return nil
        }

        var formatted = format ?? config.players.npFormat

        for (placeholder, key) in [
            ("$t", "title"), ("$a", "artist"), ("$b", "album"), ("$c", "comment"), ("$n", "nowplaying"),
            ("$k", "track"), ("$l", "length"), ("$y", "year"), ("$r", "bitrate"), ("$f", "filename"),
            ("$p", "program")
        ] {
            formatted = formatted.replacingOccurrences(of: placeholder, with: title[key] ?? "")
        }

        formatted = formatted.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")

        return formatted.isEmpty ? nil : formatted
    }

    private static func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"

        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private var errorTitle: String {
        String(localized: "Now Playing Error", bundle: .module)
    }

    /// Gets the last song played via the Last.fm API.
    private func lastFM(_ credentials: String) async -> Bool {
        let parts = credentials.split(separator: ";", omittingEmptySubsequences: false).map(String.init)

        guard parts.count == 2 else {
            log.add(String(localized: "Last.fm: Please provide both your Last.fm username and API key", bundle: .module),
                    title: errorTitle)
            return false
        }

        let (username, apiKey) = (parts[0], parts[1])
        let responseBody: Data

        do {
            let query = "method=user.getrecenttracks&user=\(username)&api_key=\(apiKey)&limit=1&format=json"
            responseBody = try await Self.fetch("https://ws.audioscrobbler.com/2.0/?"
                                                + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query))
        } catch {
            log.add(String(localized: "Last.fm: Could not connect to Audioscrobbler: \(error.localizedDescription)",
                           bundle: .module), title: errorTitle)
            return false
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
                  let recentTracks = json["recenttracks"] as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            // In most cases, a list containing a single track dictionary is sent. On rare
            // occasions, the track dictionary is not wrapped in a list.
            let lastPlayed = (recentTracks["track"] as? [[String: Any]])?.first ?? recentTracks["track"] as? [String: Any]

            guard let lastPlayed,
                  let artist = (lastPlayed["artist"] as? [String: Any])?["#text"] as? String,
                  let trackTitle = lastPlayed["name"] as? String else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            title["artist"] = artist
            title["title"] = trackTitle
            title["album"] = (lastPlayed["album"] as? [String: Any])?["#text"] as? String ?? ""
            title["nowplaying"] = "\(artist) - \(trackTitle)"

        } catch {
            log.add(String(localized: "Last.fm: Could not get recent track from Audioscrobbler: \(error.localizedDescription)",
                           bundle: .module), title: errorTitle)
            return false
        }

        return true
    }

    /// Gets the currently playing song via the ListenBrainz API.
    private func listenBrainz(_ username: String) async -> Bool {
        guard !username.isEmpty else {
            log.add(String(localized: "ListenBrainz: Please provide your ListenBrainz username", bundle: .module),
                    title: errorTitle)
            return false
        }

        let responseBody: Data

        do {
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
            responseBody = try await Self.fetch("https://api.listenbrainz.org/1/user/\(encodedUsername)/playing-now")
        } catch {
            log.add(String(localized: "ListenBrainz: Could not connect to ListenBrainz: \(error.localizedDescription)",
                           bundle: .module), title: errorTitle)
            return false
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            guard (payload["playing_now"] as? Bool) == true else {
                log.add(String(localized: "ListenBrainz: You don't seem to be listening to anything right now",
                               bundle: .module), title: errorTitle)
                return false
            }

            guard let listens = payload["listens"] as? [[String: Any]],
                  let track = listens.first?["track_metadata"] as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            let artist = track["artist_name"] as? String ?? "?"
            let trackTitle = track["track_name"] as? String ?? "?"

            title["artist"] = artist
            title["title"] = trackTitle
            title["album"] = track["release_name"] as? String ?? "?"
            title["nowplaying"] = "\(artist) - \(trackTitle)"

            return true

        } catch {
            log.add(String(localized: "ListenBrainz: Could not get current track from ListenBrainz: \(error.localizedDescription)",
                           bundle: .module), title: errorTitle)
        }

        return false
    }

    private func other(_ command: String) -> Bool {
        guard !command.isEmpty else {
            return false
        }

        do {
            let output = try executeCommand(command, returnOutput: true) ?? Data()
            title["nowplaying"] = String(decoding: output, as: UTF8.self)
            return true

        } catch {
            log.add(String(localized: "Executing '\(command)' failed: \(error.localizedDescription)", bundle: .module),
                    title: errorTitle)
            return false
        }
    }
}
