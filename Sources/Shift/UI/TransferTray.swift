import SwiftUI

@MainActor
struct TransferTray: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StripeFill()
                Text("TRANSFERS")
                    .font(Fonts.pixel(9, bold: true))
                    .tracking(1.5)
                    .foregroundColor(Palette.ink)
                StripeFill()
                if model.jobs.contains(where: { $0.isFinished }) {
                    Button("CLEAR DONE") { model.clearFinished() }
                        .buttonStyle(KeyButtonStyle(compact: true))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.paperAlt)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.ink).frame(height: 1.5)
            }

            rows
        }
        .retroBox()
    }

    @ViewBuilder
    private var rows: some View {
        if model.jobs.count <= 3 {
            VStack(spacing: 0) {
                ForEach(model.jobs) { job in
                    JobRow(job: job)
                }
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                    }
                }
            }
            .frame(height: 3 * JobRow.height)
        }
    }
}

@MainActor
struct JobRow: View {
    static let height: CGFloat = 52

    @ObservedObject var job: TransferJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(job.direction == .toMac ? "→ MAC" : "→ PHONE")
                .font(Fonts.pixel(8, bold: true))
                .foregroundColor(Palette.ink)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(job.name)
                    .font(Fonts.body(12))
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                RetroProgress(fraction: barFraction, height: 8)
                Text(detail)
                    .font(Fonts.pixel(7))
                    .foregroundColor(detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Button {
                if job.isFinished {
                    model.dismiss(job)
                } else {
                    model.cancel(job)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .frame(width: 10)
            }
            .buttonStyle(KeyButtonStyle(compact: true))
            .help(job.isFinished ? "Dismiss" : "Cancel this transfer")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ink.opacity(0.2)).frame(height: 1)
        }
    }

    /// nil draws the barber pole: running, but no size to measure against.
    private var barFraction: Double? {
        switch job.state {
        case .queued: return 0
        case .running: return job.fraction
        case .done: return 1
        case .failed, .cancelled: return job.fraction ?? 0
        }
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return "WAITING…"
        case .running:
            var text: String
            if let total = job.totalBytes, total > 0 {
                text = Fmt.bytes(job.doneBytes) + " OF " + Fmt.bytes(total)
            } else {
                text = Fmt.bytes(job.doneBytes) + " SO FAR"
            }
            if job.speed > 1 { text += "  ·  " + Fmt.speed(job.speed) }
            return text.uppercased()
        case .done:
            if let total = job.totalBytes, total > 0 { return "DONE  ·  " + Fmt.bytes(total).uppercased() }
            return "DONE"
        case .failed(let message):
            return message.uppercased()
        case .cancelled:
            return "CANCELLED"
        }
    }

    private var detailColor: Color {
        switch job.state {
        case .failed: return Palette.bad
        case .done: return Palette.good
        default: return Palette.inkSoft
        }
    }
}
