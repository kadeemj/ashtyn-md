import AppKit

/// Keeps the caret line vertically centered while typing.
@MainActor
final class TypewriterScroller {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    /// Set while a programmatic scroll runs, so the view-state observer can
    /// tell it apart from the user scrolling.
    private let willScroll: (Bool) -> Void

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            updateInsets()
            if isEnabled { caretDidMove() }
        }
    }

    init(
        textView: NSTextView,
        scrollView: NSScrollView,
        willScroll: @escaping (Bool) -> Void
    ) {
        self.textView = textView
        self.scrollView = scrollView
        self.willScroll = willScroll
    }

    /// Bottom room so the last line can still reach the middle of the view.
    ///
    /// Uses contentInsets rather than textContainerInset: the latter is a
    /// symmetric NSSize, so it would also push the first line down, and
    /// LineNumberRulerView reads it for its own y-offset math.
    func updateInsets() {
        guard let scrollView else { return }
        scrollView.automaticallyAdjustsContentInsets = !isEnabled
        if isEnabled {
            let half = scrollView.contentView.bounds.height / 2
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: half, right: 0)
        } else {
            scrollView.contentInsets = NSEdgeInsets()
        }
    }

    func caretDidMove() {
        guard isEnabled,
              let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        // Never fight a drag-selection in progress.
        guard textView.selectedRange().length == 0 else { return }

        let clip = scrollView.contentView
        guard clip.bounds.height > 0 else { return }

        let length = (textView.string as NSString).length
        let caret = min(textView.selectedRange().location, length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret)
        let fragment = caret >= length && length > 0
            ? layoutManager.extraLineFragmentRect
            : layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        _ = container

        let target = fragment.midY + textView.textContainerInset.height - clip.bounds.height / 2
        let clamped = max(-scrollView.contentInsets.top, target)
        guard abs(clip.bounds.origin.y - clamped) > 1 else { return }

        willScroll(true)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
        willScroll(false)
    }
}
