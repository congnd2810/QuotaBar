import AppKit
import SwiftUI

/// Stats-style menu bar widget: a small caption, a value and, depending on the style, a gauge.
struct MenuBarWidget: Identifiable {
    var id: String { caption }
    let caption: String
    /// 0...1, nil while there is no data yet.
    let fraction: Double?

    var value: String { UsageStore.percent(fraction) }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// Caption above the value.
    case text
    /// Caption and value next to a vertical bar.
    case bar
    /// A ring gauge next to caption and value.
    case ring

    var id: String { rawValue }
}

struct MenuBarLabel: View {
    static let height: CGFloat = 22

    let widgets: [MenuBarWidget]
    let style: MenuBarStyle

    var body: some View {
        HStack(spacing: 10) {
            ForEach(widgets) { widget in
                HStack(spacing: 4) {
                    if style == .ring {
                        Ring(fraction: widget.fraction ?? 0)
                    }
                    captionAndValue(widget)
                    if style == .bar {
                        VerticalBar(fraction: widget.fraction ?? 0)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 2)
        .frame(height: Self.height)
        .foregroundStyle(.black)
    }

    private func captionAndValue(_ widget: MenuBarWidget) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(widget.caption)
                .font(.system(size: 7.5, weight: .semibold))
                .kerning(0.2)
            Text(widget.value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    /// Status items display an image: the widgets are rendered to a template
    /// image, which macOS tints for light/dark menu bars like any system icon. Partial opacity
    /// (gauge tracks) survives as lighter tint.
    @MainActor
    static func image(for widgets: [MenuBarWidget], style: MenuBarStyle) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarLabel(widgets: widgets, style: style))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct VerticalBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5).opacity(0.25)
            RoundedRectangle(cornerRadius: 1.5)
                .frame(height: 18 * min(max(fraction, 0), 1))
        }
        .frame(width: 5, height: 18)
    }
}

private struct Ring: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2.5).opacity(0.25)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}
