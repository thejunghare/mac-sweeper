import SwiftUI

/// §12.1 materials: Liquid Glass on macOS 26+, system materials as the fallback on
/// macOS 13–15. All tints remain semantic so appearance/accent changes propagate.
extension View {
    /// Bar-style translucent surface (toolbars/footer strips inside sheets).
    func glassBar() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(self.glassEffect(.regular))
        } else {
            return AnyView(self.background(.bar))
        }
    }
}
