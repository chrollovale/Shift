import SwiftUI

// MARK: - First run: get adb

@MainActor
struct ToolsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack {
            Spacer()
            card
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var card: some View {
        VStack(spacing: 16) {
            LogoMark().frame(width: 72, height: 72)
            Text("ONE QUICK SETUP")
                .font(Fonts.pixel(15, bold: true))
                .tracking(2)
                .foregroundColor(Palette.ink)
            Text("Shift talks to your phone through Google's Android Platform Tools (adb). Download them once, about 12 MB, and you're done. There is nothing else to install.")
                .font(Fonts.body(12))
                .foregroundColor(Palette.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340)

            if let problem = model.toolsError {
                Text(problem)
                    .font(Fonts.body(11))
                    .foregroundColor(Palette.bad)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 340)
            }

            switch model.stage {
            case .installing:
                VStack(spacing: 8) {
                    RetroProgress(fraction: nil, height: 14).frame(width: 280)
                    Text(model.installMessage.uppercased())
                        .font(Fonts.pixel(8))
                        .foregroundColor(Palette.inkSoft)
                }
            case .checking:
                Text("LOOKING FOR ADB…")
                    .font(Fonts.pixel(8))
                    .foregroundColor(Palette.inkSoft)
            default:
                HStack(spacing: 12) {
                    Button("DOWNLOAD TOOLS") { model.installTools() }
                        .buttonStyle(KeyButtonStyle(kind: .primary))
                    Button("USE MY OWN ADB…") { model.chooseAdbManually() }
                        .buttonStyle(KeyButtonStyle())
                }
            }
        }
        .padding(30)
        .frame(width: 460)
        .retroBox(radius: 10, shadow: 6)
    }
}

// MARK: - Waiting for a phone

@MainActor
struct ConnectView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack {
            Spacer()
            card
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var waiting: (text: String, warning: Bool) {
        if model.devices.contains(where: { $0.state == .unauthorized }) {
            return ("UNLOCK YOUR PHONE AND TAP ALLOW", true)
        }
        if model.devices.contains(where: { $0.state == .offline }) {
            return ("PHONE IS OFFLINE. RECONNECT THE CABLE", true)
        }
        if model.devices.contains(where: { $0.state == .unknown }) {
            return ("PHONE FOUND, BUT ADB CAN'T USE IT YET", true)
        }
        return ("WAITING FOR YOUR PHONE…", false)
    }

    private var card: some View {
        VStack(spacing: 18) {
            LogoMark().frame(width: 72, height: 72)
            Text("CONNECT YOUR PHONE")
                .font(Fonts.pixel(15, bold: true))
                .tracking(2)
                .foregroundColor(Palette.ink)

            VStack(alignment: .leading, spacing: 11) {
                StepRow(number: 1, text: "Plug your phone into this Mac with a USB cable.")
                StepRow(number: 2, text: "On the phone, open Settings › About phone and tap Build number 7 times.")
                StepRow(number: 3, text: "Open Settings › System › Developer options and turn on USB debugging.")
                StepRow(number: 4, text: "Tap Allow on the “Allow USB debugging?” prompt.")
            }
            .frame(width: 400, alignment: .leading)

            VStack(spacing: 8) {
                RetroProgress(fraction: waiting.warning ? 0 : nil, height: 12).frame(width: 280)
                Text(waiting.text)
                    .font(Fonts.pixel(8, bold: true))
                    .foregroundColor(waiting.warning ? Palette.bad : Palette.inkSoft)
            }

            Button("CONNECT OVER WI-FI…") { model.dialog = .wireless }
                .buttonStyle(KeyButtonStyle(compact: true))
        }
        .padding(30)
        .frame(width: 500)
        .retroBox(radius: 10, shadow: 6)
    }
}

struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Fonts.pixel(10, bold: true))
                .foregroundColor(Palette.onAccent)
                .frame(width: 22, height: 22)
                .background(Palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.ink, lineWidth: 1.5))
            Text(text)
                .font(Fonts.body(12))
                .foregroundColor(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }
}
