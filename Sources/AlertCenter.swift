import AppKit
import SwiftUI

struct AlertItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case available                     // a watched bin is free
        case request(everyone: Bool)       // someone asks me to close a bin
        case reply(positive: Bool)         // someone answered my request
        case newBins(count: Int)           // bins appeared in a folder I'm watching
        case mailboxProblem                // Bin Watch needs the mailbox folder chosen again
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    let time: Date
    /// What it's about, for labels: "bin", "script", or "item" for a mix.
    var noun = "bin"

    /// Bin-available alert.
    init(binID: UUID, binName: String, detail: String, time: Date = Date(), noun: String = "bin") {
        self.init(id: binID, kind: .available, title: binName, detail: detail, time: time, noun: noun)
    }

    init(id: UUID, kind: Kind, title: String, detail: String, time: Date, noun: String = "bin") {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.time = time; self.noun = noun
    }
}

enum AlertResponse { case primary, secondary, dismissed }

/// What the alert stack is showing. Newest alert first.
final class AlertStackModel: ObservableObject {
    @Published var items: [AlertItem] = []
    @Published var expanded = false
    @Published var pulse = 0          // bumps on each reminder chime, so cards glow
    var maxListHeight: CGFloat = 500
}

/// Shows "bin available" alerts in one floating stack at the top right: above every
/// app (including full-screen ones), on every Space, never taking focus from Media
/// Composer. Several alerts collapse into a neat stack you can expand, so they never
/// run off the screen. Alerts stay until acknowledged, with a soft reminder chime.
final class AlertCenter {
    static let shared = AlertCenter()

    let model = AlertStackModel()
    private var handlers: [UUID: (AlertResponse) -> Void] = [:]
    private var panel: AlertPanel?
    private var chimeTimer: Timer?
    private var shrinkWork: DispatchWorkItem?

    // MARK: Showing and acknowledging

    func present(binID: UUID, binName: String, detail: String, onAcknowledge: @escaping () -> Void) {
        present(AlertItem(binID: binID, binName: binName, detail: detail), onRespond: { _ in onAcknowledge() })
    }

    func present(_ item: AlertItem, onRespond: @escaping (AlertResponse) -> Void) {
        handlers[item.id] = onRespond
        let wasEmpty = model.items.isEmpty
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            model.items.removeAll { $0.id == item.id }
            model.items.insert(item, at: 0)
        }
        updateBadge()
        if wasEmpty { showPanel() } else { resizePanel() }
        if case .reply = item.kind { playChime(scale: 0.6) } else { playChime() }
        startChimeTimer()
    }

    /// The person clicked a card's button.
    func respond(_ id: UUID, _ response: AlertResponse) {
        let handler = handlers[id]
        remove(id)
        handler?(response)
    }

    /// "OK" on a reply card.
    func acknowledge(_ id: UUID) { respond(id, .primary) }

    /// "Clear all": everything is dismissed — nothing is opened and no answers are sent.
    func acknowledgeAll() {
        for item in model.items { respond(item.id, .dismissed) }
    }

    /// Takes an alert away without treating it as acknowledged (e.g. the bin was unwatched).
    func remove(_ id: UUID) {
        guard model.items.contains(where: { $0.id == id }) else { return }
        handlers[id] = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            model.items.removeAll { $0.id == id }
            if model.items.count <= 1 { model.expanded = false }
        }
        updateBadge()
        if model.items.isEmpty {
            hidePanel()
            chimeTimer?.invalidate(); chimeTimer = nil
            stopChime()
        } else {
            resizePanel()
        }
    }

    func setExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.expanded = expanded }
        resizePanel()
    }

    /// The Dock icon shows how many alerts are waiting.
    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = model.items.isEmpty ? nil : "\(model.items.count)"
    }

    // MARK: Panel

    private func makePanel() -> AlertPanel {
        let host = FirstClickHostingView(rootView: AlertStackView(model: model))
        let panel = AlertPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10))
        panel.contentView = host
        return panel
    }

    private func targetFrame() -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame
        model.maxListHeight = visible.height * 0.6
        let size = AlertStackView.size(for: model)
        let m = AlertStackView.margin
        return NSRect(x: visible.maxX - size.width + m - 8,
                      y: visible.maxY - size.height + m - 8,
                      width: size.width, height: size.height)
    }

    /// Tests set this so alerts are tracked but never put on screen — and never make a sound.
    static var headless = false
    /// How many chimes would have played (tests check this instead of listening).
    private(set) var chimesSuppressed = 0

    private func showPanel() {
        guard !Self.headless else { return }
        shrinkWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let target = targetFrame() else { return }
        panel.setFrame(target.offsetBy(dx: 50, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 30, dy: 0), display: true)
        }, completionHandler: { [weak self] in
            if self?.model.items.isEmpty == true { panel.orderOut(nil) }
        })
    }

    /// Grow straight away; shrink once SwiftUI's animation has finished, so nothing gets clipped.
    private func resizePanel() {
        guard !Self.headless, let panel, let target = targetFrame() else { return }
        shrinkWork?.cancel()
        if target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let latest = self.targetFrame() else { return }
                self.panel?.setFrame(latest, display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    // MARK: Sound

    private func startChimeTimer() {
        guard chimeTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.model.items.isEmpty, AppStore.shared.settings.repeatChime else { return }
            self.playChime(scale: 0.7)
            self.model.pulse += 1
        }
        RunLoop.main.add(t, forMode: .common)
        chimeTimer = t
    }

    private var playing: NSSound?

    /// Plays the chosen alert sound. `scale` softens the repeat reminders.
    func playChime(scale: Double = 1) {
        guard !Self.headless else { chimesSuppressed += 1; return }
        playing?.stop()
        let settings = AppStore.shared.settings
        let sound = SoundLibrary.sound(settings.soundName) ?? SoundLibrary.sound("Glass")
        sound?.volume = Float(settings.volume * scale)
        sound?.play()
        playing = sound
    }

    func stopChime() {
        playing?.stop()
        playing = nil
    }
}

/// Lets the very first click land on a button, even though Bin Watch isn't the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, transparent, floating and non-activating: clicks work, but Avid keeps
/// both focus and the keyboard.
final class AlertPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
