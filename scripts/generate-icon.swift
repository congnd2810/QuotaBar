// Renders the app icon and builds Resources/AppIcon.icns.
// Usage: swift scripts/generate-icon.swift   (run from the repo root)
import AppKit
import SwiftUI

/// A usage gauge on a macOS-style rounded square: the arc reads as "quota used",
/// the two-tone fill hints at the two providers.
struct IconView: View {
    /// Share of the 270° gauge arc that is filled.
    let fill = 0.7

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.12, blue: 0.27), Color(red: 0.06, green: 0.05, blue: 0.13)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            // Track.
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 76, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 500, height: 500)

            // Fill.
            Circle()
                .trim(from: 0, to: 0.75 * fill)
                .stroke(
                    AngularGradient(
                        colors: [Color(red: 0.98, green: 0.62, blue: 0.42), Color(red: 0.93, green: 0.42, blue: 0.62), Color(red: 0.45, green: 0.56, blue: 1.0)],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * fill)
                    ),
                    style: StrokeStyle(lineWidth: 76, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
                .frame(width: 500, height: 500)

            // Needle pointing at the end of the fill. The arc starts at 135° (clockwise from 3 o'clock);
            // an unrotated needle points at 270°.
            Capsule()
                .fill(Color.white)
                .frame(width: 22, height: 190)
                .offset(y: -95)
                .rotationEffect(.degrees(135 + 270 * fill - 270))
                .shadow(color: .black.opacity(0.3), radius: 6)
            Circle()
                .fill(Color.white)
                .frame(width: 64, height: 64)

            // Sparkle: the "AI" in AI usage.
            Image(systemName: "sparkle")
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
                .offset(y: 205)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func run() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else { fatalError("render failed") }

    // Standard iconset sizes: 16…512 at 1x and 2x.
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: cgImage, size: NSSize(width: 1024, height: 1024))
                .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }

    let resources = root.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
}

try MainActor.assumeIsolated { try run() }
