import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Two panes, two keys

@MainActor
struct Workspace: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                BrowserPane(pane: .phone)
                CenterKeys()
                    .frame(width: 112)
                BrowserPane(pane: .mac)
            }
            if !model.jobs.isEmpty {
                TransferTray()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 22)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }
}

@MainActor
struct CenterKeys: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            SendKey(direction: .toMac, count: model.phoneSelection.count)
            SendKey(direction: .toPhone, count: model.macSelection.count)
            Spacer()
        }
    }
}

@MainActor
struct SendKey: View {
    @EnvironmentObject var model: AppModel
    let direction: Direction
    let count: Int

    var body: some View {
        Button {
            model.sendSelection(direction)
        } label: {
            VStack(spacing: 7) {
                ArrowGlyph(pointsRight: direction == .toMac)
                    .stroke(Palette.onAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 38, height: 14)
                Text(direction == .toMac ? "TO MAC" : "TO PHONE")
                    .font(Fonts.pixel(10, bold: true))
                Text(count == 0 ? "SELECT FILES" : (count == 1 ? "1 ITEM" : "\(count) ITEMS"))
                    .font(Fonts.pixel(7))
            }
            .frame(width: 86)
            .padding(.vertical, 8)
        }
        .buttonStyle(KeyButtonStyle(kind: .primary))
        .disabled(count == 0)
        .help(direction == .toMac ? "Copy the selected phone items to the Mac folder on the right" : "Copy the selected Mac items to the phone folder on the left")
    }
}

// MARK: - One pane (phone or Mac)

private struct Crumb: Identifiable {
    let title: String
    let path: String
    var id: String { path }
}

@MainActor
struct BrowserPane: View {
    @EnvironmentObject var model: AppModel
    let pane: Pane
    @State private var dropTargeted = false

    private var entries: [FileEntry] { model.entries(for: pane) }
    private var selection: Set<String> { model.selection(for: pane) }
    private var path: String { pane == .mac ? model.macURL.path : model.phonePath }
    private var errorText: String? { pane == .mac ? model.macError : model.phoneError }
    private var loading: Bool { pane == .mac ? model.macLoading : model.phoneLoading }
    private var sort: SortSpec { pane == .mac ? model.macSort : model.phoneSort }
    private var places: [Place] { pane == .mac ? model.macPlaces : model.phonePlaces }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            placesRow
            pathRow
            columnHeader
            listArea
            footer
        }
        .retroBox()
        .overlay(dropOverlay)
        .onDrop(
            of: pane == .phone ? [UTType.shiftItems, UTType.fileURL] : [UTType.shiftItems],
            isTargeted: $dropTargeted
        ) { providers in
            model.handleDrop(providers, onto: pane)
        }
    }

    // MARK: Pieces

    private var titleBar: some View {
        HStack(spacing: 8) {
            StripeFill()
            Text(pane == .phone ? model.phoneTitle : "THIS MAC")
                .font(Fonts.pixel(9, bold: true))
                .tracking(1.5)
                .foregroundColor(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            StripeFill()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Palette.paperAlt)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ink).frame(height: 1.5)
        }
    }

    private var placesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(places) { place in
                    Button(place.title.uppercased()) {
                        model.navigate(pane, to: place.path)
                    }
                    .buttonStyle(ChipStyle(active: path == place.path))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var pathRow: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp(pane)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 12)
            }
            .buttonStyle(KeyButtonStyle(compact: true))
            .disabled(!model.canGoUp(pane))
            .help("Up one folder")

            breadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.paper)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.ink, lineWidth: 1))

            if loading {
                RetroProgress(fraction: nil, height: 8).frame(width: 40)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var breadcrumbs: some View {
        let trail = crumbs
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Text("›")
                                .font(Fonts.body(12))
                                .foregroundColor(Palette.inkSoft)
                        }
                        Button(crumb.title) {
                            model.navigate(pane, to: crumb.path)
                        }
                        .buttonStyle(.plain)
                        .font(Fonts.body(12))
                        .foregroundColor(index == trail.count - 1 ? Palette.ink : Palette.inkSoft)
                        .lineLimit(1)
                    }
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
            }
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: path) { _ in proxy.scrollTo("end") }
        }
        .frame(height: 18)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 26, height: 1)
            headerButton("NAME", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerButton("SIZE", .size)
                .frame(width: 68, alignment: .trailing)
            headerButton("MODIFIED", .modified)
                .frame(width: 104, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.paperAlt)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: 1.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink).frame(height: 1.5) }
    }

    private func headerButton(_ title: String, _ key: SortKey) -> some View {
        let active = sort.key == key
        let arrow = active ? (sort.ascending ? " ▲" : " ▼") : ""
        return Button {
            model.toggleSort(pane, key)
        } label: {
            Text(title + arrow)
                .font(Fonts.pixel(8, bold: true))
                .foregroundColor(active ? Palette.ink : Palette.inkSoft)
        }
        .buttonStyle(.plain)
    }

    private var listArea: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        FileRow(
                            entry: entry,
                            pane: pane,
                            selected: selection.contains(entry.id),
                            shaded: index % 2 == 1
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection(pane) }
                )
            }
            .overlay(emptyState)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = errorText {
            stateMessage(symbol: "lock.fill", text: message)
        } else if entries.isEmpty && !loading {
            stateMessage(symbol: "tray", text: "EMPTY FOLDER")
        }
    }

    private func stateMessage(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
            Text(text)
                .font(text == "EMPTY FOLDER" ? Fonts.pixel(9, bold: true) : Fonts.body(12))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Palette.inkSoft)
        .frame(maxWidth: 280)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(Fonts.pixel(8))
                .foregroundColor(Palette.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("NEW FOLDER") {
                model.dialog = .newFolder(pane)
            }
            .buttonStyle(KeyButtonStyle(compact: true))
            Button(pane == .mac ? "TRASH" : "DELETE") {
                let items = entries.filter { selection.contains($0.id) }
                if pane == .mac {
                    model.dialog = .trashMac(items)
                } else {
                    model.dialog = .deletePhone(items)
                }
            }
            .buttonStyle(KeyButtonStyle(compact: true))
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Palette.paperAlt)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: 1.5) }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                .background(Palette.accent.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

    // MARK: Helpers

    private var footerText: String {
        let count = entries.count
        var text = "\(count) ITEM" + (count == 1 ? "" : "S")
        if !selection.isEmpty {
            text += "  ·  \(selection.count) SELECTED"
            let bytes = entries
                .filter { selection.contains($0.id) && !$0.isDirectory }
                .reduce(Int64(0)) { $0 + $1.size }
            if bytes > 0 { text += "  ·  " + Fmt.bytes(bytes).uppercased() }
        }
        return text
    }

    private var crumbs: [Crumb] {
        let base: Crumb
        if pane == .mac {
            let home = NSHomeDirectory()
            if path == home || path.hasPrefix(home + "/") {
                base = Crumb(title: "Home", path: home)
            } else {
                base = Crumb(title: "Mac", path: "/")
            }
        } else if let card = model.volumes.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            base = Crumb(title: model.phonePlaces.first(where: { $0.id == card })?.title ?? "SD Card", path: card)
        } else if path == model.phoneRoot || path.hasPrefix(model.phoneRoot + "/") {
            base = Crumb(title: model.phonePlaces.first?.title ?? "Internal", path: model.phoneRoot)
        } else {
            base = Crumb(title: "Phone", path: "/")
        }

        var result = [base]
        let prefix = base.path == "/" ? "/" : base.path + "/"
        guard path != base.path, path.hasPrefix(prefix) else { return result }
        var current = base.path
        for part in path.dropFirst(prefix.count).split(separator: "/") {
            current = RemotePath.join(current, String(part))
            result.append(Crumb(title: String(part), path: current))
        }
        return result
    }
}

// MARK: - A file row

@MainActor
struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let entry: FileEntry
    let pane: Pane
    let selected: Bool
    let shaded: Bool

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(entry: entry)
            Text(entry.name)
                .font(Fonts.body(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "—" : Fmt.bytes(entry.size))
                .font(Fonts.mono(10.5))
                .frame(width: 68, alignment: .trailing)
                .opacity(selected ? 1 : 0.7)
            Text(Fmt.date(entry.modified))
                .font(Fonts.mono(10.5))
                .frame(width: 104, alignment: .leading)
                .lineLimit(1)
                .opacity(selected ? 1 : 0.7)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .foregroundColor(selected ? Palette.paper : Palette.ink)
        .background(selected ? Palette.ink : (shaded ? Palette.zebra : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.click(entry, in: pane) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.open(entry, in: pane) })
        .onDrag { model.dragProvider(for: entry, in: pane) }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        let targets = model.targets(for: entry, in: pane)
        if pane == .phone {
            Button("Send to Mac") { model.send(targets, .toMac) }
            if targets.count == 1 {
                Button("Rename…") { model.dialog = .rename(entry) }
            }
            Divider()
            Button("Delete from Phone…") { model.dialog = .deletePhone(targets) }
        } else {
            Button("Send to Phone") { model.send(targets, .toPhone) }
            Button("Open") { model.open(entry, in: .mac) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
            }
            Divider()
            Button("Move to Trash…") { model.dialog = .trashMac(targets) }
        }
    }
}
