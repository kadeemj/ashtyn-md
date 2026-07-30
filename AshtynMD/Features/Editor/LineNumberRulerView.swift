import AppKit

/// Line-number gutter for the editor, drawn with TextKit 1 layout info.
/// Wrapped lines get one number at their first fragment; the current line's
/// number is emphasized.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(invalidate),
            name: NSText.didChangeNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(invalidate),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(invalidate),
            name: NSView.frameDidChangeNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func invalidate() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character.
        var lineNumber = 1
        var index = 0
        while index < charRange.location && index < content.length {
            index = NSMaxRange(content.lineRange(for: NSRange(location: index, length: 0)))
            lineNumber += 1
        }

        let selectedLineRange: NSRange? = {
            guard textView.window?.firstResponder === textView else { return nil }
            let selection = textView.selectedRange()
            guard selection.location <= content.length else { return nil }
            return content.lineRange(for: NSRange(location: selection.location, length: 0))
        }()

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (textView.font?.pointSize ?? 13) - 2), weight: .regular
        )
        let inset = textView.textContainerInset.height

        var lineStart = index
        while lineStart <= charRange.location + charRange.length {
            let lineRange = content.lineRange(for: NSRange(location: min(lineStart, content.length), length: 0))
            drawNumber(
                lineNumber,
                forCharacterIndex: lineRange.location,
                isCurrent: selectedLineRange?.location == lineRange.location,
                font: font,
                layoutManager: layoutManager,
                container: container,
                textInsetY: inset,
                visibleRect: visibleRect,
                isEndOfText: lineRange.location >= content.length
            )
            if NSMaxRange(lineRange) == lineStart { break }
            lineStart = NSMaxRange(lineRange)
            lineNumber += 1
            if lineRange.length == 0 { break }
        }
    }

    private func drawNumber(
        _ number: Int,
        forCharacterIndex characterIndex: Int,
        isCurrent: Bool,
        font: NSFont,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        textInsetY: CGFloat,
        visibleRect: NSRect,
        isEndOfText: Bool
    ) {
        let fragmentRect: NSRect
        if isEndOfText {
            // The virtual line after a trailing newline (or an empty document).
            fragmentRect = layoutManager.extraLineFragmentRect
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: nil
            )
        }
        guard fragmentRect.height > 0 else { return }

        let y = fragmentRect.minY + textInsetY - visibleRect.minY
        guard y + fragmentRect.height >= 0, y <= bounds.height else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(
            x: ruleThickness - size.width - 6,
            y: y + (fragmentRect.height - size.height) / 2
        )
        label.draw(at: point, withAttributes: attributes)
    }
}
