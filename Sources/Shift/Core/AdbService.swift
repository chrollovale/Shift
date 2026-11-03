import Foundation

struct AdbError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper around the `adb` command line tool.
struct AdbService {
    let adb: URL

    // MARK: Plumbing

    func command(_ arguments: [String]) -> Command {
        Command(executable: adb, arguments: arguments)
    }

    func run(_ arguments: [String]) async -> CommandOutput {
        await command(arguments).run()
    }

    func shell(_ serial: String, _ remoteCommand: String) async -> CommandOutput {
        await run(["-s", serial, "shell", remoteCommand])
    }

    private func message(from out: CommandOutput) -> String {
        AdbParse.friendlyError(out.stderr.isEmpty ? out.stdout : out.stderr)
    }

    // MARK: Server and devices

    func version() async -> String? {
        let out = await run(["version"])
        guard out.succeeded else { return nil }
        return out.stdout.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    func startServer() async {
        _ = await run(["start-server"])
    }

    func devices() async -> [Device] {
        let out = await run(["devices", "-l"])
        return AdbParse.devices(out.stdout)
    }

    /// "Google Pixel 8" style name for a connected phone.
    func deviceName(serial: String, fallback: String) async -> String {
        let out = await shell(serial, "getprop ro.product.manufacturer; getprop ro.product.model")
        let lines = out.stdout.split(whereSeparator: { $0.isNewline }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.count >= 2, !lines[1].isEmpty else { return fallback }
        let maker = lines[0]
        let model = lines[1]
        if maker.isEmpty || model.lowercased().hasPrefix(maker.lowercased()) { return model }
        let capitalized = maker.prefix(1).uppercased() + String(maker.dropFirst())
        return capitalized + " " + model
    }

    func freeSpace(serial: String) async -> Int64? {
        let out = await shell(serial, "df -k /sdcard")
        return AdbParse.freeBytes(fromDf: out.stdout)
    }

    /// SD cards show up as /storage/XXXX-XXXX.
    func removableVolumes(serial: String) async -> [String] {
        let out = await shell(serial, "ls -1 /storage")
        return out.stdout
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                name.range(of: #"^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$"#, options: .regularExpression) != nil
            }
            .map { "/storage/" + $0 }
    }

    // MARK: Browsing

    func list(serial: String, directory: String) async throws -> [FileEntry] {
        let out = await shell(serial, "ls -lAL " + AdbParse.quote(RemotePath.asDirectory(directory)))
        let entries = AdbParse.ls(out.stdout, in: directory)
        if entries.isEmpty {
            let text = out.stderr + out.stdout
            let lower = text.lowercased()
            if !out.succeeded || lower.contains("permission denied") || lower.contains("no such file") {
                throw AdbError(message: AdbParse.friendlyError(text))
            }
        }
        return entries
    }

    // MARK: Changing things on the phone

    func makeDirectory(serial: String, path: String) async throws {
        guard RemotePath.isSafeToModify(path) else { throw AdbError(message: "That location can't be changed from Shift.") }
        let out = await shell(serial, "mkdir -p " + AdbParse.quote(path))
        if !out.succeeded { throw AdbError(message: message(from: out)) }
    }

    func rename(serial: String, from: String, to: String) async throws {
        guard RemotePath.isSafeToModify(from), RemotePath.isSafeToModify(to) else {
            throw AdbError(message: "That location can't be changed from Shift.")
        }
        let out = await shell(serial, "mv " + AdbParse.quote(from) + " " + AdbParse.quote(to))
        if !out.succeeded { throw AdbError(message: message(from: out)) }
    }

    func delete(serial: String, path: String) async throws {
        guard RemotePath.isSafeToModify(path) else { throw AdbError(message: "That location can't be changed from Shift.") }
        let out = await shell(serial, "rm -rf " + AdbParse.quote(path))
        if !out.succeeded { throw AdbError(message: message(from: out)) }
    }

    // MARK: Transfers

    func pushCommand(serial: String, local: String, remoteDirectory: String) -> Command {
        command(["-s", serial, "push", local, RemotePath.asDirectory(remoteDirectory)])
    }

    func pullCommand(serial: String, remote: String, localDirectory: String) -> Command {
        command(["-s", serial, "pull", "-a", remote, localDirectory])
    }

    /// Current size of something on the phone — used to draw progress while a push runs.
    func remoteSize(serial: String, path: String, isDirectory: Bool) async -> Int64? {
        let remoteCommand = isDirectory ? "du -sk " + AdbParse.quote(path) : "stat -c %s " + AdbParse.quote(path)
        let out = await shell(serial, remoteCommand)
        guard let first = out.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).first,
              let value = Int64(first) else { return nil }
        return isDirectory ? value * 1024 : value
    }

    /// Best-effort: ask Android's media scanner to notice a freshly pushed file so it shows up in Gallery.
    func scanMedia(serial: String, path: String) async {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        let uri = "file://" + encoded
        _ = await shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d " + AdbParse.quote(uri))
    }

    // MARK: Wi-Fi

    func pair(address: String, code: String) async -> CommandOutput {
        await run(["pair", address, code])
    }

    func connect(address: String) async -> CommandOutput {
        await run(["connect", address])
    }

    func disconnect(serial: String) async {
        _ = await run(["disconnect", serial])
    }
}
