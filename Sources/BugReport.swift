import Foundation

/// A bug report, turned into a link to GitHub's "New issue" page with everything filled in.
/// Nothing is sent from Bin Watch: the person checks it on GitHub and posts it there.
struct BugReport {
    var title = ""
    var whatHappened = ""
    var steps = ""
    var expected = ""
    /// Technical details, or nil to leave them out.
    var details: String?

    static let newIssuePage = "https://github.com/\(UpdateLogic.repo)/issues/new"
    static let issuesPage = URL(string: "https://github.com/\(UpdateLogic.repo)/issues")!
    /// Browsers and GitHub start refusing links much longer than this.
    static let maxLinkLength = 7500

    var isReady: Bool {
        !title.trimmed.isEmpty && !whatHappened.trimmed.isEmpty
    }

    var body: String { body(details: details) }

    private func body(details: String?) -> String {
        var parts = ["### What happened\n\n\(whatHappened.trimmed)"]
        if !steps.trimmed.isEmpty { parts.append("### Steps to reproduce\n\n\(steps.trimmed)") }
        if !expected.trimmed.isEmpty { parts.append("### What I expected\n\n\(expected.trimmed)") }
        if let details, !details.trimmed.isEmpty {
            parts.append("<details>\n<summary>Technical details</summary>\n\n```\n\(details.trimmed)\n```\n</details>")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The link to open. If it would be too long, the technical details lose their oldest
    /// lines first, then the description is shortened ("Copy Report" still has all of it).
    var issueLink: URL {
        var detailLines = details?.components(separatedBy: "\n") ?? []
        var report = self
        while true {
            let link = Self.link(title: report.title.trimmed, body: report.body(details: details == nil ? nil : detailLines.joined(separator: "\n")))
            if link.absoluteString.count <= Self.maxLinkLength { return link }
            if detailLines.count > 8 {
                // Keep the summary at the top; drop the oldest recent events below it.
                let firstEvent = (detailLines.firstIndex(of: Self.eventsHeading) ?? detailLines.count - 1) + 1
                if firstEvent < detailLines.count - 1 { detailLines.remove(at: firstEvent); continue }
                detailLines.removeLast()
                continue
            }
            let longest = [\BugReport.whatHappened, \BugReport.steps, \BugReport.expected]
                .max { report[keyPath: $0].count < report[keyPath: $1].count }!
            let text = report[keyPath: longest]
            if text.count < 40 { return link }
            report[keyPath: longest] = String(text.prefix(text.count * 3 / 4)) + " … (shortened)"
        }
    }

    static let eventsHeading = "Recent events (this session):"

    static func link(title: String, body: String) -> URL {
        let query = [("title", title), ("body", body), ("labels", "bug")]
            .map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: newIssuePage + "?" + query)!
    }

    /// Percent-encodes everything except letters, digits and -._~, so &, = and + survive.
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Takes out anything that could name a project, bin, person or folder: quoted names, and
    /// everything from the start of a file path to the end of the line (paths can contain spaces).
    static func redact(_ line: String) -> String {
        var s = line
        for pattern in [#"“[^”]*”"#, #""[^"]*""#, #"'[^']*'"#, #"‘[^’]*’"#] {
            s = s.replacingOccurrences(of: pattern, with: "“…”", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(file://)?/(Volumes|Users|private|Applications|Library|System|var|tmp|Network)\b.*"#,
                                   with: "‹path›", options: .regularExpression)
        return s
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
