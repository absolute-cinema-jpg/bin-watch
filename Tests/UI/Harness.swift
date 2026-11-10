// Drives the real browser UI offscreen with genuine mouse and keyboard events.
// Never takes focus or shows a window on screen. Run: ./Tests/run-ui.sh
import AppKit
import SwiftUI

func pump(_ t: Double) {
    let end = Date().addingTimeInterval(t)
    while Date() < end {
        if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
            NSApp.sendEvent(e)
        }
    }
}

var window: NSWindow!
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "  ✓ \(m)" : "  ✗ \(m)"); if !c { fails += 1 } }

/// Click at a point measured from the window's TOP-left, in points.
func click(_ x: CGFloat, _ yFromTop: CGFloat, _ mods: NSEvent.ModifierFlags = []) {
    let p = NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(e, atStart: false)
    }
    pump(0.4)
}

/// A real double-click: two clicks, the second with clickCount 2.
func doubleClick(_ x: CGFloat, _ yFromTop: CGFloat, _ mods: NSEvent.ModifierFlags = []) {
    let p = NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop)
    for count in [1, 2] {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            NSApp.postEvent(e, atStart: false)
        }
    }
    pump(0.5)
}

func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    NSApp.postEvent(e, atStart: false)
    pump(0.4)
}

func snapshot(_ out: String, of target: NSWindow? = nil) {
    let host = (target ?? window).contentView!
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    // Paint the window's background behind the view, as the screen would.
    let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
    let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    (target ?? window).backgroundColor.setFill(); bounds.fill()
    rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try! flat.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

@main enum Harness {
    static func main() {
        AlertCenter.headless = true        // alerts are checked in memory, never shown
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dir = CommandLine.arguments[1]
        let top = URL(fileURLWithPath: dir).appendingPathComponent("Avid Projects")
        let root = top.appendingPathComponent("Documentary S1")
        let fm = FileManager.default
        try? fm.removeItem(at: top)
        for f in ["Documentary S1.avp", "1 Dailies/Day 01.avb", "1 Dailies/Day 02.avb", "2 Selects/B-Roll.avb",
                  "3 Cuts/Reel 1.avb", "3 Cuts/Reel 2.avb", "3 Cuts/Reel 3.avb", "3 Cuts/Reel 4.avb", "3 Cuts/Old/Reel 1 v1.avb",
                  "Music.avb", "3 Cuts/Reel 2.lck"] {
            let u = root.appendingPathComponent(f)
            try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data())
        }
        let store = AppStore.shared
        for b in store.watched { store.unwatch(b) }
        store.setRoot(top)
        store.settings.browseMode = .list
        Navigation.shared.selection = .browse
        let bm = BrowserModel.shared
        bm.go(to: ["Documentary S1", "3 Cuts"])

        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 960, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = ManageWindow.identifier
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        window.contentView = FirstClickHostingView(rootView: ManageView().environmentObject(store))
        window.orderFrontRegardless()
        pump(2)

        if CommandLine.arguments.count > 2 {
            for mode in [BrowseMode.icons, .columns] {
                store.settings.browseMode = mode; pump(1)
                snapshot(dir + "/\(mode.rawValue).png")
            }
            exit(0)
        }
        BinOpener.testHook = { _ in }       // never open Avid or Finder from tests
        InteractionTests.run(bm, store)
        BinOpener.testHook = { _ in }       // never open Avid or Finder from tests
        RequestFlowTests.run(store, dir: dir)
        NewBinsFlowTests.run(store, dir: dir)
        LockedFlowTests.run(store, dir: dir)
        HelpFlowTests.run(store, dir: dir)
        check(AlertCenter.shared.chimesSuppressed > 0, "alerts were raised during the tests, but no sound was played")
        print(fails == 0 ? "interaction tests passed" : "\(fails) interaction tests FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
