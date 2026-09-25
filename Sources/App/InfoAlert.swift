import AppKit

/// A long, variable-length body for an informational `NSAlert`, shown in a scrollable, selectable
/// text area instead of `informativeText`.
///
/// `informativeText` is the wrong place for a report: it is what makes an alert balloon to fit
/// forty lines of control-plane log, and it cannot be selected, so the paths and error text it
/// carries cannot be copied out. A text view fixes both — the alert stops growing with its
/// content, and Cmd+C works.
extension NSAlert {
    /// Sizing: a fixed width (wider than the alert's natural body, so paths rarely wrap — the
    /// alert grows to fit it) and a height measured from the laid out text, clamped between
    /// `minLines` and `maxLines` of the body font. A short report is wrapped snugly, a longer one
    /// grows the alert a little, and past the cap it scrolls.
    ///
    /// `informativeText` is cleared on purpose: the two would otherwise stack, and the field's own
    /// wrapping width differs from the text view's. A sentence that has to precede the text goes
    /// in `intro` instead: it is laid out above the text area, wrapped at the same width, so the
    /// two read as one column.
    @MainActor @discardableResult
    func setScrollableBody(_ text: String, intro: String? = nil, width: CGFloat = 546,
                           minLines: Int = 7, maxLines: Int = 26) -> NSTextView? {
        informativeText = ""

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let inset = NSSize(width: 6, height: 5)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        // Measure at this width, then clamp. The line height comes from the layout manager for
        // the font actually in use, not from a guess.
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return nil
        }
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        let content = layout.usedRect(for: container).height + inset.height * 2
        let minHeight = lineHeight * CGFloat(minLines) + inset.height * 2
        let maxHeight = lineHeight * CGFloat(maxLines) + inset.height * 2
        let height = min(max(content, minHeight), maxHeight).rounded(.up)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        // A fixed frame: the alert lays its accessory out at exactly this size, so the clamp above
        // is what decides how much of the report is visible before scrolling.
        scroll.translatesAutoresizingMaskIntoConstraints = true

        guard let intro, !intro.isEmpty else {
            accessoryView = scroll
            return textView
        }

        // The intro, in the alert's own body font, measured at the text area's width; the two are
        // stacked in a plain container with frames, because NSAlert sizes its accessory by frame.
        // Selectable so it can be copied, and every https URL in it is a link run: a label draws
        // and follows `.link` attributes only while it allows editing text attributes.
        let label = NSTextField(wrappingLabelWithString: intro)
        label.font = font
        label.textColor = .labelColor
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.attributedStringValue = Self.linkified(intro, font: font)
        label.translatesAutoresizingMaskIntoConstraints = true
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        let introHeight = (label.cell?.cellSize(forBounds: bounds).height ?? lineHeight).rounded(.up)
        let gap: CGFloat = 8

        let stack = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                         height: height + gap + introHeight))
        scroll.frame.origin = .zero
        label.frame = NSRect(x: 0, y: height + gap, width: width, height: introHeight)
        stack.addSubview(scroll)
        stack.addSubview(label)
        accessoryView = stack
        return textView
    }

    /// `text` in `font` and the label colour, with each `https://` URL in it turned into a `.link`
    /// run. The font and colour are set on every run explicitly: a selectable label re-renders its
    /// attributed string on the first click, and runs without them fall back to the system
    /// defaults.
    static func linkified(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            let found = (text as NSString).substring(with: match.range)
            guard found.lowercased().hasPrefix("https://"), let url = match.url else { continue }
            result.addAttribute(.link, value: url, range: match.range)
        }
        return result
    }
}
