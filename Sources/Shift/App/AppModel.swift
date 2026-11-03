import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type used to move items between Shift's two panes. Declared in Info.plist.
    static let shiftItems = UTType(exportedAs: "app.shift.mac.items", conformingTo: .data)
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: Setup / tools

    @Published var stage: Stage = .checking
    @Published var installMessage = ""
    @Published var toolsError: String?
    private(set) var service: AdbService?

    // MARK: Devices

    @Published var devices: [Device] = []
    @Published var selectedSerial: String?
    @Published var freeBytes: Int64?
    @Published var volumes: [String] = []
    private var connectedSerial: String?
    private var nameCache: [String: String] = [:]
    private var pollTask: Task<Void, Never>?

    var activeDevice: Device? { devices.first { $0.serial == selectedSerial } }
    var isConnected: Bool { activeDevice?.state == .ready }

    // MARK: Mac pane

    @Published var macURL: URL
    @Published var macEntries: [FileEntry] = []
    @Published var macSelection: Set<String> = []
    @Published var macError: String?
    @Published var macLoading = false
    @Published var macSort = SortSpec(key: .name, ascending: true) {
        didSet { macEntries = macEntries.ordered(by: macSort) }
    }
    private var macRequest = 0
    private var macAnchor: String?

    // MARK: Phone pane

    static let phoneHome = "/sdcard"
    @Published var phonePath = AppModel.phoneHome
    @Published var phoneEntries: [FileEntry] = []
    @Published var phoneSelection: Set<String> = []
    @Published var phoneError: String?
    @Published var phoneLoading = false
    @Published var phoneSort = SortSpec(key: .name, ascending: true) {
        didSet { phoneEntries = phoneEntries.ordered(by: phoneSort) }
    }
    private var phoneRequest = 0
    private var phoneAnchor: String?

    // MARK: Shared UI state

    @Published var showHidden = false {
        didSet {
            refreshMac()
            refreshPhone()
        }
    }
    @Published var jobs: [TransferJob] = []
    @Published var status = "Welcome to Shift."
    @Published var toast: Toast?
    @Published var dialog: Dialog?

    private var queueRunning = false
    private var pendingItems: [FileEntry] = []
    private var pendingDirection: Direction = .toPhone
    private var pendingDestination = ""
    private var pendingTask: Task<Void, Never>?

    // MARK: Lifecycle

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        macURL = FileManager.default.fileExists(atPath: downloads.path) ? downloads : home
        Task { await bootstrap() }
    }

    static let platformToolsURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shift", isDirectory: true)
    }

    static func locateAdb() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: "customAdbPath") { candidates.append(custom) }
        candidates.append(supportDirectory.appendingPathComponent("platform-tools/adb").path)
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        let env = ProcessInfo.processInfo.environment
        if let sdk = env["ANDROID_HOME"] { candidates.append(sdk + "/platform-tools/adb") }
        if let sdk = env["ANDROID_SDK_ROOT"] { candidates.append(sdk + "/platform-tools/adb") }
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        return URL(fileURLWithPath: found)
    }

    func bootstrap() async {
        stage = .checking
        if let url = Self.locateAdb() {
            await useAdb(url)
        } else {
            stage = .needsTools
        }
    }

    private func useAdb(_ url: URL) async {
        let svc = AdbService(adb: url)
        await svc.startServer()
        guard await svc.version() != nil else {
            toolsError = "That copy of adb didn't start. If you're on Apple Silicon, make sure Rosetta is installed, or pick another adb."
            stage = .needsTools
            return
        }
        toolsError = nil
        service = svc
        stage = .ready
        status = "Looking for your phone…"
        refreshMac()
        startPolling()
    }

    func installTools() {
        guard stage != .installing else { return }
        stage = .installing
        toolsError = nil
        Task {
            do {
                installMessage = "Downloading Android Platform Tools…"
                let (tempFile, response) = try await URLSession.shared.download(from: Self.platformToolsURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw AdbError(message: "Google's download server answered with error \(http.statusCode).")
                }

                installMessage = "Unpacking…"
                let fm = FileManager.default
                let destination = Self.supportDirectory
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let unpacked = destination.appendingPathComponent("platform-tools", isDirectory: true)
                try? fm.removeItem(at: unpacked)

                // Move the download somewhere we own right away; the system may clean its temp file.
                let zipURL = destination.appendingPathComponent("platform-tools.zip")
                try? fm.removeItem(at: zipURL)
                try fm.moveItem(at: tempFile, to: zipURL)

                let unzip = Command(
                    executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                    arguments: ["-o", "-q", zipURL.path, "-d", destination.path]
                )
                let result = await unzip.run()
                try? fm.removeItem(at: zipURL)
                guard result.succeeded else { throw AdbError(message: "Couldn't unpack the download.") }

                let adbPath = unpacked.appendingPathComponent("adb").path
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbPath)
                _ = await Command(
                    executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                    arguments: ["-dr", "com.apple.quarantine", unpacked.path]
                ).run()

                installMessage = "Starting up…"
                guard let adb = Self.locateAdb() else { throw AdbError(message: "adb wasn't found after unpacking.") }
                await useAdb(adb)
            } catch {
                toolsError = error.localizedDescription
                stage = .needsTools
            }
        }
    }

    func chooseAdbManually() {
        let panel = NSOpenPanel()
        panel.title = "Choose the adb executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "customAdbPath")
            Task { await bootstrap() }
        }
    }

    // MARK: Device polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refreshDevices() async {
        guard let service = service else { return }
        var found = await service.devices()
        for index in found.indices where found[index].state == .ready {
            let serial = found[index].serial
            if let cached = nameCache[serial] {
                found[index].name = cached
            } else {
                let resolved = await service.deviceName(serial: serial, fallback: found[index].name)
                nameCache[serial] = resolved
                found[index].name = resolved
            }
        }
        if found != devices { devices = found }

        if let selected = selectedSerial, found.contains(where: { $0.serial == selected }) {
            // keep the current choice
        } else {
            selectedSerial = found.first(where: { $0.state == .ready })?.serial ?? found.first?.serial
        }

        let nowConnected: String? = (activeDevice?.state == .ready) ? activeDevice?.serial : nil
        if nowConnected != connectedSerial {
            connectedSerial = nowConnected
            deviceChanged()
        }
    }

    func selectDevice(_ serial: String) {
        selectedSerial = serial
        let nowConnected: String? = (activeDevice?.state == .ready) ? serial : nil
        if nowConnected != connectedSerial {
            connectedSerial = nowConnected
            deviceChanged()
        }
    }

    private func deviceChanged() {
        phoneSelection = []
        phoneEntries = []
        phoneError = nil
        phonePath = Self.phoneHome
        volumes = []
        freeBytes = nil
        if let device = activeDevice, device.state == .ready {
            status = "Connected to \(device.name)."
            refreshPhone()
            Task {
                await loadVolumes()
                await updateFreeSpace()
            }
        } else {
            status = devices.isEmpty ? "Waiting for a phone…" : "Check your phone."
        }
    }

    private func loadVolumes() async {
        guard let service = service, let serial = connectedSerial else { return }
        volumes = await service.removableVolumes(serial: serial)
    }

    func updateFreeSpace() async {
        guard let service = service, let serial = connectedSerial else { return }
        freeBytes = await service.freeSpace(serial: serial)
    }

    // MARK: Listing

    func refreshAll() {
        refreshMac()
        refreshPhone()
        Task {
            await refreshDevices()
            await updateFreeSpace()
        }
    }

    func refreshMac() {
        macRequest += 1
        let token = macRequest
        let url = macURL
        let hidden = showHidden
        macLoading = true
        Task {
            let result = await Task.detached { () -> Result<[FileEntry], Error> in
                Result { try LocalFS.list(url, showHidden: hidden) }
            }.value
            guard token == macRequest else { return }
            macLoading = false
            switch result {
            case .success(let list):
                macEntries = list.ordered(by: macSort)
                macError = nil
                let ids = Set(list.map { $0.id })
                macSelection = macSelection.intersection(ids)
            case .failure:
                macEntries = []
                macSelection = []
                macError = "macOS didn't let Shift open this folder. You can allow it in System Settings › Privacy & Security › Files and Folders."
            }
        }
    }

    func refreshPhone() {
        phoneRequest += 1
        let token = phoneRequest
        guard let service = service, let serial = connectedSerial else {
            phoneEntries = []
            phoneLoading = false
            return
        }
        let path = phonePath
        let hidden = showHidden
        phoneLoading = true
        Task {
            do {
                let list = try await service.list(serial: serial, directory: path)
                guard token == phoneRequest else { return }
                let visible = hidden ? list : list.filter { !$0.name.hasPrefix(".") }
                phoneEntries = visible.ordered(by: phoneSort)
                phoneError = nil
                phoneSelection = phoneSelection.intersection(Set(visible.map { $0.id }))
            } catch {
                guard token == phoneRequest else { return }
                phoneEntries = []
                phoneSelection = []
                phoneError = error.localizedDescription
            }
            if token == phoneRequest { phoneLoading = false }
        }
    }

    // MARK: Navigation

    var macPlaces: [Place] {
        let home = NSHomeDirectory()
        return [
            Place(id: home, title: "Home"),
            Place(id: home + "/Desktop", title: "Desktop"),
            Place(id: home + "/Documents", title: "Documents"),
            Place(id: home + "/Downloads", title: "Downloads"),
            Place(id: home + "/Pictures", title: "Pictures")
        ]
    }

    var phonePlaces: [Place] {
        var list = [
            Place(id: Self.phoneHome, title: "Internal"),
            Place(id: Self.phoneHome + "/DCIM", title: "DCIM"),
            Place(id: Self.phoneHome + "/Download", title: "Download"),
            Place(id: Self.phoneHome + "/Pictures", title: "Pictures"),
            Place(id: Self.phoneHome + "/Documents", title: "Documents"),
            Place(id: Self.phoneHome + "/Music", title: "Music"),
            Place(id: Self.phoneHome + "/Movies", title: "Movies")
        ]
        for (index, volume) in volumes.enumerated() {
            list.append(Place(id: volume, title: volumes.count > 1 ? "SD Card \(index + 1)" : "SD Card"))
        }
        return list
    }

    func navigate(_ pane: Pane, to path: String) {
        switch pane {
        case .mac:
            macURL = URL(fileURLWithPath: path, isDirectory: true)
            macSelection = []
            macAnchor = nil
            refreshMac()
        case .phone:
            phonePath = path
            phoneSelection = []
            phoneAnchor = nil
            refreshPhone()
        }
    }

    func canGoUp(_ pane: Pane) -> Bool {
        switch pane {
        case .mac: return macURL.path != "/"
        case .phone: return connectedSerial != nil && !([Self.phoneHome] + volumes).contains(phonePath)
        }
    }

    func goUp(_ pane: Pane) {
        guard canGoUp(pane) else { return }
        switch pane {
        case .mac: navigate(.mac, to: macURL.deletingLastPathComponent().path)
        case .phone: navigate(.phone, to: RemotePath.parent(of: phonePath))
        }
    }

    func open(_ entry: FileEntry, in pane: Pane) {
        if entry.isDirectory {
            navigate(pane, to: entry.path)
        } else if pane == .mac {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        } else {
            status = "Select it and press the → MAC key (⌘→) to copy it to your Mac."
        }
    }

    func toggleSort(_ pane: Pane, _ key: SortKey) {
        switch pane {
        case .mac:
            macSort = macSort.key == key ? SortSpec(key: key, ascending: !macSort.ascending) : SortSpec(key: key, ascending: true)
        case .phone:
            phoneSort = phoneSort.key == key ? SortSpec(key: key, ascending: !phoneSort.ascending) : SortSpec(key: key, ascending: true)
        }
    }

    // MARK: Selection

    func entries(for pane: Pane) -> [FileEntry] {
        pane == .mac ? macEntries : phoneEntries
    }

    func selection(for pane: Pane) -> Set<String> {
        pane == .mac ? macSelection : phoneSelection
    }

    private func setSelection(_ value: Set<String>, anchor: String?, for pane: Pane) {
        if pane == .mac {
            macSelection = value
            macAnchor = anchor
        } else {
            phoneSelection = value
            phoneAnchor = anchor
        }
    }

    func click(_ entry: FileEntry, in pane: Pane) {
        let flags = NSEvent.modifierFlags
        let list = entries(for: pane)
        var selected = selection(for: pane)
        let anchor = pane == .mac ? macAnchor : phoneAnchor

        if flags.contains(.shift),
           let anchorID = anchor,
           let a = list.firstIndex(where: { $0.id == anchorID }),
           let b = list.firstIndex(where: { $0.id == entry.id }) {
            selected = Set(list[min(a, b)...max(a, b)].map { $0.id })
            setSelection(selected, anchor: anchorID, for: pane)
        } else if flags.contains(.command) {
            if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
            setSelection(selected, anchor: entry.id, for: pane)
        } else {
            setSelection([entry.id], anchor: entry.id, for: pane)
        }
    }

    func clearSelection(_ pane: Pane) {
        setSelection([], anchor: nil, for: pane)
    }

    func toggleSelectAll(_ pane: Pane) {
        let list = entries(for: pane)
        if selection(for: pane).count == list.count {
            clearSelection(pane)
        } else {
            setSelection(Set(list.map { $0.id }), anchor: nil, for: pane)
        }
    }

    func targets(for entry: FileEntry, in pane: Pane) -> [FileEntry] {
        if selection(for: pane).contains(entry.id) {
            let selected = selection(for: pane)
            return entries(for: pane).filter { selected.contains($0.id) }
        }
        return [entry]
    }

    // MARK: Sending

    func sendSelection(_ direction: Direction) {
        let items: [FileEntry]
        switch direction {
        case .toPhone: items = macEntries.filter { macSelection.contains($0.id) }
        case .toMac: items = phoneEntries.filter { phoneSelection.contains($0.id) }
        }
        send(items, direction)
    }

    func send(_ items: [FileEntry], _ direction: Direction) {
        guard !items.isEmpty else { return }
        guard isConnected else {
            flash("Connect your phone first.", isError: true)
            return
        }
        switch direction {
        case .toPhone: begin(items, direction: .toPhone, destination: phonePath)
        case .toMac: begin(items, direction: .toMac, destination: macURL.path)
        }
    }

    private func begin(_ items: [FileEntry], direction: Direction, destination: String) {
        guard !items.isEmpty else { return }
        let clashes: [String]
        switch direction {
        case .toMac:
            clashes = items.filter {
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).appendingPathComponent($0.name).path)
            }.map { $0.name }
        case .toPhone:
            let existing = Set(phoneEntries.map { $0.name })
            clashes = destination == phonePath ? items.filter { existing.contains($0.name) }.map { $0.name } : []
        }
        if clashes.isEmpty {
            enqueue(items, direction: direction, destination: destination)
        } else {
            dialog = .conflict(ConflictPrompt(items: items, direction: direction, destination: destination, clashes: clashes))
        }
    }

    func resolveConflict(_ prompt: ConflictPrompt, replace: Bool) {
        dialog = nil
        let items = replace ? prompt.items : prompt.items.filter { !prompt.clashes.contains($0.name) }
        enqueue(items, direction: prompt.direction, destination: prompt.destination)
    }

    private func enqueue(_ items: [FileEntry], direction: Direction, destination: String) {
        guard !items.isEmpty else { return }
        for item in items {
            jobs.append(TransferJob(entry: item, direction: direction, destinationDir: destination))
        }
        Task { await runQueue() }
    }

    private func runQueue() async {
        guard !queueRunning else { return }
        queueRunning = true
        var moved = 0
        while let job = jobs.first(where: { $0.state == .queued }) {
            await execute(job)
            if job.state == .done { moved += 1 }
        }
        queueRunning = false

        if moved > 0 {
            flash(moved == 1 ? "Moved 1 item." : "Moved \(moved) items.")
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        refreshMac()
        refreshPhone()
        await updateFreeSpace()
    }

    private func execute(_ job: TransferJob) async {
        if job.cancelRequested {
            job.state = .cancelled
            return
        }
        guard let service = service, let serial = connectedSerial else {
            job.state = .failed("The phone disconnected.")
            return
        }
        job.state = .running
        status = (job.direction == .toPhone ? "Sending " : "Receiving ") + job.name + "…"

        if job.direction == .toPhone && job.isDirectory && job.totalBytes == nil {
            let source = job.sourcePath
            job.totalBytes = await Task.detached { LocalFS.directorySize(URL(fileURLWithPath: source)) }.value
        }
        if job.cancelRequested {
            job.state = .cancelled
            return
        }

        let command: Command
        switch job.direction {
        case .toPhone:
            command = service.pushCommand(serial: serial, local: job.sourcePath, remoteDirectory: job.destinationDir)
        case .toMac:
            command = service.pullCommand(serial: serial, remote: job.sourcePath, localDirectory: job.destinationDir)
        }
        job.command = command
        if job.cancelRequested { command.cancel() }

        let watcher = Task { await self.watchProgress(job, serial: serial, service: service) }
        let output = await command.run()
        watcher.cancel()
        job.command = nil

        if command.cancelled {
            job.state = .cancelled
            return
        }
        if output.succeeded {
            if let total = job.totalBytes { job.doneBytes = total }
            job.speed = 0
            job.state = .done
            if job.direction == .toPhone && !job.isDirectory {
                await service.scanMedia(serial: serial, path: RemotePath.join(job.destinationDir, job.name))
            }
        } else {
            let text = output.stderr.isEmpty ? output.stdout : output.stderr
            job.state = .failed(AdbParse.friendlyError(text))
        }
    }

    /// Polls the destination while adb works, so the progress bar and speed readout are live.
    private func watchProgress(_ job: TransferJob, serial: String, service: AdbService) async {
        var lastBytes: Int64 = 0
        var lastTime = Date()
        var smoothed: Double = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { break }

            let bytes: Int64?
            switch job.direction {
            case .toMac:
                let local = URL(fileURLWithPath: job.destinationDir).appendingPathComponent(job.name).path
                bytes = await Task.detached { LocalFS.size(atPath: local) }.value
            case .toPhone:
                bytes = await service.remoteSize(
                    serial: serial,
                    path: RemotePath.join(job.destinationDir, job.name),
                    isDirectory: job.isDirectory
                )
            }
            guard let current = bytes else { continue }

            let now = Date()
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > 0 {
                let instant = Double(current - lastBytes) / elapsed
                smoothed = smoothed == 0 ? instant : smoothed * 0.6 + instant * 0.4
            }
            lastBytes = current
            lastTime = now
            job.doneBytes = current
            job.speed = max(0, smoothed)
        }
    }

    func cancel(_ job: TransferJob) {
        job.cancelRequested = true
        if job.state == .queued {
            job.state = .cancelled
        } else {
            job.command?.cancel()
        }
    }

    func dismiss(_ job: TransferJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    // MARK: Drag and drop

    /// What one drag carries between the two panes (only visible inside Shift).
    private struct DragPayload: Codable {
        let pane: String
        let paths: [String]
    }

    func dragProvider(for entry: FileEntry, in pane: Pane) -> NSItemProvider {
        let payload = DragPayload(
            pane: pane == .mac ? "mac" : "phone",
            paths: targets(for: entry, in: pane).map { $0.path }
        )
        let provider = NSItemProvider()
        // In-app drags carry the whole selection and never leak to Finder.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.shiftItems.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(try? JSONEncoder().encode(payload), nil)
            return nil
        }

        // Phone rows can also be dragged straight onto Finder: the file is pulled when it's dropped.
        if pane == .phone {
            let typeID: String
            if entry.isDirectory {
                typeID = UTType.folder.identifier
            } else {
                typeID = UTType(filenameExtension: entry.fileExtension)?.identifier ?? UTType.data.identifier
            }
            provider.suggestedName = entry.name
            provider.registerFileRepresentation(
                forTypeIdentifier: typeID,
                fileOptions: [],
                visibility: .all
            ) { [weak self] completion in
                let progress = Progress(totalUnitCount: 1)
                Task { @MainActor in
                    let url = await self?.pullForDrag(entry)
                    let failure: Error? = (url == nil) ? CocoaError(.fileReadUnknown) : nil
                    completion(url, false, failure)
                    progress.completedUnitCount = 1
                }
                return progress
            }
        }
        return provider
    }

    /// Pulls one item into a temporary folder so Finder can copy it from there.
    private func pullForDrag(_ entry: FileEntry) async -> URL? {
        guard let service = service, let serial = connectedSerial else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shift-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        status = "Fetching " + entry.name + " from your phone…"
        let output = await service.pullCommand(serial: serial, remote: entry.path, localDirectory: folder.path).run()
        let result = folder.appendingPathComponent(entry.name)
        if output.succeeded && FileManager.default.fileExists(atPath: result.path) {
            status = "Copied " + entry.name + "."
            return result
        }
        flash(AdbParse.friendlyError(output.stderr.isEmpty ? output.stdout : output.stderr), isError: true)
        return nil
    }

    /// Clears out leftovers from earlier drags. Called once at launch.
    nonisolated static func cleanTemporaryFolders() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let items = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.hasPrefix("Shift-") {
            try? fm.removeItem(at: url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider], onto pane: Pane) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.shiftItems.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.shiftItems.identifier) { data, _ in
                    guard let data = data,
                          let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else { return }
                    Task { @MainActor in self.receiveDrop(payload: payload, onto: pane) }
                }
            } else if pane == .phone && provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    Task { @MainActor in self.receiveDrop(files: [url]) }
                }
            }
        }
        return accepted
    }

    private func receiveDrop(files: [URL]) {
        guard isConnected else {
            flash("Connect your phone first.", isError: true)
            return
        }
        collect(files.map { LocalFS.entry(for: $0) }, direction: .toPhone, destination: phonePath)
    }

    private func receiveDrop(payload: DragPayload, onto pane: Pane) {
        guard isConnected else {
            flash("Connect your phone first.", isError: true)
            return
        }
        switch (payload.pane, pane) {
        case ("mac", .phone):
            let items = payload.paths.map { LocalFS.entry(for: URL(fileURLWithPath: $0)) }
            collect(items, direction: .toPhone, destination: phonePath)
        case ("phone", .mac):
            let items = payload.paths.compactMap { path in phoneEntries.first(where: { $0.path == path }) }
            collect(items, direction: .toMac, destination: macURL.path)
        default:
            break
        }
    }

    /// Several dropped files arrive one by one; gather them into a single batch.
    private func collect(_ items: [FileEntry], direction: Direction, destination: String) {
        pendingItems.append(contentsOf: items)
        pendingDirection = direction
        pendingDestination = destination
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self = self else { return }
            var seen = Set<String>()
            let batch = self.pendingItems.filter { seen.insert($0.path).inserted }
            self.pendingItems = []
            self.begin(batch, direction: self.pendingDirection, destination: self.pendingDestination)
        }
    }

    // MARK: File operations

    private func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\n") { return nil }
        return name
    }

    func createFolder(in pane: Pane, name raw: String) {
        guard let name = validName(raw) else {
            flash("That name won't work.", isError: true)
            return
        }
        switch pane {
        case .mac:
            do {
                try FileManager.default.createDirectory(
                    at: macURL.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: false
                )
                refreshMac()
            } catch {
                flash("Couldn't create the folder: \(error.localizedDescription)", isError: true)
            }
        case .phone:
            guard let service = service, let serial = connectedSerial else { return }
            let path = RemotePath.join(phonePath, name)
            Task {
                do {
                    try await service.makeDirectory(serial: serial, path: path)
                    refreshPhone()
                } catch {
                    flash(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func renameOnPhone(_ entry: FileEntry, to raw: String) {
        guard let name = validName(raw), let service = service, let serial = connectedSerial else {
            flash("That name won't work.", isError: true)
            return
        }
        let target = RemotePath.join(RemotePath.parent(of: entry.path), name)
        Task {
            do {
                try await service.rename(serial: serial, from: entry.path, to: target)
                refreshPhone()
            } catch {
                flash(error.localizedDescription, isError: true)
            }
        }
    }

    func deleteFromPhone(_ entries: [FileEntry]) {
        guard let service = service, let serial = connectedSerial else { return }
        Task {
            var failure: String?
            for entry in entries {
                do {
                    try await service.delete(serial: serial, path: entry.path)
                } catch {
                    failure = error.localizedDescription
                }
            }
            refreshPhone()
            await updateFreeSpace()
            if let failure = failure {
                flash(failure, isError: true)
            } else {
                flash(entries.count == 1 ? "Deleted 1 item from your phone." : "Deleted \(entries.count) items from your phone.")
            }
        }
    }

    func trashOnMac(_ entries: [FileEntry]) {
        var failed = 0
        for entry in entries {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            } catch {
                failed += 1
            }
        }
        refreshMac()
        if failed > 0 {
            flash("\(failed) item(s) couldn't be moved to the Trash.", isError: true)
        } else {
            flash(entries.count == 1 ? "Moved 1 item to the Trash." : "Moved \(entries.count) items to the Trash.")
        }
    }

    // MARK: Wi-Fi

    func pairDevice(address: String, code: String) {
        guard let service = service else { return }
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        guard !trimmedAddress.isEmpty, !trimmedCode.isEmpty else {
            flash("Enter the pairing address and code.", isError: true)
            return
        }
        Task {
            let out = await service.pair(address: trimmedAddress, code: trimmedCode)
            let text = (out.stdout + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = text.lowercased().contains("successfully")
            flash(text.isEmpty ? "The phone didn't answer." : text, isError: !ok)
        }
    }

    func connectDevice(address: String) {
        guard let service = service else { return }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            flash("Enter the phone's address, e.g. 192.168.1.20:5555.", isError: true)
            return
        }
        Task {
            let out = await service.connect(address: trimmed)
            let text = (out.stdout + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            let ok = lower.contains("connected to") || lower.contains("already connected")
            flash(text.isEmpty ? "The phone didn't answer." : text, isError: !ok)
            await refreshDevices()
        }
    }

    func disconnectWireless() {
        guard let service = service, let device = activeDevice, device.isWireless else { return }
        Task {
            await service.disconnect(serial: device.serial)
            await refreshDevices()
        }
    }

    // MARK: Feedback

    func flash(_ text: String, isError: Bool = false) {
        status = text
        let message = Toast(text: text, isError: isError)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toast?.id == message.id {
                withAnimation(.easeOut(duration: 0.25)) { toast = nil }
            }
        }
    }

    /// Short label for the phone pane header.
    var phoneTitle: String {
        guard let device = activeDevice else { return "PHONE" }
        var title = device.name.uppercased()
        if let free = freeBytes { title += "  ·  " + Fmt.bytes(free) + " FREE" }
        return title
    }
}
