import SwiftUI

/// §12.1 materials: Liquid Glass on macOS 26+, system materials as the fallback on
/// macOS 13–15. All tints remain semantic so appearance/accent changes propagate.
extension View {
    /// Card-style translucent surface (welcome cards, permission primer).
    func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(
                self
                    .padding(0)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
            )
        } else {
            return AnyView(
                self
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
            )
        }
    }

    /// Bar-style translucent surface (toolbars/footer strips inside sheets).
    func glassBar() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(self.glassEffect(.regular))
        } else {
            return AnyView(self.background(.bar))
        }
    }
}
