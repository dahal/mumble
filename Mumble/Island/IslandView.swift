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
        case .hidden: false
        }
    }

    private var size: CGSize {
        guard expanded else { return hasNotch ? notch : CGSize(width: 120, height: 0) }
        let width: CGFloat = showsText ? 440 : max(notch.width + 120, 260)
        let topInset = hasNotch ? notch.height : 0
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                leadingIcon
                Spacer(minLength: 8)
                trailingStatus
            }
            .frame(height: 40)
            if showsText {
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
        case .listening:
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
        case .hidden:
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
