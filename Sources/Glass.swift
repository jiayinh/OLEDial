import SwiftUI

// Liquid Glass helpers. On macOS 26 (Tahoe) / 27 (Golden Gate) these use the native
// Liquid Glass APIs, which also follow the system "Liquid Glass" appearance slider.
// On macOS 14–15 they fall back to vibrancy materials.

extension View {
    /// Rounded glass card background.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// Circular glass badge (icons).
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: Circle())
            } else {
                self.glassEffect(.regular, in: Circle())
            }
        } else {
            self
                .background((tint ?? Color.primary.opacity(0.1)).opacity(0.35), in: Circle())
        }
    }

    /// Capsule-shaped glass (used by the HUD).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(.ultraThickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }

    /// Glass button style (falls back to bordered).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Groups glass shapes so they blend/morph together on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
