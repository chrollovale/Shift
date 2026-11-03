import Foundation

// MARK: - Models

struct FileEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }

    var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    /// SF Symbol that best describes the entry.
    var symbolName: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "dng", "raw", "tiff":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v":
            return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus":
            return "music.note"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "xz":
            return "doc.zipper"
        case "apk", "aab", "xapk":
            return "shippingbox"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "log", "json", "xml", "csv", "html":
            return "doc.text"
        default:
            return "doc"
        }
    }
}

enum DeviceState: String {
    case ready
    case unauthorized
    case offline
    case unknown
}

struct Device: Identifiable, Hashable {
    let serial: String
    var state: DeviceState
    var name: String

    var id: String { serial }

    /// Wi-Fi devices show up as "192.168.1.20:5555" or "adb-XXXX._adb-tls-connect._tcp".
    var isWireless: Bool {
        if serial.hasPrefix("emulator-") { return false }
        return serial.contains(":") || serial.contains("._adb")
    }
}

enum SortKey: String, CaseIterable {
    case name
    case size
    case modified
}

struct SortSpec: Equatable {
    var key: SortKey
    var ascending: Bool
}

extension Array where Element == FileEntry {
    /// Folders first, then by the chosen column. Ties fall back to the name.
    func ordered(by spec: SortSpec) -> [FileEntry] {
        return self.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var order: ComparisonResult
            switch spec.key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .size:
                order = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified:
                let da = a.modified ?? Date.distantPast
                let db = b.modified ?? Date.distantPast
                order = da == db ? .orderedSame : (da < db ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                order = a.name.localizedStandardCompare(b.name)
                return order == .orderedAscending
            }
            return spec.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yy, HH:mm"
        return f
    }()

    static func date(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        return dateFormatter.string(from: d)
    }
}

// MARK: - Remote (phone) paths

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func asDirectory(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    static func parent(of path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard p != "/", let slash = p.lastIndex(of: "/") else { return "/" }
        let head = String(p[p.startIndex..<slash])
        return head.isEmpty ? "/" : head
    }

    /// Guard rail for destructive operations: only allow paths inside shared storage.
    static func isSafeToModify(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("..") { return false }
        if path.hasPrefix("/sdcard/") { return parts.count >= 2 }
        if path.hasPrefix("/storage/") {
            // /storage/emulated/0 and /storage/self/primary are the storage roots themselves.
            if parts.count >= 2 && (parts[1] == "emulated" || parts[1] == "self") { return parts.count >= 4 }
            return parts.count >= 3
        }
        return false
    }
}

// MARK: - adb output parsing

enum AdbParse {
    /// Single-quotes a string for the Android shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parses `adb devices -l`.
    static func devices(_ text: String) -> [Device] {
        var result: [Device] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }

            let state: DeviceState
            switch parts[1] {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            case "offline", "authorizing", "connecting": state = .offline
            default: state = .unknown
            }

            var model = ""
            for token in parts.dropFirst(2) where token.hasPrefix("model:") {
                model = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(Device(serial: parts[0], state: state, name: model.isEmpty ? parts[0] : model))
        }
        return result
    }

    private static let lsPattern = try! NSRegularExpression(
        pattern: #"^([\-dlcbps])[rwxsStTl\-]{9}[.+@]?\s+\d+\s+\S+\s+\S+\s+(?:\d+,\s*)?(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?::\d{2})?\s+(.+)$"#
    )

    private static let lsDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func group(_ m: NSTextCheckingResult, _ index: Int, in s: String) -> String? {
        guard let r = Range(m.range(at: index), in: s) else { return nil }
        return String(s[r])
    }

    /// Parses `ls -lAL <dir>/` output from toybox (Android 6+).
    static func ls(_ text: String, in directory: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = lsPattern.firstMatch(in: line, options: [], range: range),
                  let type = group(m, 1, in: line),
                  let sizeText = group(m, 2, in: line),
                  let day = group(m, 3, in: line),
                  let time = group(m, 4, in: line),
                  var name = group(m, 5, in: line) else { continue }

            // Skip device nodes, sockets and pipes.
            if type == "c" || type == "b" || type == "p" || type == "s" { continue }
            if type == "l", let arrow = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }

            entries.append(FileEntry(
                path: RemotePath.join(directory, name),
                name: name,
                isDirectory: type == "d",
                size: Int64(sizeText) ?? 0,
                modified: lsDate.date(from: day + " " + time)
            ))
        }
        return entries
    }

    /// Free bytes from `df -k <path>` output.
    static func freeBytes(fromDf text: String) -> Int64? {
        let lines = text.split(whereSeparator: { $0.isNewline })
        guard lines.count >= 2 else { return nil }
        let tokens = lines.dropFirst()
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        // ... <1K-blocks> <Used> <Available> <Use%> <Mounted on>
        guard tokens.count >= 6, let kb = Int64(tokens[tokens.count - 3]) else { return nil }
        return kb * 1024
    }

    /// Turns raw adb / toybox error text into something readable.
    static func friendlyError(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Something went wrong." }
        let lower = trimmed.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return "Android doesn't allow access to this location."
        }
        if lower.contains("no space left") {
            return "The destination is full."
        }
        if lower.contains("no such file") || lower.contains("does not exist") {
            return "That file or folder no longer exists."
        }
        if lower.contains("device offline") || lower.contains("no devices") || lower.contains("not found") && lower.contains("device") {
            return "The phone disconnected."
        }
        if lower.contains("unauthorized") {
            return "Tap Allow on your phone to authorise this Mac."
        }
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? trimmed
        for prefix in ["adb: error: ", "adb: ", "error: "] where firstLine.hasPrefix(prefix) {
            return String(firstLine.dropFirst(prefix.count))
        }
        return firstLine
    }
}
