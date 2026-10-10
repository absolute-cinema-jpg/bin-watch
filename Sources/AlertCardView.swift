import SwiftUI

private let green = Color(red: 0.20, green: 0.78, blue: 0.47)
private let teal = Color(red: 0.07, green: 0.58, blue: 0.62)

/// One alert on its own, or several as a stack (newest on top, two more peeking out
/// beneath) that expands into a scrolling list. It never grows past 60% of the screen.
struct AlertStackView: View {
    static let cardWidth: CGFloat = 300
    static let margin: CGFloat = 22        // transparent room for the shadow
    static let headerHeight: CGFloat = 26
    static let spacing: CGFloat = 6
    static let gap: CGFloat = 8
    static let peek: CGFloat = 7

    static func height(of item: AlertItem) -> CGFloat {
        if case .request = item.kind { return 96 }
        return 64
    }

    @ObservedObject var model: AlertStackModel

    /// The panel size needed for the current state (used to size the floating window).
    static func size(for model: AlertStackModel) -> CGSize {
        let n = max(model.items.count, 1)
        let header = n > 1 ? headerHeight + spacing : 0
        let top = model.items.first.map(height(of:)) ?? 64
        let body = model.expanded ? listHeight(model.items, max: model.maxListHeight)
                                  : top + CGFloat(min(n - 1, 2)) * peek
        return CGSize(width: cardWidth + margin * 2, height: header + body + margin * 2)
    }

    private static func listHeight(_ items: [AlertItem], max: CGFloat) -> CGFloat {
        min(items.map(height(of:)).reduce(0, +) + CGFloat(Swift.max(items.count - 1, 0)) * gap, max)
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            if model.items.count > 1 { header }
            if model.expanded { expandedList } else { collapsedStack }
        }
        .frame(width: Self.cardWidth)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .padding(.leading, 10)
            Spacer()
            Button(model.expanded ? "Show less" : "Show all") {
                AlertCenter.shared.setExpanded(!model.expanded)
            }
            .buttonStyle(ChipButtonStyle())
            Button("Clear all") { AlertCenter.shared.acknowledgeAll() }
                .buttonStyle(ChipButtonStyle())
                .help("Put every alert away")
        }
        .padding(3)
        .frame(height: Self.headerHeight)
        .background(VisualEffectBackground(material: .popover).clipShape(Capsule()))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private var headerTitle: String {
        let bins = model.items.filter { $0.kind == .available }.count
        let others = model.items.count - bins
        if others == 0 { return "\(bins) bins available" }
        if bins == 0 { return "\(others) messages" }
        return "\(model.items.count) alerts"
    }

    private var collapsedStack: some View {
        let ghosts = min(model.items.count - 1, 2)
        let topHeight = model.items.first.map(Self.height(of:)) ?? 64
        return ZStack(alignment: .top) {
            ForEach((0..<max(ghosts, 0)).reversed(), id: \.self) { i in
                let depth = CGFloat(i + 1)
                CardBackground()
                    .frame(width: Self.cardWidth - depth * 18, height: topHeight)
                    .opacity(1 - Double(depth) * 0.25)
                    .offset(y: depth * Self.peek)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            if let top = model.items.first {
                AlertCard(item: top, model: model)
                    .id(top.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .frame(height: topHeight + CGFloat(max(ghosts, 0)) * Self.peek, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if model.items.count > 1 { AlertCenter.shared.setExpanded(true) } }
    }

    private var expandedList: some View {
        ScrollView(.vertical, showsIndicators: model.items.count > 6) {
            VStack(spacing: Self.gap) {
                ForEach(model.items) { item in
                    AlertCard(item: item, model: model)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.92))))
                }
            }
        }
        .frame(height: Self.listHeight(model.items, max: model.maxListHeight))
    }
}

/// A compact alert card: a bin that's free, someone asking for a bin, or a reply.
struct AlertCard: View {
    let item: AlertItem
    @ObservedObject var model: AlertStackModel

    @State private var appeared = false
    @State private var ring = false
    @State private var glow = false

    private var style: (label: String, symbol: String, colors: [Color]) {
        switch item.kind {
        case .available:
            return ("BIN AVAILABLE", "lock.open.fill", [green, teal])
        case .request:
            return ("BIN REQUEST", "hand.raised.fill", [Color(red: 0.55, green: 0.42, blue: 0.98), Color(red: 0.36, green: 0.30, blue: 0.85)])
        case .reply(let positive):
            return ("REPLY", positive ? "checkmark.bubble.fill" : "text.bubble.fill",
                    positive ? [Color(red: 0.25, green: 0.6, blue: 1), Color(red: 0.15, green: 0.42, blue: 0.9)]
                             : [Color(red: 0.98, green: 0.65, blue: 0.25), Color(red: 0.9, green: 0.45, blue: 0.15)])
        }
    }

    var body: some View {
        Group {
            if case .request(let everyone) = item.kind {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) { badge; texts(lines: 2) }
                    HStack(spacing: 8) {
                        Spacer().frame(width: 34)
                        Button("I'll close it") { AlertCenter.shared.respond(item.id, .primary) }
                            .buttonStyle(CardButtonStyle(fill: style.colors[0], foreground: .white))
                        Button(everyone ? "Not me" : "Not now") { AlertCenter.shared.respond(item.id, .secondary) }
                            .buttonStyle(CardButtonStyle(fill: Color.primary.opacity(0.12), foreground: .primary))
                    }
                }
            } else {
                HStack(spacing: 11) {
                    badge
                    texts(lines: 1)
                    Spacer(minLength: 4)
                    Button(item.kind == .available ? "Got it" : "OK") { AlertCenter.shared.acknowledge(item.id) }
                        .buttonStyle(CardButtonStyle(fill: style.colors[0], foreground: .white))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: AlertStackView.cardWidth, height: AlertStackView.height(of: item))
        .background(CardBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style.colors[0].opacity(glow ? 0.9 : 0), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .shadow(color: style.colors[0].opacity(glow ? 0.45 : 0), radius: 16)
        .help(item.detail.isEmpty ? item.title : "\(item.title)\n\(item.detail)")
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.12)) { appeared = true }
            ringOnce()
        }
        .onChange(of: model.pulse) { _ in
            ringOnce()
            withAnimation(.easeInOut(duration: 0.5)) { glow = true }
            withAnimation(.easeInOut(duration: 0.9).delay(0.6)) { glow = false }
        }
    }

    private func texts(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(style.label)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(style.colors[0])
                Text(item.time, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: lines > 1)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var badge: some View {
        ZStack {
            Circle()
                .stroke(style.colors[0].opacity(ring ? 0 : 0.6), lineWidth: 1.5)
                .scaleEffect(ring ? 1.7 : 1)
            Circle()
                .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: style.colors[0].opacity(0.45), radius: 4, y: 1)
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .scaleEffect(appeared ? 1 : 0.3)
                .rotationEffect(.degrees(appeared ? 0 : -25))
        }
        .frame(width: 34, height: 34)
    }

    private func ringOnce() {
        ring = false
        withAnimation(.easeOut(duration: 1.2).delay(0.2)) { ring = true }
    }
}

private struct CardBackground: View {
    var body: some View {
        VisualEffectBackground(material: .popover)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Fixed colours: the alert never takes focus from Avid, and standard buttons
/// would render grey in a window that isn't focused.
private struct CardButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.09), in: Capsule())
            .contentShape(Capsule())
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
