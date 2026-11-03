import SwiftUI
import AppKit

@MainActor
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .ignoresSafeArea(edges: .top)
        .background(DeskBackground().ignoresSafeArea())
        .background(WindowConfigurator())
        .overlay(alignment: .bottom) {
            ToastView()
                .padding(.bottom, 44)
        }
        .sheet(item: $model.dialog) { dialog in
            DialogHost(dialog: dialog)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .checking, .needsTools, .installing:
            ToolsView()
        case .ready:
            if model.isConnected {
                Workspace()
            } else {
                ConnectView()
            }
        }
    }
}

// MARK: - Title bar

@MainActor
struct TitleBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 70, height: 1)   // room for the traffic lights
            StripeFill()
            HStack(spacing: 8) {
                LogoMark().frame(width: 18, height: 18)
                Text("SHIFT")
                    .font(Fonts.pixel(12, bold: true))
                    .tracking(2.5)
                    .foregroundColor(Palette.ink)
            }
            .fixedSize()
            StripeFill()
            if model.stage == .ready {
                DeviceMenu()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Palette.paperAlt)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ink).frame(height: 1.5)
        }
    }
}

@MainActor
struct DeviceMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            if model.devices.isEmpty {
                Text("No devices found")
            }
            ForEach(model.devices) { device in
                Button {
                    model.selectDevice(device.serial)
                } label: {
                    Text(menuTitle(for: device))
                }
            }
            Divider()
            Button("Connect over Wi-Fi…") { model.dialog = .wireless }
            if model.activeDevice?.isWireless == true {
                Button("Disconnect Wi-Fi Device") { model.disconnectWireless() }
            }
            Divider()
            Button("Refresh") { model.refreshAll() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isConnected ? Palette.good : Palette.accent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Palette.ink, lineWidth: 1))
                Text((model.activeDevice?.name ?? "No phone").uppercased())
                    .font(Fonts.pixel(9, bold: true))
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Palette.ink)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .retroBox(radius: 5, shadow: 0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func menuTitle(for device: Device) -> String {
        var title = (device.serial == model.selectedSerial ? "✓  " : "") + device.name
        switch device.state {
        case .ready: break
        case .unauthorized: title += "  (waiting for Allow)"
        case .offline: title += "  (offline)"
        case .unknown: title += "  (unavailable)"
        }
        return title
    }
}

// MARK: - Status bar and toast

@MainActor
struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.status.uppercased())
                .font(Fonts.pixel(8))
                .foregroundColor(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if model.isConnected {
                Text("⌘→ TO MAC   ⌘← TO PHONE")
                    .font(Fonts.pixel(8))
                    .foregroundColor(Palette.inkSoft)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Palette.paperAlt)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.ink).frame(height: 1.5)
        }
    }
}

@MainActor
struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(toast.text)
                    .font(Fonts.body(12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundColor(toast.isError ? Color.white : Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 480)
            .retroBox(radius: 7, shadow: 3, fill: toast.isError ? Palette.bad : Palette.paper)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
