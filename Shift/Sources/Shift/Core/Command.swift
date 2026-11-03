import Foundation

struct CommandOutput {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }
}

/// A single external process whose output is captured, and which can be cancelled.
final class Command {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var launched = false
    private var cancelRequested = false
    private var errData = Data()

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        process.environment = env
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let isLaunched = launched
        lock.unlock()
        if isLaunched && process.isRunning {
            process.terminate()
        }
    }

    func run() async -> CommandOutput {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandOutput, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                let skip = self.cancelRequested
                self.lock.unlock()
                if skip {
                    continuation.resume(returning: CommandOutput(status: -2, stdout: "", stderr: "cancelled"))
                    return
                }

                do {
                    try self.process.run()
                } catch {
                    continuation.resume(returning: CommandOutput(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                self.lock.lock()
                self.launched = true
                let late = self.cancelRequested
                self.lock.unlock()
                if late { self.process.terminate() }

                // Drain stderr on its own thread so neither pipe can fill up and stall the process.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = self.errPipe.fileHandleForReading.readDataToEndOfFile()
                    self.lock.lock()
                    self.errData = data
                    self.lock.unlock()
                    group.leave()
                }
                let outData = self.outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                self.process.waitUntilExit()

                self.lock.lock()
                let errBytes = self.errData
                self.lock.unlock()

                continuation.resume(returning: CommandOutput(
                    status: self.process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBytes, as: UTF8.self)
                ))
            }
        }
    }
}
