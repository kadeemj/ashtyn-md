import AppKit
import SwiftUI

/// Read-only side-by-side view of the local editor buffer and current disk
/// contents. Both panes remain selectable and copyable.
struct ConflictComparisonView: View {
    let comparison: ConflictComparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                pane(
                    title: "Your Unsaved Version",
                    text: comparison.editorText
                )
                pane(
                    title: "Version on Disk",
                    text: comparison.diskText
                )
            }
            Divider()
            HStack {
                Text(comparison.fileName)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func pane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ConflictReadOnlyTextView(text: text, accessibilityLabel: title)
        }
        .padding()
    }
}

private struct ConflictReadOnlyTextView: NSViewRepresentable {
    let text: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
    }
}
