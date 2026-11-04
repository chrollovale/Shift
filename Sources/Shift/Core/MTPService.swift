#if SHIFT_ENABLE_MTP
import Foundation
import ShiftMTPBridge

struct MTPServiceError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct MTPStorage: Decodable, Hashable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let freeBytes: UInt64
    let maxCapacity: UInt64

    var path: String { "/mtp/\(id)" }
}

struct MTPTransferItem: Decodable, Sendable {
    let id: UInt32
    let parentId: UInt32
    let storageId: UInt32
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Int64
}

private struct MTPDetectedDevice: Decodable {
    let id: String
    let name: String
}

/// Thread-safe progress and cancellation state passed through libmtp's C callback.
final class MTPTransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completedBytes: Int64 = 0
    private var expectedTotal: Int64?
    private let update: @Sendable (Int64, Int64) -> Void

    init(totalBytes: Int64? = nil, update: @escaping @Sendable (Int64, Int64) -> Void) {
        expectedTotal = totalBytes
        self.update = update
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setTotal(_ total: Int64) {
        lock.lock()
        expectedTotal = total
        lock.unlock()
    }

    func beginFile() {
        // The byte offset stays at the aggregate completed count until this file reports progress.
    }

    func receive(sent: UInt64, total: UInt64) -> Int32 {
        lock.lock()
        let isCancelled = cancelled
        let done = completedBytes + Int64(clamping: sent)
        let aggregateTotal = expectedTotal ?? (completedBytes + Int64(clamping: total))
        lock.unlock()
        update(done, aggregateTotal)
        return isCancelled ? 1 : 0
    }

    func finishFile(_ byteCount: Int64) {
        lock.lock()
        completedBytes += max(0, byteCount)
        let done = completedBytes
        let total = expectedTotal ?? completedBytes
        lock.unlock()
        update(done, total)
    }
}

private final class MTPConnection: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    deinit {
        shift_mtp_close_device(pointer)
    }
}

private let mtpProgressCallback: @convention(c) (
    UInt64, UInt64, UnsafeMutableRawPointer?
) -> Int32 = { sent, total, context in
    guard let context else { return 0 }
    return Unmanaged<MTPTransferProgress>.fromOpaque(context)
        .takeUnretainedValue()
        .receive(sent: sent, total: total)
}

/// MTP backend backed by libmtp. All access to the device is serialized by this actor.
actor MTPService {
    private static let rootObjectID = UInt32.max
    private var connection: MTPConnection?
    private var connectedID: String?
    private var cachedStorages: [MTPStorage] = []

    static func detectDevices() throws -> [Device] {
        let records: [MTPDetectedDevice] = try decode(shift_mtp_detect_devices_json())
        return records.map {
            Device(serial: "mtp:" + $0.id, state: .ready, name: $0.name, transport: .mtp)
        }
    }

    func open(deviceID: String) throws {
        if connectedID == deviceID, connection != nil { return }
        connection = nil
        connectedID = nil
        cachedStorages = []

        var error: UnsafeMutablePointer<CChar>?
        let pointer = deviceID.withCString { shift_mtp_open_device($0, &error) }
        defer { free(error) }
        guard let pointer else {
            throw MTPServiceError(message: Self.message(error, fallback: "Couldn't open the MTP device."))
        }
        connection = MTPConnection(pointer)
        connectedID = deviceID
        do {
            cachedStorages = try readStorages()
        } catch {
            connection = nil
            connectedID = nil
            throw error
        }
        guard !cachedStorages.isEmpty else {
            connection = nil
            connectedID = nil
            throw MTPServiceError(message: "The MTP device has no accessible storage.")
        }
    }

    func close() {
        connection = nil
        connectedID = nil
        cachedStorages = []
    }

    func storageRoots() -> [MTPStorage] { cachedStorages }

    func refreshStorageRoots() throws -> [MTPStorage] {
        cachedStorages = try readStorages()
        return cachedStorages
    }

    func freeSpace(at path: String) -> Int64? {
        guard let storageID = Self.storageID(from: path),
              let storage = cachedStorages.first(where: { $0.id == storageID }) else { return nil }
        return Int64(clamping: storage.freeBytes)
    }

    func list(_ path: String) throws -> [FileEntry] {
        let (storage, parentID) = try resolveDirectory(path)
        return try list(storageID: storage.id, parentID: parentID).map { item in
            FileEntry(
                path: RemotePath.join(path, item.name),
                name: item.name,
                isDirectory: item.isDirectory,
                size: Int64(clamping: item.size),
                modified: item.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(item.modified)) : nil
            )
        }
    }

    func upload(
        localPath: String,
        to remoteDirectory: String,
        name: String,
        isDirectory: Bool,
        replaceExisting: Bool,
        progress: MTPTransferProgress?
    ) throws {
        let (storage, parentID) = try resolveDirectory(remoteDirectory)
        if try list(storageID: storage.id, parentID: parentID).contains(where: { $0.name == name }) {
            guard replaceExisting else {
                throw MTPServiceError(message: "An item named \(name) already exists on the phone. Refresh and choose Replace to overwrite it.")
            }
            try delete(RemotePath.join(remoteDirectory, name))
        }
        let source = URL(fileURLWithPath: localPath, isDirectory: isDirectory)
        if isDirectory {
            if let progress {
                progress.setTotal(Self.localDirectorySize(source))
            }
            let folderID = try makeDirectory(name, parentID: parentID, storageID: storage.id)
            try uploadDirectory(source, parentID: folderID, storageID: storage.id, progress: progress)
        } else {
            let size = Self.localFileSize(source)
            progress?.setTotal(size)
            progress?.beginFile()
            try uploadFile(source, name: name, parentID: parentID, storageID: storage.id, progress: progress)
            progress?.finishFile(size)
        }
    }

    func download(
        remotePath: String,
        to localURL: URL,
        isDirectory: Bool,
        progress: MTPTransferProgress?
    ) throws {
        let item = try resolve(remotePath)
        guard item.isDirectory == isDirectory else {
            throw MTPServiceError(message: "The selected item changed before the transfer began.")
        }
        if isDirectory {
            progress?.setTotal(try directorySize(item))
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            try downloadDirectory(item, to: localURL, progress: progress)
        } else {
            progress?.setTotal(Int64(clamping: item.size))
            progress?.beginFile()
            try downloadFile(item, to: localURL, progress: progress)
            progress?.finishFile(Int64(clamping: item.size))
        }
    }

    func makeDirectory(_ name: String, in path: String) throws {
        let (storage, parentID) = try resolveDirectory(path)
        _ = try makeDirectory(name, parentID: parentID, storageID: storage.id)
    }

    func rename(_ path: String, to name: String) throws {
        let item = try resolve(path)
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = name.withCString { shift_mtp_rename(handle, item.id, $0, &error) }
            defer { free(error) }
            guard result == 0 else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't rename this item on the phone."))
            }
        }
    }

    func delete(_ path: String) throws {
        let item = try resolve(path)
        if item.isDirectory {
            for child in try list(storageID: item.storageId, parentID: item.id) {
                let childPath = RemotePath.join(path, child.name)
                try delete(childPath)
            }
        }
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = shift_mtp_delete(handle, item.id, &error)
            defer { free(error) }
            guard result == 0 else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't delete this item from the phone."))
            }
        }
    }

    private func uploadDirectory(
        _ localDirectory: URL,
        parentID: UInt32,
        storageID: UInt32,
        progress: MTPTransferProgress?
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: localDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            if progress?.shouldCancel() == true {
                throw MTPServiceError(message: "Transfer cancelled.")
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let folderID = try makeDirectory(child.lastPathComponent, parentID: parentID, storageID: storageID)
                try uploadDirectory(child, parentID: folderID, storageID: storageID, progress: progress)
            } else {
                let size = Self.localFileSize(child)
                progress?.beginFile()
                try uploadFile(child, name: child.lastPathComponent, parentID: parentID, storageID: storageID, progress: progress)
                progress?.finishFile(size)
            }
        }
    }

    private func uploadFile(
        _ localFile: URL,
        name: String,
        parentID: UInt32,
        storageID: UInt32,
        progress: MTPTransferProgress?
    ) throws {
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let context = progress.map { Unmanaged.passUnretained($0).toOpaque() }
            let result = localFile.path.withCString { localPath in
                name.withCString { remoteName in
                    shift_mtp_upload(
                        handle, localPath, remoteName, parentID, storageID,
                        progress == nil ? nil : mtpProgressCallback,
                        context,
                        &error
                    )
                }
            }
            defer { free(error) }
            guard result == 0 else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't upload \(name)."))
            }
        }
    }

    private func downloadDirectory(
        _ directory: MTPTransferItem,
        to localDirectory: URL,
        progress: MTPTransferProgress?
    ) throws {
        for child in try list(storageID: directory.storageId, parentID: directory.id) {
            if progress?.shouldCancel() == true {
                throw MTPServiceError(message: "Transfer cancelled.")
            }
            let localChild = localDirectory.appendingPathComponent(child.name, isDirectory: child.isDirectory)
            if child.isDirectory {
                try FileManager.default.createDirectory(at: localChild, withIntermediateDirectories: true)
                try downloadDirectory(child, to: localChild, progress: progress)
            } else {
                progress?.beginFile()
                try downloadFile(child, to: localChild, progress: progress)
                progress?.finishFile(Int64(clamping: child.size))
            }
        }
    }

    private func directorySize(_ item: MTPTransferItem) throws -> Int64 {
        try list(storageID: item.storageId, parentID: item.id).reduce(Int64(0)) { total, child in
            let size = child.isDirectory ? try directorySize(child) : Int64(clamping: child.size)
            return total + size
        }
    }

    private static func localFileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func localDirectorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func downloadFile(
        _ item: MTPTransferItem,
        to localURL: URL,
        progress: MTPTransferProgress?
    ) throws {
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let context = progress.map { Unmanaged.passUnretained($0).toOpaque() }
            let result = localURL.path.withCString { path in
                shift_mtp_download(
                    handle, item.id, path,
                    progress == nil ? nil : mtpProgressCallback,
                    context,
                    &error
                )
            }
            defer { free(error) }
            guard result == 0 else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't download \(item.name)."))
            }
        }
    }

    private func makeDirectory(_ name: String, parentID: UInt32, storageID: UInt32) throws -> UInt32 {
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = name.withCString { shift_mtp_make_directory(handle, $0, parentID, storageID, &error) }
            defer { free(error) }
            guard result > 0 else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't create the folder on the phone."))
            }
            return UInt32(result)
        }
    }

    private func resolveDirectory(_ path: String) throws -> (MTPStorage, UInt32) {
        let parts = try pathParts(path)
        guard let storageID = UInt32(parts[1]),
              let storage = cachedStorages.first(where: { $0.id == storageID }) else {
            throw MTPServiceError(message: "That MTP storage is no longer available.")
        }
        var parentID = Self.rootObjectID
        for component in parts.dropFirst(2) {
            guard let match = try list(storageID: storageID, parentID: parentID).first(where: { $0.name == component }),
                  match.isDirectory else {
                throw MTPServiceError(message: "That folder no longer exists on the phone.")
            }
            parentID = match.id
        }
        return (storage, parentID)
    }

    private func resolve(_ path: String) throws -> MTPTransferItem {
        let parts = try pathParts(path)
        guard let storageID = UInt32(parts[1]), cachedStorages.contains(where: { $0.id == storageID }) else {
            throw MTPServiceError(message: "That MTP storage is no longer available.")
        }
        guard parts.count > 2 else {
            return MTPTransferItem(id: Self.rootObjectID, parentId: Self.rootObjectID, storageId: storageID, name: "", isDirectory: true, size: 0, modified: 0)
        }

        var parentID = Self.rootObjectID
        var found: MTPTransferItem?
        for component in parts.dropFirst(2) {
            guard let item = try list(storageID: storageID, parentID: parentID).first(where: { $0.name == component }) else {
                throw MTPServiceError(message: "That item no longer exists on the phone.")
            }
            found = item
            parentID = item.id
        }
        guard let found else {
            throw MTPServiceError(message: "That item no longer exists on the phone.")
        }
        return found
    }

    private func pathParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "mtp", !parts.contains("..") else {
            throw MTPServiceError(message: "That MTP location can't be changed from Shift.")
        }
        return parts
    }

    private func list(storageID: UInt32, parentID: UInt32) throws -> [MTPTransferItem] {
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let raw = shift_mtp_list_json(handle, storageID, parentID, &error)
            defer { free(error) }
            guard let raw else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't read this folder from the phone."))
            }
            defer { shift_mtp_free(UnsafeMutableRawPointer(raw)) }
            return try JSONDecoder().decode([MTPTransferItem].self, from: Data(String(cString: raw).utf8))
        }
    }

    private func readStorages() throws -> [MTPStorage] {
        try withHandle { handle in
            var error: UnsafeMutablePointer<CChar>?
            let raw = shift_mtp_storages_json(handle, &error)
            defer { free(error) }
            guard let raw else {
                throw MTPServiceError(message: Self.message(error, fallback: "Couldn't read storage from the phone."))
            }
            defer { shift_mtp_free(UnsafeMutableRawPointer(raw)) }
            return try JSONDecoder().decode([MTPStorage].self, from: Data(String(cString: raw).utf8))
        }
    }

    private func withHandle<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        guard let handle = connection?.pointer else {
            throw MTPServiceError(message: "The MTP device disconnected.")
        }
        return try body(handle)
    }

    private static func decode<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?, as type: T.Type = T.self) throws -> T {
        guard let raw else { throw MTPServiceError(message: "Couldn't read the connected MTP devices.") }
        defer { shift_mtp_free(UnsafeMutableRawPointer(raw)) }
        return try JSONDecoder().decode(T.self, from: Data(String(cString: raw).utf8))
    }

    private static func message(_ error: UnsafeMutablePointer<CChar>?, fallback: String) -> String {
        guard let error else { return fallback }
        let text = String(cString: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private static func storageID(from path: String) -> UInt32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "mtp" else { return nil }
        return UInt32(parts[1])
    }
}

private func free(_ pointer: UnsafeMutablePointer<CChar>?) {
    guard let pointer else { return }
    shift_mtp_free(UnsafeMutableRawPointer(pointer))
}
#endif
