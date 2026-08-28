import AppKit

// Tachyon app icon: dark rounded square, neutral ring, green gauge wedge —
// the "healthy usage" band color; the icon should feel like breathing room.
@main struct IconGen {
    static func main() {
        let sizes: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
            (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
            (256, "icon_256x256"), (512, "icon_256x256@2x"),
            (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]
        let dir = "Tachyon.iconset"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (px, name) in sizes {
            let s = CGFloat(px)
            let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                // macOS-style rounded square, inset ~10% like system icons.
                let inset = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
                let radius = inset.width * 0.225
                let bg = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.addPath(bg)
                ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
                ctx.fillPath()

                let center = CGPoint(x: rect.midX, y: rect.midY)
                let ringRadius = inset.width * 0.30
                let stroke = max(1.5, inset.width * 0.055)

                // Gauge wedge at 35% — a green-band amount. Green slice, green story.
                let wedgeRadius = ringRadius - stroke * 1.6
                ctx.move(to: center)
                ctx.addArc(center: center, radius: wedgeRadius,
                           startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * 0.35,
                           clockwise: true)
                ctx.closePath()
                ctx.setFillColor(CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1))
                ctx.fillPath()

                // Neutral ring on top.
                ctx.addEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                          width: ringRadius * 2, height: ringRadius * 2))
                ctx.setStrokeColor(CGColor(gray: 0.96, alpha: 1))
                ctx.setLineWidth(stroke)
                ctx.strokePath()
                return true
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        print("iconset written")
    }
}
