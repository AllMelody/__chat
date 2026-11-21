import AppKit
import SwiftUI

struct AutosavingSplitView<Left: View, Right: View>: NSViewRepresentable {
    let left: Left
    let right: Right
    let autosaveName: String
    let isVertical: Bool
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right, autosaveName: String, isVertical: Bool = true) {
        self.left = left()
        self.right = right()
        self.autosaveName = autosaveName
        self.isVertical = isVertical
    }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = isVertical
        split.dividerStyle = .thin
        let leftHost = NSHostingView(rootView: left)
        let rightHost = NSHostingView(rootView: right)
        split.addArrangedSubview(leftHost)
        split.addArrangedSubview(rightHost)
        split.autosaveName = NSSplitView.AutosaveName(autosaveName)
        leftHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        return split
    }
    func updateNSView(_ nsView: NSSplitView, context: Context) {
        if let leftHost = nsView.subviews.first as? NSHostingView<Left> { leftHost.rootView = left }
        if nsView.subviews.count > 1, let rightHost = nsView.subviews[1] as? NSHostingView<Right> { rightHost.rootView = right }
    }
}
