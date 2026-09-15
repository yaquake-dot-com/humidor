// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum FileTypes {
    public static let archive: Set<String> = [
        "7z", "br", "bz2", "gz", "iso", "lz", "lzma", "rar", "tar", "tbz", "tbz2", "tgz", "xz", "zip", "zst"
    ]
    public static let audio: Set<String> = [
        "aac", "ac3", "afc", "aifc", "aif", "aiff", "ape", "au", "bwav", "bwf", "dff", "dsd", "dsf", "dts", "flac",
        "gbs", "gym", "it", "m4a", "m4b", "mid", "midi", "mka", "mod", "mp1", "mp2", "mp3", "mp+", "mpc", "nsf", "nsfe",
        "ofr", "ofs", "oga", "ogg", "opus", "psf", "psf1", "psf2", "s3m", "sid", "spc", "spx", "ssf", "tak", "tta",
        "wav", "vgm", "vgz", "wma", "vqf", "wv", "xm"
    ]
    public static let executable: Set<String> = [
        "apk", "appimage", "bat", "deb", "dmg", "flatpak", "exe", "jar", "msi", "pkg", "rpm", "sh"
    ]
    public static let image: Set<String> = [
        "apng", "avif", "bmp", "gif", "heic", "heif", "ico", "jfif", "jp2", "jpg", "jpe", "jpeg", "jxl", "png", "psd",
        "raw", "svg", "svgz", "tif", "tiff", "webp"
    ]
    public static let document: Set<String> = [
        "doc", "docx", "epub", "mobi", "odp", "ods", "odt", "opf", "oxps", "pdf", "ppt", "pptx", "rtf", "xls", "xlsx",
        "xps"
    ]
    public static let text: Set<String> = [
        "cue", "csv", "htm", "html", "m3u", "m3u8", "md5", "log", "lrc", "md", "mks", "nfo", "ps", "rst", "sfv",
        "sha1", "sha256", "srt", "txt"
    ]
    public static let video: Set<String> = [
        "3gp", "amv", "asf", "avi", "f4v", "flv", "m2ts", "m2v", "m4p", "m4v", "mov", "mp4", "mpe", "mpeg", "mpg",
        "mkv", "mts", "ogv", "ts", "vob", "webm", "wmv"
    ]
}

public extension EventName where Payload == Void {
    static var sharesPreparing: Self { .init("shares-preparing") }
}

public extension EventName where Payload == Int? {
    /// Emitted while scanning, with the number of folders scanned so far.
    static var sharesScanning: Self { .init("shares-scanning") }
}

public extension EventName where Payload == Bool {
    static var sharesReady: Self { .init("shares-ready") }
}

public extension EventName where Payload == [SharedFolder] {
    static var sharesUnavailable: Self { .init("shares-unavailable") }
}

/// Splits a path into lowercase words, treating punctuation as whitespace.
func shareWords(_ text: String) -> Set<String> {
    let cleaned = String(text.lowercased().map { Character.punctuation.contains($0) ? " " : $0 })
    return Set(cleaned.split(whereSeparator: \.isWhitespace).map(String.init))
}

// MARK: - Share Databases

/// Names of the share databases.
enum ShareDatabaseName: String, CaseIterable, Sendable {
    case words
    case publicFiles = "publicfiles"
    case publicMtimes = "publicmtimes"
    case publicStreams = "publicstreams"
    case buddyFiles = "buddyfiles"
    case buddyMtimes = "buddymtimes"
    case buddyStreams = "buddystreams"
    case trustedFiles = "trustedfiles"
    case trustedMtimes = "trustedmtimes"
    case trustedStreams = "trustedstreams"

    static func files(_ level: PermissionLevel) -> Self {
        switch level {
        case .buddy: return .buddyFiles
        case .trusted: return .trustedFiles
        default: return .publicFiles
        }
    }

    static func mtimes(_ level: PermissionLevel) -> Self {
        switch level {
        case .buddy: return .buddyMtimes
        case .trusted: return .trustedMtimes
        default: return .publicMtimes
        }
    }

    static func streams(_ level: PermissionLevel) -> Self {
        switch level {
        case .buddy: return .buddyStreams
        case .trusted: return .trustedStreams
        default: return .publicStreams
        }
    }
}

/// Open share databases, grouped by value type.
final class ShareDatabases: @unchecked Sendable {
    var words: ShareDatabase<[Int]>?
    var files: [PermissionLevel: ShareDatabase<SharedFileInfo>] = [:]
    var mtimes: [PermissionLevel: ShareDatabase<Double>] = [:]
    var streams: [PermissionLevel: ShareDatabase<Data>] = [:]

    static let scannedLevels: [PermissionLevel] = [.public, .buddy, .trusted]

    static func path(_ name: ShareDatabaseName, dataFolderPath: String) -> String {
        (dataFolderPath as NSString).appendingPathComponent("\(name.rawValue).dbn")
    }

    /// Opens databases for reading.
    func load(_ names: Set<ShareDatabaseName>, dataFolderPath: String) throws {
        var failure: Error?

        func open<Value>(_ name: ShareDatabaseName) -> ShareDatabase<Value>? {
            let path = Self.path(name, dataFolderPath: dataFolderPath)

            do {
                return try ShareDatabase<Value>(filePath: path, overwrite: false)
            } catch {
                failure = error
                Shares.removeDBFile(path)
                return nil
            }
        }

        for name in names {
            switch name {
            case .words:
                words = open(name)
            case .publicFiles, .buddyFiles, .trustedFiles:
                let level = Self.scannedLevels.first { ShareDatabaseName.files($0) == name }!
                files[level] = open(name)
            case .publicMtimes, .buddyMtimes, .trustedMtimes:
                let level = Self.scannedLevels.first { ShareDatabaseName.mtimes($0) == name }!
                mtimes[level] = open(name)
            case .publicStreams, .buddyStreams, .trustedStreams:
                let level = Self.scannedLevels.first { ShareDatabaseName.streams($0) == name }!
                streams[level] = open(name)
            }
        }

        if let failure {
            close()
            throw failure
        }
    }

    func close() {
        words?.close()
        words = nil

        for database in files.values { database.close() }
        for database in mtimes.values { database.close() }
        for database in streams.values { database.close() }

        files.removeAll()
        mtimes.removeAll()
        streams.removeAll()
    }
}

// MARK: - Scanner

enum ScannerState: Sendable {
    case initialized
    case rescanning
    case failure
}

/// Items sent from the scanner to the rest of the application.
enum ScannerItem: @unchecked Sendable {
    case state(ScannerState)
    case folderCount(Int)
    case logMessage(String)
    case filePathIndex([String])
    case compressedShares(SharedFileListResponse)
}

/// Responsible for building shares, running on a background thread.
///
/// It handles scanning of folders and files, as well as building databases and
/// writing them to disk.
final class Scanner: @unchecked Sendable {

    static let hiddenFolderNames: Set<String> = ["@eaDir", "#recycle", "#snapshot"]

    private let emit: (ScannerItem) -> Void
    private let shareGroups: [[SharedFolder]]
    private let dataFolderPath: String
    private let shareDBs = ShareDatabases()
    private let initializing: Bool
    private var rescan: Bool
    private var rebuild: Bool
    private let revealBuddyShares: Bool
    private let revealTrustedShares: Bool

    private var files: [(String, SharedFileInfo)] = []
    private var streams: [String: Data] = [:]
    private var streamOrder: [String] = []
    private var mtimes: [(String, Double)] = []
    private var wordIndex: [String: [Int]] = [:]
    private var processedShareNames = Set<String>()
    private var processedSharePaths = Set<String>()
    private var currentFileIndex = 0
    private var currentFolderCount = 0

    init(emit: @escaping (ScannerItem) -> Void, shareGroups: [[SharedFolder]], dataFolderPath: String,
         initializing: Bool = false, rescan: Bool = true, rebuild: Bool = false,
         revealBuddyShares: Bool = false, revealTrustedShares: Bool = false) {
        self.emit = emit
        self.shareGroups = shareGroups
        self.dataFolderPath = dataFolderPath
        self.initializing = initializing
        self.rescan = rescan
        self.rebuild = rebuild
        self.revealBuddyShares = revealBuddyShares
        self.revealTrustedShares = revealTrustedShares
    }

    func run() {
        defer { shareDBs.close() }

        do {
            if initializing {
                do {
                    try createCompressedShares()
                    try createFilePathIndex()
                } catch {
                    // Failed to load shares or version is invalid, rebuild
                    rescan = true
                    rebuild = true
                }

                emit(.state(.initialized))
            }

            guard rescan else {
                return
            }

            emit(.state(.rescanning))
            emit(.logMessage(rebuild
                             ? String(localized: "Rebuilding shares…", bundle: .module)
                             : String(localized: "Rescanning shares…", bundle: .module)))

            // Clear previous word index to prevent inconsistent state if the scanner fails
            try setWordIndex([:])

            // Scan shares
            for permissionLevel in ShareDatabases.scannedLevels {
                try rescanFolders(permissionLevel)
            }

            try setWordIndex(wordIndex)
            wordIndex.removeAll()

            try createCompressedShares()
            try createFilePathIndex()

            emit(.logMessage(String(localized: "Rescan complete: \(currentFolderCount) folders found",
                                    bundle: .module)))

        } catch {
            let folderPath = dataFolderPath
            emit(.logMessage(String(localized: "Serious error occurred while rescanning shares. If this problem persists, delete \(folderPath)/*.dbn and try again. If that doesn't help, please file a bug report with this stack trace included: \("\n" + String(describing: error))",
                                    bundle: .module)))
            emit(.state(.failure))
        }
    }

    /// Creates a message that will later contain a compressed list of our shares.
    private func createCompressedSharesMessage(_ permissionLevel: PermissionLevel) throws {
        func packed(_ level: PermissionLevel) -> PackedShares? {
            guard let database = shareDBs.streams[level] else {
                return nil
            }

            var shares: PackedShares = [:]
            for key in database.keys {
                shares[key] = database[key]
            }
            return shares
        }

        let publicStreams = packed(.public)
        var buddyStreams = packed(.buddy)
        var trustedStreams = packed(.trusted)

        if permissionLevel == .public && !revealBuddyShares {
            buddyStreams = nil
        }

        if (permissionLevel == .public || permissionLevel == .buddy) && !revealTrustedShares {
            trustedStreams = nil
        }

        let compressedShares = SharedFileListResponse(
            publicShares: publicStreams, buddyShares: buddyStreams, trustedShares: trustedStreams,
            permissionLevel: permissionLevel
        )
        _ = try compressedShares.makeNetworkMessage()
        compressedShares.publicShares = nil
        compressedShares.buddyShares = nil
        compressedShares.trustedShares = nil

        emit(.compressedShares(compressedShares))
    }

    private func createCompressedShares() throws {
        try shareDBs.load(Set(ShareDatabases.scannedLevels.map(ShareDatabaseName.streams)), dataFolderPath: dataFolderPath)

        for permissionLevel in ShareDatabases.scannedLevels {
            try createCompressedSharesMessage(permissionLevel)
        }

        shareDBs.close()
    }

    private func createFilePathIndex() throws {
        try shareDBs.load(Set(ShareDatabases.scannedLevels.map(ShareDatabaseName.files)), dataFolderPath: dataFolderPath)

        let filePathIndex = ShareDatabases.scannedLevels.flatMap { shareDBs.files[$0]?.keys ?? [] }
        emit(.filePathIndex(filePathIndex))

        shareDBs.close()
    }

    private func realToVirtual(_ realPath: String) throws -> String {
        let realPath = realPath.replacingOccurrences(of: "/", with: "\\")

        for sharedFolders in shareGroups {
            for sharedFolder in sharedFolders {
                var folderPath = sharedFolder.path.replacingOccurrences(of: "/", with: "\\")

                if realPath == folderPath {
                    return sharedFolder.virtualName
                }

                // Remove trailing separator from root folders
                while folderPath.hasSuffix("\\") {
                    folderPath.removeLast()
                }
                folderPath += "\\"

                if realPath.hasPrefix(folderPath) {
                    let realPathNoPrefix = realPath.dropFirst(folderPath.count)
                    return "\(sharedFolder.virtualName)\\\(realPathNoPrefix)"
                }
            }
        }

        throw ShareDatabaseError(message: "Cannot find virtual path for \(realPath)")
    }

    private func setWordIndex(_ wordIndex: [String: [Int]]) throws {
        let database = try Shares.createDBFile(ShareDatabases.path(.words, dataFolderPath: dataFolderPath))
            as ShareDatabase<[Int]>
        defer { database.close() }

        try database.update(wordIndex.map { ($0.key, $0.value) })
    }

    private func setShares(_ permissionLevel: PermissionLevel) throws {
        let filesDB = try Shares.createDBFile(
            ShareDatabases.path(.files(permissionLevel), dataFolderPath: dataFolderPath)) as ShareDatabase<SharedFileInfo>
        defer { filesDB.close() }
        try filesDB.update(files)

        let streamsDB = try Shares.createDBFile(
            ShareDatabases.path(.streams(permissionLevel), dataFolderPath: dataFolderPath)) as ShareDatabase<Data>
        defer { streamsDB.close() }
        try streamsDB.update(streamOrder.map { ($0, streams[$0]!) })

        let mtimesDB = try Shares.createDBFile(
            ShareDatabases.path(.mtimes(permissionLevel), dataFolderPath: dataFolderPath)) as ShareDatabase<Double>
        defer { mtimesDB.close() }
        try mtimesDB.update(mtimes)
    }

    private func rescanFolders(_ permissionLevel: PermissionLevel) throws {
        let sharedPublicFolders = shareGroups[0]
        let sharedBuddyFolders = shareGroups[1]
        let sharedTrustedFolders = shareGroups[2]
        let sharedFolders: [SharedFolder]

        switch permissionLevel {
        case .trusted: sharedFolders = sharedTrustedFolders
        case .buddy: sharedFolders = sharedBuddyFolders
        default: sharedFolders = sharedPublicFolders
        }

        do {
            try shareDBs.load([.files(permissionLevel), .mtimes(permissionLevel)], dataFolderPath: dataFolderPath)
        } catch {
            // No previous share databases, rebuild
            rebuild = true
        }

        let oldFiles = shareDBs.files[permissionLevel]
        let oldMtimes = shareDBs.mtimes[permissionLevel]

        for sharedFolder in sharedFolders.sorted(by: { ($0.virtualName, $0.path) < ($1.virtualName, $1.path) }) {
            if processedShareNames.contains(sharedFolder.virtualName) {
                // No duplicate names
                continue
            }

            if processedSharePaths.contains(sharedFolder.path) {
                // No duplicate folder paths
                continue
            }

            scanSharedFolder(sharedFolder.path, oldMtimes: oldMtimes, oldFiles: oldFiles)

            processedShareNames.insert(sharedFolder.virtualName)
            processedSharePaths.insert(sharedFolder.path)
        }

        // Save data to databases
        shareDBs.close()
        try setShares(permissionLevel)

        files.removeAll()
        streams.removeAll()
        streamOrder.removeAll()
        mtimes.removeAll()
    }

    /// Stops sharing any dot/hidden folders/files.
    static func isHidden(folder: String, fileName: String? = nil) -> Bool {
        if let fileName {
            // If we're asked to check a file, we exclude it if it starts with a dot
            return fileName.hasPrefix(".")
        }

        let lastFolder = (folder as NSString).lastPathComponent
        return lastFolder.hasPrefix(".") || hiddenFolderNames.contains(lastFolder)
    }

    /// Scans a shared folder for all subfolders, files and their metadata.
    private func scanSharedFolder(_ sharedFolderPath: String, oldMtimes: ShareDatabase<Double>?,
                                  oldFiles: ShareDatabase<SharedFileInfo>?) {
        let fileManager = FileManager.default
        var folderPaths = [sharedFolderPath]

        while let folderPath = folderPaths.popLast() {
            guard let virtualFolderPath = try? realToVirtual(folderPath) else {
                continue
            }

            if streams[virtualFolderPath] != nil {
                // Sharing a folder twice, no go
                continue
            }

            var fileList: [SharedFileInfo] = []

            do {
                let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
                let entries = try fileManager.contentsOfDirectory(
                    at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: []
                )

                for entry in entries {
                    let basename = entry.lastPathComponent
                    let path = (folderPath as NSString).appendingPathComponent(basename)

                    do {
                        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                                        .contentModificationDateKey])

                        if values.isDirectory == true {
                            if Self.isHidden(folder: path) {
                                continue
                            }

                            currentFolderCount += 1
                            folderPaths.append(path)

                            if currentFolderCount % 100 == 0 {
                                emit(.folderCount(currentFolderCount))
                            }
                            continue
                        }

                        if Self.isHidden(folder: folderPath, fileName: basename) {
                            continue
                        }

                        let fileIndex = currentFileIndex
                        let fileMtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                        let fileSize = values.fileSize ?? 0
                        let virtualFilePath = "\(virtualFolderPath)\\\(basename)"
                        var fullPathFileData: SharedFileInfo

                        mtimes.append((path, fileMtime))

                        if !rebuild, fileMtime == oldMtimes?[path], let oldFileData = oldFiles?[path] {
                            fullPathFileData = oldFileData
                            fullPathFileData.virtualPath = virtualFilePath  // Virtual name might have changed
                        } else {
                            fullPathFileData = fileInfo(virtualFilePath: virtualFilePath, filePath: path, size: fileSize)
                        }

                        var basenameFileData = fullPathFileData
                        basenameFileData.virtualPath = basename
                        fileList.append(basenameFileData)

                        for word in shareWords(virtualFilePath) {
                            wordIndex[word, default: []].append(fileIndex)
                        }

                        files.append((path, fullPathFileData))
                        currentFileIndex += 1

                    } catch {
                        emit(.logMessage(String(localized: "Error while scanning file \(path): \(error.localizedDescription)",
                                                bundle: .module)))
                    }
                }

            } catch {
                emit(.logMessage(String(localized: "Error while scanning folder \(folderPath): \(error.localizedDescription)",
                                        bundle: .module)))
            }

            streams[virtualFolderPath] = Self.folderStream(fileList)
            streamOrder.append(virtualFolderPath)
        }
    }

    private func audioTag(filePath: String, size: Int) throws -> TinyTag? {
        guard let parserClass = TinyTag.parserClass(for: filePath) else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        let tag = parserClass.init(reader: TinyTagReader(handle: handle, fileSize: size))
        try tag.load()
        return tag
    }

    /// Gets file metadata.
    private func fileInfo(virtualFilePath: String, filePath: String, size: Int) -> SharedFileInfo {
        var tag: TinyTag?
        var quality: AudioQuality?
        var duration: Int?

        // We skip metadata scanning of files without meaningful content
        if size > 128 {
            do {
                tag = try audioTag(filePath: filePath, size: size)
            } catch {
                emit(.logMessage(String(localized: "Error while scanning metadata for file \(filePath): \(error.localizedDescription)",
                                        bundle: .module)))
            }
        }

        if let tag {
            let limit = Double(UInt32.max)
            var bitrate: Int?
            var sampleRate: Int?
            var bitDepth: Int?

            if let value = tag.bitrate, value.isFinite {
                // Round the value with minimal performance loss
                let rounded = (value + 0.5).rounded(.towardZero)
                bitrate = (rounded > 0 && rounded < limit) ? Int(rounded) : nil
            }

            if let value = tag.sampleRate {
                sampleRate = (value > 0 && Double(value) < limit) ? value : nil
            }

            if let value = tag.bitDepth {
                bitDepth = (value > 0 && Double(value) < limit) ? value : nil
            }

            if let value = tag.duration, value.isFinite {
                let truncated = value.rounded(.towardZero)
                duration = (truncated >= 0 && truncated < limit) ? Int(truncated) : nil
            }

            quality = AudioQuality(bitrate: bitrate, isVBR: tag.isVBR, sampleRate: sampleRate, bitDepth: bitDepth)
        }

        return SharedFileInfo(virtualPath: virtualFilePath, size: size, quality: quality, duration: duration)
    }

    /// Packs all files and metadata in a folder.
    static func folderStream(_ fileList: [SharedFileInfo]) -> Data {
        var stream = Data()
        stream.appendUInt32(fileList.count)

        for fileInfo in fileList {
            stream.append(FileListMessage.packFileInfo(fileInfo))
        }

        return stream
    }
}

// MARK: - Shares

@MainActor
public final class Shares {

    static let invalidSharePrefix = "__INVALID_SHARE__"

    let shareDBs = ShareDatabases()
    private var requestedShareTimes: [String: Double] = [:]
    public private(set) var isInitialized = false
    public private(set) var isRescanning = false
    private var compressedShares: [PermissionLevel: SharedFileListResponse] = [
        .public: SharedFileListResponse(permissionLevel: .public),
        .buddy: SharedFileListResponse(permissionLevel: .buddy),
        .trusted: SharedFileListResponse(permissionLevel: .trusted),
        .banned: SharedFileListResponse(permissionLevel: .banned)
    ]
    public private(set) var filePathIndex: [String] = []
    private var scannerThread: Thread?

    init() {
        events.connect(.folderContentsRequest) { [self] msg in folderContentsRequest(msg) }
        events.connect(.quit) { [self] in quit() }
        events.connect(.serverDisconnect) { [self] _ in requestedShareTimes.removeAll() }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.sharedFileListRequest) { [self] msg in sharedFileListRequest(msg) }
        events.connect(.sharesReady) { [self] successful in sharesReady(successful) }
        events.connect(.start) { [self] in start() }
    }

    private func start() {
        let rescanStartup = config.transfers.rescanOnStartup && !config.needsConfig

        convertShares()
        rescanShares(initializing: true, rescan: rescanStartup)
    }

    private func quit() {
        shareDBs.close()
        isInitialized = false
    }

    private func serverLogin(_ msg: Login) {
        if msg.success {
            sendNumSharedFoldersFiles()
        }
    }

    // MARK: Shares-related Actions

    nonisolated static func createDBFile<Value>(_ path: String) throws -> ShareDatabase<Value> {
        removeDBFile(path)
        return try ShareDatabase<Value>(filePath: path)
    }

    nonisolated static func removeDBFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func virtualToReal(_ virtualPath: String) -> String {
        for shares in [config.transfers.shared, config.transfers.buddyShared, config.transfers.trustedShared] {
            for sharedFolder in shares {
                let virtualName = sharedFolder.virtualName

                if virtualPath == virtualName {
                    return sharedFolder.path
                }

                if virtualPath.hasPrefix(virtualName + "\\") {
                    var folderPath = sharedFolder.path
                    while folderPath.hasSuffix("/") { folderPath.removeLast() }

                    return folderPath + virtualPath.dropFirst(virtualName.count).replacingOccurrences(of: "\\", with: "/")
                }
            }
        }

        return Self.invalidSharePrefix + virtualPath
    }

    /// Normalizes shared folder names and paths.
    private func convertShares() {
        func convert(_ sharedFolder: SharedFolder) -> SharedFolder {
            // Remove slashes from share name to avoid path conflicts
            let virtualName = sharedFolder.virtualName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let path = sharedFolder.path.isEmpty ? "" : (sharedFolder.path as NSString).standardizingPath

            return SharedFolder(virtualName: virtualName, path: path)
        }

        config.transfers.shared = config.transfers.shared.map(convert)
        config.transfers.buddyShared = config.transfers.buddyShared.map(convert)
    }

    public func fileIsShared(username: String, virtualPath: String, realPath: String) -> (isShared: Bool, size: Int?) {
        log.addTransfer("Checking if file is shared: \(virtualPath) with real path \(realPath)")

        var fileInfo: SharedFileInfo?

        if !realPath.hasPrefix(Self.invalidSharePrefix) {
            if let publicFiles = shareDBs.files[.public], publicFiles.contains(realPath) {
                fileInfo = publicFiles[realPath]

            } else if let buddyFiles = shareDBs.files[.buddy], core.buddies.users[username] != nil,
                      buddyFiles.contains(realPath) {
                fileInfo = buddyFiles[realPath]

            } else if let trustedFiles = shareDBs.files[.trusted], core.buddies.users[username]?.isTrusted == true,
                      trustedFiles.contains(realPath) {
                fileInfo = trustedFiles[realPath]
            }
        }

        guard let fileInfo else {
            log.addTransfer("File is not present in the database of shared files, not sharing: "
                            + "\(virtualPath) with real path \(realPath)")
            return (false, nil)
        }

        return (true, fileInfo.size)
    }

    /// Checks if this user is banned, geoip-blocked, and which shares it is
    /// allowed to access based on transfer and shares settings.
    public func checkUserPermission(_ username: String, ipAddress: String? = nil)
        -> (level: PermissionLevel, rejectReason: String) {
        let transfers = config.transfers

        if core.networkFilter.isUserBanned(username)
            || core.networkFilter.isUserIPBanned(username: username, ipAddress: ipAddress) {
            return (.banned, transfers.useCustomBan ? transfers.customBan : "")
        }

        if let userData = core.buddies.users[username] {
            return (userData.isTrusted ? .trusted : .buddy, "")
        }

        guard let ipAddress, transfers.geoBlock else {
            return (.public, "")
        }

        let countryCode = core.networkFilter.countryCode(ipAddress: ipAddress)

        // Please note that all country codes are stored in the same string at the first index
        // of an array, separated by commas
        if !countryCode.isEmpty, transfers.geoBlockCountryCodes.first?.contains(countryCode) == true {
            return (.banned, transfers.useCustomGeoBlock ? transfers.customGeoBlock : "")
        }

        return (.public, "")
    }

    /// Compressed list of shares for a permission level, as sent to peers.
    func compressedSharesData(for level: PermissionLevel) -> Data? {
        compressedShares[level]?.built
    }

    public var sharedFolders: (public: [SharedFolder], buddy: [SharedFolder], trusted: [SharedFolder]) {
        (config.transfers.shared, config.transfers.buddyShared, config.transfers.trustedShared)
    }

    public func normalizedVirtualName(_ virtualName: String, sharedFolders: [SharedFolder]? = nil) -> String {
        let sharedFolders = sharedFolders ?? {
            let groups = self.sharedFolders
            return groups.public + groups.buddy + groups.trusted
        }()

        // Provide a default name for root folders
        var virtualName = virtualName.isEmpty ? "Shared" : virtualName

        // Remove slashes from share name to avoid path conflicts
        virtualName = virtualName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))

        var newVirtualName = virtualName
        let existingNames = Set(sharedFolders.map(\.virtualName))

        // Check if virtual share name is already in use
        var counter = 1
        while existingNames.contains(newVirtualName) {
            newVirtualName = "\(virtualName)\(counter)"
            counter += 1
        }

        return newVirtualName
    }

    @discardableResult
    public func addShare(_ folderPath: String, permissionLevel: PermissionLevel = .public,
                         virtualName: String? = nil, validatePath: Bool = true) -> String? {
        if validatePath && !FileManager.default.isReadableFile(atPath: folderPath) {
            return nil
        }

        // Remove previous share with same path if present
        removeShare(folderPath)

        let groups = sharedFolders
        let virtualName = normalizedVirtualName(
            virtualName ?? (folderPath as NSString).lastPathComponent,
            sharedFolders: groups.public + groups.buddy + groups.trusted
        )
        let share = SharedFolder(virtualName: virtualName, path: (folderPath as NSString).standardizingPath)

        switch permissionLevel {
        case .buddy: config.transfers.buddyShared.append(share)
        case .trusted: config.transfers.trustedShared.append(share)
        default: config.transfers.shared.append(share)
        }

        return virtualName
    }

    @discardableResult
    public func removeShare(_ virtualNameOrFolderPath: String) -> Bool {
        let normalizedFolderPath = (virtualNameOrFolderPath as NSString).standardizingPath

        func matches(_ share: SharedFolder) -> Bool {
            virtualNameOrFolderPath == share.virtualName || virtualNameOrFolderPath == share.path
                || share.path == normalizedFolderPath
        }

        for keyPath in [\TransferSettings.shared, \TransferSettings.buddyShared, \TransferSettings.trustedShared] {
            if let index = config.transfers[keyPath: keyPath].firstIndex(where: matches) {
                config.transfers[keyPath: keyPath].remove(at: index)
                return true
            }
        }

        return false
    }

    /// Sends the number of publicly shared files to the server.
    public func sendNumSharedFoldersFiles() {
        guard !isRescanning else {
            return
        }

        let localUsername = core.usersComponent?.loginUsername
        var numSharedFolders = shareDBs.streams[.public]?.count ?? 0
        var numSharedFiles = shareDBs.files[.public]?.count ?? 0

        if config.transfers.revealBuddyShares {
            numSharedFolders += shareDBs.streams[.buddy]?.count ?? 0
            numSharedFiles += shareDBs.files[.buddy]?.count ?? 0
        }

        if config.transfers.revealTrustedShares {
            numSharedFolders += shareDBs.streams[.trusted]?.count ?? 0
            numSharedFiles += shareDBs.files[.trusted]?.count ?? 0
        }

        core.sendMessageToServer(SharedFoldersFiles(folders: numSharedFolders, files: numSharedFiles))

        guard let localUsername else {
            // The shares module is initialized before the users module (to send updated share
            // stats to the server before watching our own username), and receives the login
            // event first, so the username is still unknown when connecting. For this reason,
            // this check only happens after sending the SharedFoldersFiles server message.
            return
        }

        // We've connected and rescanned our shares again. Fake a user stats message, since
        // server doesn't send updates for our own username after the first WatchUser message
        // response
        let stats = GetUserStats(user: localUsername)
        stats.avgSpeed = core.uploadsComponent?.uploadSpeed ?? 0
        stats.files = numSharedFiles
        stats.dirs = numSharedFolders

        events.emit(.userStats, stats)
    }

    // MARK: Scanning

    @discardableResult
    public func rebuildShares(useThread: Bool = true) -> Bool? {
        rescanShares(rebuild: true, useThread: useThread)
    }

    @discardableResult
    public func rescanShares(initializing: Bool = false, rescan: Bool = true, rebuild: Bool = false,
                             useThread: Bool = true, force: Bool = false) -> Bool? {
        guard !isRescanning else {
            return nil
        }

        var rescan = rescan

        if rescan && !force {
            // Verify all shares are mounted before allowing destructive rescan
            let unavailableShares = checkSharesAvailable()

            if !unavailableShares.isEmpty {
                let description = unavailableShares.map { "(\($0.virtualName), \($0.path))" }.joined(separator: ", ")
                log.add(String(localized: "Rescan aborted due to unavailable shares: \(description)", bundle: .module))
                rescan = false

                events.emit(.sharesUnavailable, unavailableShares)

                if !initializing {
                    return nil
                }
            }
        }

        // Hand over database control to the scanner
        isRescanning = true
        shareDBs.close()
        filePathIndex = []

        events.emit(.sharesPreparing)

        let groups = sharedFolders
        let dataFolderPath = config.dataFolderPath
        let revealBuddyShares = config.transfers.revealBuddyShares
        let revealTrustedShares = config.transfers.revealTrustedShares

        guard useThread else {
            var successful = true

            let scanner = Scanner(
                emit: { [self] item in
                    MainActor.assumeIsolated {
                        if case .state(.failure) = item {
                            successful = false
                        }
                        processScannerItem(item, emitEvents: false)
                    }
                },
                shareGroups: [groups.public, groups.buddy, groups.trusted], dataFolderPath: dataFolderPath,
                initializing: initializing, rescan: rescan, rebuild: rebuild,
                revealBuddyShares: revealBuddyShares, revealTrustedShares: revealTrustedShares
            )
            scanner.run()
            return successful
        }

        let scanner = Scanner(
            emit: { item in
                events.invokeMainThread { [self] in
                    processScannerItem(item, emitEvents: true)
                }
            },
            shareGroups: [groups.public, groups.buddy, groups.trusted], dataFolderPath: dataFolderPath,
            initializing: initializing, rescan: rescan, rebuild: rebuild,
            revealBuddyShares: revealBuddyShares, revealTrustedShares: revealTrustedShares
        )

        let thread = Thread { [weak self] in
            scanner.run()

            events.invokeMainThread {
                self?.scannerFinished()
            }
        }
        thread.name = "ShareScanner"
        thread.qualityOfService = .utility
        scannerThread = thread
        thread.start()

        return nil
    }

    public func checkSharesAvailable() -> [SharedFolder] {
        let groups = sharedFolders
        return (groups.public + groups.buddy + groups.trusted).filter {
            !FileManager.default.isReadableFile(atPath: $0.path)
        }
    }

    private var scanSuccessful = true

    private func processScannerItem(_ item: ScannerItem, emitEvents: Bool) {
        switch item {
        case .state(.failure):
            scanSuccessful = false

        case let .folderCount(count):
            if emitEvents {
                events.emit(.sharesScanning, count)
            }

        case let .logMessage(message):
            log.add(message)

        case let .filePathIndex(index):
            filePathIndex = index

        case let .compressedShares(message):
            if let level = message.permissionLevel {
                compressedShares[level] = message
            }

        case .state(.rescanning):
            if emitEvents {
                events.emit(.sharesScanning, nil)
            }

        case .state(.initialized):
            isInitialized = true
        }
    }

    private func scannerFinished() {
        let successful = scanSuccessful

        scanSuccessful = true
        scannerThread = nil
        events.emit(.sharesReady, successful)
    }

    private func sharesReady(_ successful: Bool) {
        var successful = successful

        // Scanning done, load shares in the main thread again
        if successful {
            do {
                try shareDBs.load([
                    .words, .publicFiles, .publicStreams, .buddyFiles, .buddyStreams, .trustedFiles, .trustedStreams
                ], dataFolderPath: config.dataFolderPath)
            } catch {
                successful = false
            }
        }

        isRescanning = false

        guard successful else {
            filePathIndex = []
            return
        }

        // Share stats are sent when logging in, avoid sending them before the Login message
        if core.usersComponent?.loginStatus != .offline {
            sendNumSharedFoldersFiles()
        }
    }

    // MARK: Network Messages

    /// Peer code 4.
    private func sharedFileListRequest(_ msg: SharedFileListRequest) {
        guard let username = msg.username else {
            return
        }

        let requestTime = ProcessInfo.processInfo.systemUptime

        if let previousTime = requestedShareTimes[username], requestTime < previousTime + 0.4 {
            // Ignoring request, because it's less than half a second since the
            // last one by this user
            return
        }

        requestedShareTimes[username] = requestTime

        log.add(String(localized: "User \(username) is browsing your list of shared files", bundle: .module))

        let (permissionLevel, _) = checkUserPermission(username, ipAddress: msg.addr?.ipAddress)

        guard let sharesList = compressedShares[permissionLevel] else {
            return
        }

        // Send a copy, since the message is associated with a specific connection
        let response = SharedFileListResponse(permissionLevel: permissionLevel)
        response.built = sharesList.built

        core.sendMessageToPeer(username, response)
    }

    /// Peer code 36.
    private func folderContentsRequest(_ msg: FolderContentsRequest) {
        guard let username = msg.username else {
            return
        }

        let folderPath = msg.folder
        let (permissionLevel, _) = checkUserPermission(username, ipAddress: msg.addr?.ipAddress)
        var folderData: Data?

        if permissionLevel != .banned {
            folderData = shareDBs.streams[.public]?[folderPath]

            if folderData == nil
                && (config.transfers.revealBuddyShares || permissionLevel == .buddy || permissionLevel == .trusted) {
                folderData = shareDBs.streams[.buddy]?[folderPath]
            }

            if folderData == nil && (config.transfers.revealTrustedShares || permissionLevel == .trusted) {
                folderData = shareDBs.streams[.trusted]?[folderPath]
            }
        }

        core.sendMessageToPeer(username, FolderContentsResponse(folder: folderPath, token: msg.token,
                                                                packedFiles: folderData))
    }
}
