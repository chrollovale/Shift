import SwiftUI

enum Pane {
    case mac
    case phone
}

enum Direction {
    case toPhone
    case toMac
}

enum Stage: Equatable {
    case checking
    case needsTools
    case installing
    case ready
}

struct Place: Identifiable {
    let id: String          // the path
    let title: String
    var path: String { id }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let items: [FileEntry]
    let direction: Direction
    let destination: String
    let clashes: [String]
}

/// Everything the app can ask in a sheet.
enum Dialog: Identifiable {
    case newFolder(Pane)
    case rename(FileEntry)
    case deletePhone([FileEntry])
    case trashMac([FileEntry])
    case conflict(ConflictPrompt)
    case wireless

    var id: String {
        switch self {
        case .newFolder(let pane): return "newFolder-\(pane)"
        case .rename(let entry): return "rename-\(entry.path)"
        case .deletePhone: return "deletePhone"
        case .trashMac: return "trashMac"
        case .conflict(let prompt): return "conflict-\(prompt.id)"
        case .wireless: return "wireless"
        }
    }
}

/// One item travelling between Mac and phone.
final class TransferJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let name: String
    let direction: Direction
    let sourcePath: String
    let destinationDir: String
    let isDirectory: Bool

    @Published var totalBytes: Int64?
    @Published var doneBytes: Int64 = 0
    @Published var speed: Double = 0
    @Published var state: State = .queued

    var command: Command?
    var cancelRequested = false

    init(entry: FileEntry, direction: Direction, destinationDir: String) {
        self.name = entry.name
        self.direction = direction
        self.sourcePath = entry.path
        self.destinationDir = destinationDir
        self.isDirectory = entry.isDirectory
        // Folders get measured when their turn comes.
        self.totalBytes = entry.isDirectory ? nil : entry.size
    }

    var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(doneBytes) / Double(total))
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}
