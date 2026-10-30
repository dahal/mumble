import AppKit
import SwiftUI

/// The black pill that grows out of the notch. On screens without a notch it floats
/// just below the menu bar with fully rounded corners.
struct IslandView: View {
    let model: IslandModel
    let notch: CGSize
    let hasNotch: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { model.phase != .hidden }
    private var showsText: Bool {
        switch model.phase {
        case .listening: model.showPreview && !model.previewText.isEmpty
        case .finishing: model.showPreview && !model.previewText.isEmpty
        case .done, .notice: true
        case .meeting: model.showPreview && !model.previewText.isEmpty
        case .hidden, .suggest, .headsUp: false
        }
    }

    private var isPrompt: Bool {
        if case .suggest = model.phase { return true }
        if case .headsUp = model.phase { return true }
        return false
    }

    private var size: CGSize {
        guard expanded else { return hasNotch ? notch : CGSize(width: 120, height: 0) }
        let topInset = hasNotch ? notch.height : 0
        if isPrompt { return CGSize(width: 480, height: topInset + 44) }
        let width: CGFloat = showsText ? 440 : max(notch.width + 120, 260)
        return CGSize(width: width, height: topInset + (showsText ? 84 : 40))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if hasNotch {
                        IslandShape(topRadius: 8, bottomRadius: 22).fill(.black)
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black)
                    }
                }
                .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 12, y: 4)
                if expanded {
                    content
                        .padding(.top, hasNotch ? notch.height : 0)
                        .padding(.horizontal, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
            .frame(width: size.width, height: size.height)
            .padding(.top, hasNotch ? 0 : 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78), value: size)
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case let .suggest(title, bundleID):
            PromptRow(icon: AnyView(AppIconView(bundleID: bundleID)), title: title, detail: "Take notes?",
                      button: "Take Notes", shortcut: nil, showsDismiss: true,
                      onTake: model.onTakeNotes, onDismiss: model.onDismiss)
        case let .headsUp(title):
            PromptRow(icon: AnyView(Image(systemName: "calendar").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)),
                      title: title, detail: "in 1 min", button: "Take Notes", shortcut: "⌥⇧M", showsDismiss: false,
                      onTake: model.onTakeNotes, onDismiss: model.onDismiss)
        default:
            statusContent
        }
    }

    @ViewBuilder private var statusContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                leadingIcon
                Spacer(minLength: 8)
                trailingStatus
            }
            .frame(height: 40)
            if showsText, case .meeting = model.phase {
                (Text(model.meetingSpeaker.isEmpty ? "" : model.meetingSpeaker + "  ").foregroundStyle(.white)
                    + Text(model.previewText).foregroundStyle(.white.opacity(0.65)))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            } else if showsText {
                Text(displayText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textStyle)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
        }
    }

    private var displayText: String {
        switch model.phase {
        case let .done(text): text
        case let .notice(text): text
        default: model.previewText
        }
    }

    private var textStyle: Color {
        switch model.phase {
        case .listening: .white.opacity(0.65)
        case .notice: .orange
        default: .white
        }
    }

    @ViewBuilder private var leadingIcon: some View {
        switch model.phase {
        case .listening, .meeting:
            WaveformBars(levels: model.levels)
        case .finishing:
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.bounce, value: model.phase)
        case .notice:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16, weight: .semibold))
        case .hidden, .suggest, .headsUp:
            EmptyView()
        }
    }

    @ViewBuilder private var trailingStatus: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 6) {
                if model.isLatched {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
                Circle().fill(.red).frame(width: 7, height: 7)
                    .opacity(model.level > 0.15 ? 1 : 0.55)
                Text(Self.format(model.elapsed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .meeting:
            HStack(spacing: 6) {
                Text(model.flash ?? "Meeting notes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.flash == nil ? .white.opacity(0.6) : .orange)
                    .contentTransition(.opacity)
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(Self.format(model.elapsed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .done:
            Text("Inserted").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        default:
            EmptyView()
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One-row prompt in the island: icon, title, detail, a white capsule button and an optional ×.
struct PromptRow: View {
    let icon: AnyView
    let title: String
    let detail: String
    let button: String
    let shortcut: String?
    let showsDismiss: Bool
    let onTake: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onTake) {
                HStack(spacing: 6) {
                    Text(button).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    if let shortcut { Text(shortcut).font(.system(size: 12, weight: .medium)).foregroundStyle(.gray) }
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            if showsDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }
        }
        .frame(height: 44)
    }
}

/// The meeting app's icon on a small white tile.
struct AppIconView: View {
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "video.fill").font(.system(size: 13)).foregroundStyle(.white)
        }
    }
}

struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// Square-ish top corners that blend into the notch, generously rounded bottom corners.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2, rect.width / 2)
        let b = min(bottomRadius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.minY + t), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + t + b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.maxY - b), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
