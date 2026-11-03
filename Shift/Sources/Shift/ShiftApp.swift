import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ShiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        FontLoader.registerBundled()
        AppModel.cleanTemporaryFolders()
    }

    var body: some Scene {
        WindowGroup("Shift") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Transfer") {
                Button("Send to Mac") { model.sendSelection(.toMac) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(model.dialog != nil)
                Button("Send to Phone") { model.sendSelection(.toPhone) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(model.dialog != nil)

                Divider()

                Button("Refresh") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("New Folder on Phone") { model.dialog = .newFolder(.phone) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isConnected)
                Button("New Folder on Mac") { model.dialog = .newFolder(.mac) }
                    .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                    .disabled(model.stage != .ready)

                Divider()

                Toggle("Show Hidden Files", isOn: $model.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Connect over Wi-Fi…") { model.dialog = .wireless }
                    .disabled(model.stage != .ready)
            }
        }
    }
}
