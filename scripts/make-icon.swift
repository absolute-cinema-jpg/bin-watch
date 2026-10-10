// Renders the app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
ctx.restoreGState()

path.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.16, blue: 0.27, alpha: 1),
    NSColor(srgbRed: 0.09, green: 0.33, blue: 0.40, alpha: 1),
])!.draw(in: rect, angle: -60)

// Soft green glow behind the lock.
NSGradient(colors: [
    NSColor(srgbRed: 0.25, green: 0.85, blue: 0.55, alpha: 0.55),
    NSColor(srgbRed: 0.25, green: 0.85, blue: 0.55, alpha: 0),
])!.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 90, dy: 90)), relativeCenterPosition: .zero)

func symbol(_ name: String, _ pt: CGFloat, _ color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

let stack = symbol("rectangle.stack.fill", 300, NSColor.white.withAlphaComponent(0.16))
stack.draw(in: CGRect(x: (size - stack.size.width) / 2, y: 470, width: stack.size.width, height: stack.size.height))

let lock = symbol("lock.open.fill", 380, .white)
lock.draw(in: CGRect(x: (size - lock.size.width) / 2 + 20, y: (size - lock.size.height) / 2 - 40,
                     width: lock.size.width, height: lock.size.height))

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
