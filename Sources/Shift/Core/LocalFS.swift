import Foundation

/// Small helpers for the Mac side of the browser.
enum LocalFS {
    static func entry(for url: URL) -> FileEntry {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        var isDirectory = values?.isDirectory ?? false
        if values?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        return FileEntry(
            path: url.path,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate
        )
    }

    static func list(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.map { entry(for: $0) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Size of a file, or the recursive size of a folder. Nil when nothing exists there yet.
    static func size(atPath path: String) -> Int64? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return directorySize(URL(fileURLWithPath: path)) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
