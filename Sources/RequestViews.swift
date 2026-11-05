import SwiftUI

struct AskTarget: Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let name: String
    var holder: String? = nil          // who has it open, from the lock file
}

/// "Locked" or "Locked by Sam Okafor" / "Locked by you" / "Locked by EDIT-2".
struct LockedLabel: View {
    let holder: String?
    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        Label(holder.map { "Locked by \(requests.describe(holder: $0))" } ?? "Locked", systemImage: "lock.fill")
            .lineLimit(1)
            .truncationMode(.tail)
            .help(holder.map { "Avid's lock file says it's open on “\($0)”" } ?? "Locked")
    }
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
                    if let holder = target.holder {
                        Label("Open on “\(holder)”" + (requests.person(holding: holder).map { " — that's \($0.person.name)" } ?? ""),
                              systemImage: "lock.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            if requests.isSetUp { form } else { setUp }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            // Ask the person who has it open, if they use Bin Watch.
            if let holder = target.holder, let person = requests.person(holding: holder) { recipient = person.id }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bin Watch will ask them to close the \(AvidItem.noun(target.relativePath)), and alert you the moment it's free.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Ask", selection: $recipient) {
                Text("Everyone using Bin Watch").tag(UUID?.none)
                if !requests.people.isEmpty { Divider() }
                ForEach(requests.people) { status in
                    let hasIt = target.holder.map(status.person.matches(lockHolder:)) ?? false
                    Text("\(status.person.name) — \(status.person.computer)\(hasIt ? " (has it open)" : status.isOnline ? "" : " (away)")")
                        .tag(Optional(status.id))
                }
            }

            TextField("Add a note (optional), e.g. “Need it for the trailer”", text: $note)
                .textFieldStyle(.roundedBorder)

            if requests.people.isEmpty {
                Label("Nobody else has joined this mailbox yet. Your request will wait up to 12 hours.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = requests.statusMessage, requests.status != .connecting {
                MailboxProblemLabel(message: problem)
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
            Text("To ask colleagues for bins and scripts, everyone using Bin Watch chooses the same shared folder on your storage (outside your Avid projects). Bin Watch leaves small message files there — no Wi-Fi or network setup needed.")
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

/// Says what's wrong with the mailbox, with a way to fix it if it needs you.
struct MailboxProblemLabel: View {
    let message: String
    @ObservedObject private var requests = RequestCenter.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if requests.status == .needsPermission {
                Spacer(minLength: 0)
                Button("Choose Folder…") { requests.chooseMailboxViaPanel() }
                    .controlSize(.small)
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
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .help(detail)
    }

    private var replies: [RequestReply] { requests.replies[request.id] ?? [] }
    private var isSent: Bool { requests.delivered.contains(request.id) }
    private var nobodyToSeeIt: Bool { replies.isEmpty && isSent && !recipientIsOnline }
    private var tint: Color { !isSent || nobodyToSeeIt ? .orange : requestPurple }

    /// Is anyone who'd get this request running Bin Watch right now?
    private var recipientIsOnline: Bool {
        if let to = request.to { return requests.people.first { $0.id == to }?.isOnline ?? false }
        return requests.people.contains(where: \.isOnline)
    }

    private var summary: String {
        if !isSent { return "Not sent yet" }
        if let closing = replies.first(where: { $0.answer == .closing }) { return "\(closing.from.name) is closing it" }
        if let notNow = replies.first(where: { $0.answer == .notNow }) { return "\(notNow.from.name): not yet" }
        let seen = replies.filter { $0.answer != .notMe }
        if request.isForEveryone {
            if seen.isEmpty { return nobodyToSeeIt ? "Asked everyone · nobody online" : "Asked everyone" }
            return "Asked everyone · seen by \(seen.count)"
        }
        let name = requests.name(of: request.to)
        if seen.isEmpty { return nobodyToSeeIt ? "Asked \(name) · offline" : "Asked \(name)" }
        return "Seen by \(name)"
    }

    private var detail: String {
        var lines = ["Asked \(request.isForEveryone ? "everyone" : requests.name(of: request.to)) at \(request.created.formatted(date: .omitted, time: .shortened))"]
        if !isSent {
            lines.append(requests.statusMessage ?? "Sending…")
            lines.append("It will be sent automatically as soon as the mailbox can be reached.")
        } else if replies.isEmpty {
            lines.append(recipientIsOnline
                ? "It's in the mailbox. “Seen” appears once it's on their screen."
                : "It's in the mailbox, and will appear on their screen when their Bin Watch next connects (within 12 hours).")
        }
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
    var holder: String? = nil
    var compact = false

    var body: some View {
        Button {
            Navigation.shared.ask(relativePath: relativePath, name: name, holder: holder)
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
        .help("Ask whoever has this \(AvidItem.noun(relativePath)) open to close it")
    }
}

/// Settings: the shared mailbox, your name, and who else is using it.
struct BinRequestsSettings: View {
    @ObservedObject private var requests = RequestCenter.shared
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section("Bin Requests") {
            Text("Ask a colleague to close a bin or script you need. Everyone using Bin Watch chooses the same shared folder on your storage (outside your Avid projects); requests travel as small files there, so no Wi-Fi or network setup is needed — it works over NEXIS and synced storage like SyncBox.")
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
            if let problem = requests.statusMessage {
                MailboxProblemLabel(message: problem)
            } else if requests.status == .connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if requests.isSetUp {
                HStack(spacing: 8) {
                    Button("Check Connection") { requests.checkConnection() }
                        .controlSize(.small)
                        .disabled(requests.checking)
                        .help("Tries listing, writing and reading a small test file in the mailbox, then removes it")
                    if requests.checking {
                        ProgressView().controlSize(.small)
                    } else if let check = requests.lastCheck {
                        Group {
                            if let problem = check.problem {
                                Label(problem, systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                            } else {
                                Label("Sending and receiving works", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
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
