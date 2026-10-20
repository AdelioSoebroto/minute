import SwiftUI

/// Liquid Glass on macOS 26 and later, a system material on older versions.
/// Everything goes through these helpers so the app adopts newer system styling without per-version code elsewhere.
extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial)).overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    /// Prominent (accent) or regular glass button, falling back to the classic styles.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// Soft fade where scrolling content slides under floating glass.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) { self.scrollEdgeEffectStyle(.soft, for: .all) } else { self }
    }
}

/// Groups nearby glass so shapes blend and morph together (macOS 26+); a plain container before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}
