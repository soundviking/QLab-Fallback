import AppKit

// MenuBarExtra labels are bridged to NSStatusItem. A non-template image keeps
// the black background and semantic colors in both light and dark macOS menus.
enum MenuBarLabelRenderer {
    static func image(text: String, color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let title = NSAttributedString(string: text, attributes: attributes)
        let width = ceil(title.size().width) + 20
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
            title.draw(at: NSPoint(x: 10, y: floor((size.height - title.size().height) / 2)))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = text
        return image
    }
}
