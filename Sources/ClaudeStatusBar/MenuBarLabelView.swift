import AppKit
import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon
    let previousModel: MenuBarLabelModel?
    let transitionProgress: Double
    var shimmerPhase: Double = 0
    let normalColor: NSColor
    let yellowColor: NSColor
    let redColor: NSColor
    let animateText: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The whole label is composited into one NSImage (LabelComposite):
        // MenuBarExtra flattens its label into the status button's single
        // image slot + title, so a multi-view HStack cannot control order
        // or keep more than one image.
        let current = LabelComposite.image(model: model, icon: icon,
                                           shimmerPhase: shimmerPhase,
                                           dark: colorScheme == .dark,
                                           normalColor: normalColor,
                                           yellowColor: yellowColor,
                                           redColor: redColor,
                                           animateText: animateText)
        let image = previousModel.map { previous in
            LabelComposite.crossfade(
                from: LabelComposite.image(model: previous,
                                           icon: StatusIcon.icon(for: previous.state),
                                           shimmerPhase: shimmerPhase,
                                           dark: colorScheme == .dark,
                                           normalColor: normalColor,
                                           yellowColor: yellowColor,
                                           redColor: redColor,
                                           animateText: animateText),
                to: current, progress: transitionProgress)
        } ?? current
        Image(nsImage: image)
            .renderingMode(.original)
    }
}
