import SwiftUI

struct AskTarget: Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let name: String
}

private let requestPurple = Color(red: 0.55, green: 0.42, blue: 0.98)

/// "Ask for this bin": choose who to ask (or everyone) and add an optional note.
struct AskSheet: View {
    let target: AskTarget
    @ObservedObject private var requests = RequestCenter.shared
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipient: UUID?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(requestPurple.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask for “\(target.name)”").font(.title3.weight(.semibold)).lineLimit(2)
                    Text(displayPath((target.relativePath as NSString).deletingLastPathComponent, root: store.rootName))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            if requests.isSetUp { form } else { setUp }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bin Watch will ask them to close the bin, and alert you the moment it's free.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Ask", selection: $recipient) {
                Text("Everyone using Bin Watch").tag(UUID?.none)
                if !requests.people.isEmpty { Divider() }
                ForEach(requests.people) { status in
                    Text("\(status.person.name) — \(status.person.computer)\(status.isOnline ? "" : " (away)")")
                        .tag(Optional(status.id))
                }
            }

            TextField("Add a note (optional), e.g. “Need it for the trailer”", text: $note)
                .textFieldStyle(.roundedBorder)

            if requests.people.isEmpty {
                Label("Nobody else has joined this mailbox yet. Your request will wait up to 12 hours.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if requests.mailboxOnline == false {
                Label("The mailbox folder isn't reachable right now.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Request") {
                    requests.ask(binPath: target.relativePath, binName: target.name, to: recipient, message: note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(requestPurple)
            }
        }
    }

    private var setUp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To ask colleagues for bins, everyone using Bin Watch chooses the same shared folder on your storage (outside your Avid projects). Bin Watch leaves small message files there — no Wi-Fi or network setup needed.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Mailbox Folder…") { requests.chooseMailboxViaPanel() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(requestPurple)
            }
        }
    }
}

/// Shown on a watched bin you've asked for: who you asked and what they said.
struct RequestStatusChip: View {
    let request: BinRequest
    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised.fill")
            Text(summary).lineLimit(1)
            Button {
                requests.cancelRequest(for: request.binPath)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Cancel this request")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(requestPurple)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(requestPurple.opacity(0.14), in: Capsule())
        .help(detail)
    }

    private var replies: [RequestReply] { requests.replies[request.id] ?? [] }

    private var summary: String {
        if let closing = replies.first(where: { $0.answer == .closing }) { return "\(closing.from.name) is closing it" }
        if let notNow = replies.first(where: { $0.answer == .notNow }) { return "\(notNow.from.name): not yet" }
        let seen = replies.filter { $0.answer != .notMe }
        if request.isForEveryone {
            return seen.isEmpty ? "Asked everyone" : "Asked everyone · seen by \(seen.count)"
        }
        return seen.isEmpty ? "Asked \(requests.name(of: request.to))" : "Seen by \(requests.name(of: request.to))"
    }

    private var detail: String {
        var lines = ["Asked \(request.isForEveryone ? "everyone" : requests.name(of: request.to)) at \(request.created.formatted(date: .omitted, time: .shortened))"]
        for reply in replies {
            let answer: String
            switch reply.answer {
            case .seen: answer = "has seen it"
            case .closing: answer = "is closing it"
            case .notNow: answer = "can't close it yet"
            case .notMe: answer = "doesn't have it open"
            }
            lines.append("\(reply.from.name) \(answer)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A small "Ask…" button for locked bins.
struct AskButton: View {
    let relativePath: String
    let name: String
    var compact = false

    var body: some View {
        Button {
            Navigation.shared.ask(relativePath: relativePath, name: name)
        } label: {
            if compact {
                Image(systemName: "hand.raised")
            } else {
                HStack(spacing: 4) { Image(systemName: "hand.raised"); Text("Ask…") }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(requestPurple)
        .help("Ask whoever has this bin open to close it")
    }
}

/// Settings: the shared mailbox, your name, and who else is using it.
struct BinRequestsSettings: View {
    @ObservedObject private var requests = RequestCenter.shared
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section("Bin Requests") {
            Text("Ask a colleague to close a bin you need. Everyone using Bin Watch chooses the same shared folder on your storage (outside your Avid projects); requests travel as small files there, so no Wi-Fi or network setup is needed — it works over NEXIS and synced storage like SyncBox.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill").font(.title2).foregroundStyle(requestPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(requests.mailboxPath.map { ($0 as NSString).lastPathComponent } ?? "No mailbox folder")
                        .font(.body.weight(.medium))
                    if let path = requests.mailboxPath {
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button(requests.mailboxPath == nil ? "Choose…" : "Change…") { requests.chooseMailboxViaPanel() }
                if requests.mailboxPath != nil {
                    Button("Turn Off") { requests.turnOff() }
                }
            }
            if requests.mailboxOnline == false {
                Label("The mailbox folder isn't reachable right now.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if requests.isSetUp {
                LabeledContent("Your name") {
                    TextField("", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onChange(of: nameFocused) { if !$0 { commitName() } }
                }
                if requests.people.isEmpty {
                    Text("Nobody else has joined yet. Ask your colleagues to choose this same folder in their Bin Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(requests.people) { status in
                        HStack(spacing: 8) {
                            Circle().fill(status.isOnline ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(status.person.name)
                            Text(status.person.computer).foregroundStyle(.secondary)
                            Spacer()
                            Text(status.isOnline ? "Online" : "Seen \(status.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear { nameDraft = requests.myName }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { requests.myName = trimmed } else { nameDraft = requests.myName }
    }
}
