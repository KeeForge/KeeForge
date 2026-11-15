import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
struct SelectableNotesText: UIViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }

        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(fittingSize)
        return CGSize(width: width, height: size.height)
    }
}
#else
/// The macOS counterpart of the UIKit wrapper above: a non-editable, selectable
/// `NSTextView` that reports a width-aware height and turns URLs and email
/// addresses in a note into clickable links. `maximumNumberOfLines` (0 = all)
/// cuts it short; `onTruncationChange` reports whether text was cut.
struct SelectableNotesText: NSViewRepresentable {
    let text: String
    var maximumNumberOfLines = 0
    var onTruncationChange: (@MainActor (Bool) -> Void)?

    init(_ text: String, maximumNumberOfLines: Int = 0, onTruncationChange: (@MainActor (Bool) -> Void)? = nil) {
        self.text = text
        self.maximumNumberOfLines = maximumNumberOfLines
        self.onTruncationChange = onTruncationChange
    }

    /// Holds the TextKit 1 stack's storage. `NSLayoutManager` does not keep its
    /// text storage alive, so without this the storage would be deallocated the
    /// moment `makeNSView` returned.
    @MainActor
    final class Coordinator {
        let textStorage = NSTextStorage()
        var isTruncated: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        // Built explicitly rather than through `NSTextView(frame:)`, which
        // opts into TextKit 2 — whose `layoutManager` is nil, and sizing below
        // needs one.
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        context.coordinator.textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        textView.textContainer?.lineBreakMode = maximumNumberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        if context.coordinator.textStorage.string != text {
            context.coordinator.textStorage.setAttributedString(Self.attributedNotes(text))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < CGFloat.greatestFiniteMagnitude,
              let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }

        // Measuring resizes the container; a probe narrower than the view would otherwise stay as its wrap width.
        defer {
            if nsView.frame.width > 0 {
                textContainer.containerSize = CGSize(width: nsView.frame.width, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        textContainer.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let laidOut = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: textContainer),
                                                   actualGlyphRange: nil)
        reportTruncation(laidOut.upperBound < context.coordinator.textStorage.length, coordinator: context.coordinator)
        return CGSize(width: width, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }

    /// Sizing runs inside a layout pass, so the change reaches SwiftUI state on the next turn.
    private func reportTruncation(_ isTruncated: Bool, coordinator: Coordinator) {
        guard let onTruncationChange, coordinator.isTruncated != isTruncated else { return }
        coordinator.isTruncated = isTruncated
        Task { @MainActor in onTruncationChange(isTruncated) }
    }

    /// Plain body text with detected URLs and email addresses marked as links.
    static func attributedNotes(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
        return attributed
    }
}
#endif
