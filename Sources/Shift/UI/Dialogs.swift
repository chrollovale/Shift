import SwiftUI

/// Chooses the right sheet for whatever the model asked for.
@MainActor
struct DialogHost: View {
    @EnvironmentObject var model: AppModel
    let dialog: Dialog

    var body: some View {
        switch dialog {
        case .newFolder(let pane):
            NameDialog(
                title: "NEW FOLDER",
                message: pane == .mac ? "Name the new folder on your Mac." : "Name the new folder on your phone.",
                initial: "untitled folder",
                confirm: "CREATE"
            ) { name in
                model.createFolder(in: pane, name: name)
            }

        case .rename(let entry):
            NameDialog(
                title: "RENAME",
                message: "Choose a new name for “" + entry.name + "”.",
                initial: entry.name,
                confirm: "RENAME"
            ) { name in
                model.renameOnPhone(entry, to: name)
            }

        case .deletePhone(let items):
            ConfirmDialog(
                title: "DELETE FROM PHONE",
                message: Self.describe(items, verb: "Delete", place: "from your phone") + " This can't be undone.",
                confirm: "DELETE",
                destructive: true
            ) {
                model.deleteFromPhone(items)
            }

        case .trashMac(let items):
            ConfirmDialog(
                title: "MOVE TO TRASH",
                message: Self.describe(items, verb: "Move", place: "to the Trash") + " You can put them back from the Trash.",
                confirm: "MOVE TO TRASH",
                destructive: false
            ) {
                model.trashOnMac(items)
            }

        case .conflict(let prompt):
            ConflictDialog(prompt: prompt)

        case .wireless:
            WirelessDialog()
        }
    }

    private static func describe(_ items: [FileEntry], verb: String, place: String) -> String {
        if items.count == 1 { return verb + " “" + items[0].name + "” " + place + "?" }
        return verb + " " + String(items.count) + " items " + place + "?"
    }
}

// MARK: - Shared frame

@MainActor
struct DialogFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StripeFill()
                Text(title)
                    .font(Fonts.pixel(9, bold: true))
                    .tracking(1.5)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                StripeFill()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.paperAlt)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.ink).frame(height: 1.5)
            }

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(18)
        }
        .frame(width: 400)
        .retroBox(radius: 10, shadow: 5)
        .padding(.leading, 20)
        .padding(.trailing, 25)
        .padding(.top, 20)
        .padding(.bottom, 25)
        .background(DeskBackground())
    }
}

private struct DialogText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.body(12))
            .foregroundColor(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Name prompt

@MainActor
struct NameDialog: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let message: String
    let confirm: String
    let onSubmit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, message: String, initial: String, confirm: String, onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.confirm = confirm
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    var body: some View {
        DialogFrame(title: title) {
            DialogText(text: message)
            TextField("", text: $text)
                .retroField()
                .focused($focused)
                .onSubmit { submit() }
            HStack(spacing: 10) {
                Spacer()
                Button("CANCEL") { model.dialog = nil }
                    .buttonStyle(KeyButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirm) { submit() }
                    .buttonStyle(KeyButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let name = text
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.dialog = nil
        onSubmit(name)
    }
}

// MARK: - Confirmation

@MainActor
struct ConfirmDialog: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let message: String
    let confirm: String
    let destructive: Bool
    let onConfirm: () -> Void

    var body: some View {
        DialogFrame(title: title) {
            DialogText(text: message)
            HStack(spacing: 10) {
                Spacer()
                Button("CANCEL") { model.dialog = nil }
                    .buttonStyle(KeyButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirm) {
                    model.dialog = nil
                    onConfirm()
                }
                .buttonStyle(KeyButtonStyle(kind: destructive ? .danger : .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Name clashes

@MainActor
struct ConflictDialog: View {
    @EnvironmentObject var model: AppModel
    let prompt: ConflictPrompt

    private var summary: String {
        let shown = prompt.clashes.prefix(4).map { "• " + $0 }.joined(separator: "\n")
        let extra = prompt.clashes.count - 4
        let tail = extra > 0 ? "\nand \(extra) more" : ""
        let place = prompt.direction == .toMac ? "on your Mac" : "on your phone"
        return "These already exist " + place + ":\n" + shown + tail
    }

    var body: some View {
        DialogFrame(title: "ALREADY THERE") {
            DialogText(text: summary)
            DialogText(text: "Replace them with the new copies, or skip the ones that exist?")
            HStack(spacing: 10) {
                Button("CANCEL") { model.dialog = nil }
                    .buttonStyle(KeyButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("SKIP") { model.resolveConflict(prompt, replace: false) }
                    .buttonStyle(KeyButtonStyle())
                Button("REPLACE") { model.resolveConflict(prompt, replace: true) }
                    .buttonStyle(KeyButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Wi-Fi

@MainActor
struct WirelessDialog: View {
    @EnvironmentObject var model: AppModel
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var connectAddress = ""

    var body: some View {
        DialogFrame(title: "CONNECT OVER WI-FI") {
            DialogText(text: "Needs Android 11 or newer. On the phone: Settings › System › Developer options › Wireless debugging. Keep the phone and this Mac on the same Wi-Fi.")

            VStack(alignment: .leading, spacing: 8) {
                label("1  PAIR ONCE")
                DialogText(text: "Tap “Pair device with pairing code” on the phone, then type what it shows.")
                TextField("Pairing address, e.g. 192.168.1.20:37099", text: $pairAddress).retroField()
                HStack(spacing: 10) {
                    TextField("Pairing code", text: $pairCode).retroField()
                    Button("PAIR") { model.pairDevice(address: pairAddress, code: pairCode) }
                        .buttonStyle(KeyButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                label("2  CONNECT")
                DialogText(text: "Use the IP address and port shown on the main Wireless debugging screen.")
                HStack(spacing: 10) {
                    TextField("Address, e.g. 192.168.1.20:41233", text: $connectAddress).retroField()
                    Button("CONNECT") { model.connectDevice(address: connectAddress) }
                        .buttonStyle(KeyButtonStyle(kind: .primary))
                }
            }

            HStack {
                Spacer()
                Button("DONE") { model.dialog = nil }
                    .buttonStyle(KeyButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Fonts.pixel(9, bold: true))
            .tracking(1)
            .foregroundColor(Palette.ink)
    }
}
