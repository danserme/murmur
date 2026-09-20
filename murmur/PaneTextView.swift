import AppKit
import SwiftUI

struct PaneTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var isEditable: Bool
    var highlight: NSRange?
    var highlightTick: Int
    var locatesSource = false
    var onRevealSource: ((String) -> Bool)?
    var onSelectionCleared: (() -> Void)?
    var onSelectionChange: ((String, CGRect?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PaneEditorView {
        let editor = PaneEditorView()
        let scrollView = editor.scrollView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = PaneNSTextView()
        textView.editor = editor
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        applyChrome(to: textView)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.editor = editor
        context.coordinator.textView = textView
        context.coordinator.observeScroll()
        return editor
    }

    static func dismantleNSView(_ nsView: PaneEditorView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func updateNSView(_ editor: PaneEditorView, context: Context) {
        context.coordinator.parent = self
        guard let textView = editor.scrollView.documentView as? NSTextView else { return }
        applyChrome(to: textView)
        textView.isEditable = isEditable
        textView.isSelectable = true

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let maxLength = (text as NSString).length
            let location = min(selected.location, maxLength)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        context.coordinator.applyHighlight(highlight, tick: highlightTick)
        context.coordinator.syncLocator()
    }

    private func applyChrome(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: 16, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineSpacing = 7
        let color = NSColor(LTTheme.ink)
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = NSColor(LTTheme.accent)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(LTTheme.selectionFill),
            .foregroundColor: color,
        ]
        if let pane = textView as? PaneNSTextView {
            pane.placeholderText = placeholder
            pane.placeholderColor = NSColor(LTTheme.muted).withAlphaComponent(0.8)
            pane.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaneTextView
        weak var editor: PaneEditorView?
        weak var textView: NSTextView?
        private var appliedTick = -1
        private var boundsObserver: NSObjectProtocol?
        private var lookupFailed = false
        private var selectedText = ""

        init(_ parent: PaneTextView) {
            self.parent = parent
        }

        func tearDown() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
        }

        func observeScroll() {
            tearDown()
            guard let clipView = editor?.scrollView.contentView else { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishSelection()
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            publishSelection()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishSelection()
        }

        func applyHighlight(_ range: NSRange?, tick: Int) {
            guard let textView else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.removeAttribute(.backgroundColor, range: full)
            guard let range, NSMaxRange(range) <= full.length, range.length > 0 else { return }
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor(LTTheme.sourceFill),
                range: range
            )
            if tick != appliedTick {
                appliedTick = tick
                textView.scrollRangeToVisible(range)
            }
        }

        func syncLocator() {
            publishSelection()
        }

        private func publishSelection() {
            guard let textView, let editor else { return }
            let range = textView.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else {
                if !selectedText.isEmpty {
                    selectedText = ""
                    lookupFailed = false
                    parent.onSelectionCleared?()
                }
                parent.onSelectionChange?("", nil)
                editor.hideLocator()
                return
            }
            let selected = (textView.string as NSString).substring(with: range)
            selectedText = selected
            parent.onSelectionChange?(selected, editor.convertSelectionRect(from: textView, range: range))
            updateLocator(selected: selected, range: range)
        }

        private func updateLocator(selected: String, range: NSRange) {
            guard let editor, let textView else { return }
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parent.locatesSource, trimmed.count >= 8 else {
                editor.hideLocator()
                return
            }
            editor.showLocator(
                selected: selected,
                failed: lookupFailed,
                range: range,
                textView: textView
            ) { [weak self] in
                self?.revealSource()
            }
        }

        private func revealSource() {
            lookupFailed = !(parent.onRevealSource?(selectedText) ?? false)
            if let textView {
                updateLocator(selected: selectedText, range: textView.selectedRange())
            }
        }
    }
}

final class PaneEditorView: NSView {
    let scrollView = NSScrollView()
    private let locatorModel = SourceLocatorModel()
    private var locatorHost: SourceLocatorHostView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let locatorHost, !locatorHost.isHidden, locatorHost.frame.contains(point) {
            return locatorHost.hitTest(convert(point, to: locatorHost)) ?? locatorHost
        }
        return super.hitTest(point)
    }

    func convertSelectionRect(from textView: NSTextView, range: NSRange) -> CGRect? {
        var actual = range
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actual)
        guard let window, screenRect.width > 0 || screenRect.height > 0 else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        return convert(windowRect, from: nil)
    }

    func hideLocator() {
        locatorHost?.isHidden = true
        window?.invalidateCursorRects(for: self)
    }

    func showLocator(
        selected: String,
        failed: Bool,
        range: NSRange,
        textView: NSTextView,
        action: @escaping () -> Void
    ) {
        guard let selectionRect = convertSelectionRect(from: textView, range: range) else {
            hideLocator()
            return
        }

        let placeAbove = selectionRect.minY - 40 >= 4
        let newlyShown = locatorHost == nil || locatorHost?.isHidden == true
        locatorModel.update(failed: failed, action: action, newlyShown: newlyShown)
        if locatorHost == nil {
            let host = SourceLocatorHostView(rootView: SourceLocatorChip(model: locatorModel))
            host.wantsLayer = true
            addSubview(host, positioned: .above, relativeTo: scrollView)
            locatorHost = host
        }

        guard let locatorHost else { return }
        locatorHost.invalidateIntrinsicContentSize()
        var size = locatorHost.fittingSize
        if size.width < 8 || size.height < 8 {
            size = NSSize(width: 210, height: 32)
        }
        let x = min(max(6, selectionRect.midX - size.width / 2), max(6, bounds.width - size.width - 6))
        let y = placeAbove ? selectionRect.minY - size.height - 8 : selectionRect.maxY + 8
        locatorHost.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        locatorHost.isHidden = false
        locatorHost.updateTrackingAreas()
        window?.invalidateCursorRects(for: locatorHost)
        window?.invalidateCursorRects(for: textView)
    }

    func isMouseOverLocator(_ event: NSEvent) -> Bool {
        guard let locatorHost, !locatorHost.isHidden else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return locatorHost.frame.contains(point)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isMouseOverLocator(event) {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}

final class PaneNSTextView: NSTextView {
    weak var editor: PaneEditorView?
    var placeholderText = ""
    var placeholderColor = NSColor.secondaryLabelColor

    override func draw(_ dirtyRect: NSRect) {
        if string.isEmpty, !placeholderText.isEmpty {
            var attributes = typingAttributes
            attributes[.foregroundColor] = placeholderColor
            let padding = textContainer?.lineFragmentPadding ?? 0
            var rect = bounds
            rect.origin.x = textContainerOrigin.x + padding
            rect.origin.y = textContainerOrigin.y
            rect.size.width -= textContainerOrigin.x + padding
            (placeholderText as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
        super.draw(dirtyRect)
    }

    override func mouseMoved(with event: NSEvent) {
        if editor?.isMouseOverLocator(event) == true {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if editor?.isMouseOverLocator(event) == true {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}
