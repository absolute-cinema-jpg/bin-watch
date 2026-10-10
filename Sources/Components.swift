import SwiftUI

struct Header<Accessory: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

extension Header where Accessory == EmptyView {
    init(title: String, subtitle: String, symbol: String, tint: Color) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }
}

struct BinIcon: View {
    let state: BinState
    var body: some View {
        Image(systemName: state == .locked ? "lock.fill" : "rectangle.stack.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(state == .locked ? Color.orange : state == .available ? Color.green : Color.secondary)
            .frame(width: 28, height: 28)
            .background((state == .locked ? Color.orange : state == .available ? Color.green : Color.gray).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct StatePill: View {
    let state: BinState
    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(state.color)
            .background(state.color.opacity(0.14), in: Capsule())
    }
}
