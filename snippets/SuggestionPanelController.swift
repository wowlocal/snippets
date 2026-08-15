import AppKit

private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SuggestionSearchField: NSSearchField {
    /// A non-activating panel normally refuses key status for incidental clicks.
    /// Secure Paste is the deliberate exception: its search field is the one view
    /// that must be able to take keyboard focus without activating Snippets.
    override var needsPanelToBecomeKey: Bool { true }
}

/// Liquid Glass deliberately darkens when its window becomes key. Secure Paste
/// must become key for its search field, while ordinary backslash suggestions
/// must not steal keyboard input from the destination app. This adaptive wash
/// keeps the same perceived panel surface across those two required states.
private final class SuggestionPanelKeyCompensationView: NSView {
    var isEnabled = false {
        didSet {
            if isEnabled != oldValue { updateBackgroundColor() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateBackgroundColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        guard isEnabled,
              #available(macOS 26.0, *),
              !LiquidGlassDesign.forcesLegacyAppearance else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark
            ? NSColor.white.withAlphaComponent(0.052)
            : NSColor.black.withAlphaComponent(0.035)
        layer?.backgroundColor = color.cgColor
    }
}

struct SuggestionItem {
    let snippet: Snippet
    let isSecure: Bool
    let score: Int
    let nameMatchRanges: [NSRange]
    let keywordMatchRanges: [NSRange]
    /// Precomputed so the comparator never folds strings on the keystroke path.
    let keywordRank: Int
    let bindingWeight: Double
    let frecency: Double

    init(
        snippet: Snippet,
        isSecure: Bool = false,
        score: Int,
        nameMatchRanges: [NSRange] = [],
        keywordMatchRanges: [NSRange] = [],
        keywordRank: Int = 0,
        bindingWeight: Double = 0,
        frecency: Double = 0
    ) {
        self.snippet = snippet
        self.isSecure = isSecure
        self.score = score
        self.nameMatchRanges = nameMatchRanges
        self.keywordMatchRanges = keywordMatchRanges
        self.keywordRank = keywordRank
        self.bindingWeight = bindingWeight
        self.frecency = frecency
    }
}

@MainActor
final class SuggestionPanelController: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSWindowDelegate
{
    private enum PresentationMode {
        case suggestions
        case securePaste
    }

    private let panel: NSPanel
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private let searchField = SuggestionSearchField()
    private let searchContainer = NSView()
    private let keyAppearanceCompensationView = SuggestionPanelKeyCompensationView()
    private let emptyLabel = NSTextField(labelWithString: "No matching snippets")
    private var searchContainerHeightConstraint: NSLayoutConstraint!
    private(set) var items: [SuggestionItem] = []
    private let maxVisible = 8
    private let singleLineRowHeight: CGFloat = 46
    private let wrappedNameRowHeight: CGFloat = 62
    private let securePasteSearchHeight: CGFloat = 42
    private let securePasteEmptyListHeight: CGFloat = 52
    /// Static so the panel and its column can size themselves during init.
    private static let panelWidth: CGFloat = 320
    /// The cell's leading/trailing inset doubled: 6pt of it is the highlight pill's
    /// own inset, 8pt is breathing room between the pill edge and the text.
    private let horizontalCellPadding: CGFloat = 28

    private var maxVisibleRowsOnScreen: Int {
        let anchorPoint = anchor?.screenPoint
        let screen = (anchorPoint.flatMap { screenContaining(point: $0) })
            ?? screenContaining(point: NSEvent.mouseLocation)
            ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else { return 8 }

        // Keep some margin so the panel doesn't try to fill the whole screen.
        let maxHeight = visibleFrame.height * 0.5

        let spacing = tableView.intercellSpacing.height
        let perRow = wrappedNameRowHeight + spacing

        // Subtract scroll insets.
        let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom
        let searchHeight = presentationMode == .securePaste ? securePasteSearchHeight : 0
        let usable = max(0, maxHeight - insets - searchHeight)

        return max(1, Int(floor(usable / perRow)))
    }

    var onSelect: ((Snippet) -> Void)?
    var onDismiss: (() -> Void)?
    var hasSelectableItems: Bool { !items.isEmpty }
    private var presentationMode: PresentationMode = .suggestions
    private var securePasteSearch: ((String) -> [SuggestionItem])?
    private var securePasteSelection: ((Snippet) -> Void)?
    private var securePasteCancellation: ((Bool) -> Void)?
    /// `orderFrontRegardless()` temporarily unhides an application. When Secure
    /// Paste starts from a Cmd-H-hidden Snippets, keep only this panel exempt from
    /// application hiding and immediately restore the original hidden state.
    private var securePasteStartedWithHiddenApplication = false
    private var isEndingSecurePaste = false
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var anchor: PanelAnchor?
    private var accessibilityPrimedPIDs: Set<pid_t> = []
    private var enhancedAccessibilityPrimedPIDs: Set<pid_t> = []
    private var selectionWasUserDriven = false

    private enum AnchorSource: String {
        case caret
        case focusedElement = "focused-element"
        case mouse
    }

    private enum PanelAnchor {
        case rect(NSRect)
        case mouse(NSPoint)
        case screenCenter(NSRect)

        var screenPoint: NSPoint {
            switch self {
            case .rect(let rect):
                return NSPoint(x: rect.midX, y: rect.midY)
            case .mouse(let point):
                return point
            case .screenCenter(let visibleFrame):
                return NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
            }
        }
    }

    private struct AnchorResolution {
        let anchor: PanelAnchor
        let source: AnchorSource
        let reason: String
    }

    private struct RectCandidate {
        let rect: NSRect
        let screen: NSScreen
        let priority: Int
    }

    override init() {
        panel = SuggestionPanel(
            contentRect: NSRect(x: 0, y: 0, width: SuggestionPanelController.panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        tableView = NSTableView()
        tableView.headerView = nil
        // `.automatic` resolves to `.inset` on macOS 26, which squeezes the column
        // and offsets the first row. This panel draws its own row pill, so no
        // system insets or decoration are wanted.
        tableView.style = .plain
        tableView.backgroundColor = .clear
        // Ordinary suggestions are non-key and Secure Paste becomes key for its
        // search field. Drawing our own pill keeps both modes visually identical.
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowHeight = singleLineRowHeight
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestionColumn"))
        column.width = SuggestionPanelController.panelWidth
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        // A legacy scroller shrinks the document view, which pulls every row pill
        // off the right edge and out of its concentric fit in the glass corner.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 4 here plus the row view's half-spacing inset of 2 makes the gap above the
        // first pill and below the last one match the 6pt gap at the sides.
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        searchField.placeholderString = "Search snippets"
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search snippets for Secure Paste")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.isHidden = true
        searchContainer.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
        ])

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let panelBody = NSView()
        panelBody.translatesAutoresizingMaskIntoConstraints = false
        keyAppearanceCompensationView.translatesAutoresizingMaskIntoConstraints = false
        panelBody.addSubview(keyAppearanceCompensationView)
        panelBody.addSubview(searchContainer)
        panelBody.addSubview(scrollView)
        panelBody.addSubview(emptyLabel)
        searchContainerHeightConstraint = searchContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            keyAppearanceCompensationView.leadingAnchor.constraint(equalTo: panelBody.leadingAnchor),
            keyAppearanceCompensationView.trailingAnchor.constraint(equalTo: panelBody.trailingAnchor),
            keyAppearanceCompensationView.topAnchor.constraint(equalTo: panelBody.topAnchor),
            keyAppearanceCompensationView.bottomAnchor.constraint(equalTo: panelBody.bottomAnchor),

            searchContainer.leadingAnchor.constraint(equalTo: panelBody.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: panelBody.trailingAnchor),
            searchContainer.topAnchor.constraint(equalTo: panelBody.topAnchor),
            searchContainerHeightConstraint,

            scrollView.leadingAnchor.constraint(equalTo: panelBody.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panelBody.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panelBody.bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: panelBody.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: panelBody.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        let surface = LiquidGlassDesign.makeFloatingPanelSurface(containing: panelBody)

        // The surface is Auto Layout driven and has no size of its own, so pinning
        // it is mandatory. Setting `frame`/`autoresizingMask` on it instead is what
        // collapsed the panel in the earlier glass attempt (d00b1ea, reverted in
        // 7c6e918).
        let panelContentView = panel.contentView!
        // The inner clipper keeps table/search contents inside the glass, but the
        // window server derives `NSWindow`'s shadow from the top-level window shape.
        // Give that view the identical continuous mask as well: otherwise making
        // Secure Paste key reveals a rectangular black shadow behind the rounded
        // surface. `invalidateShadow()` in `present` then recomputes the retained
        // system shadow from this rounded alpha shape after every resize.
        panelContentView.wantsLayer = true
        panelContentView.layer?.cornerRadius = LiquidGlassDesign.effectivePanelCornerRadius
        panelContentView.layer?.cornerCurve = .continuous
        panelContentView.layer?.masksToBounds = true
        panelContentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor)
        ])

        super.init()

        panel.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        searchField.delegate = self
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        selectionWasUserDriven = true
        let snippet = items[row].snippet
        select(snippet)
    }

    var isVisible: Bool { panel.isVisible }
    var isSecurePasteVisible: Bool {
        presentationMode == .securePaste && panel.isVisible
    }

    func show(
        items: [SuggestionItem],
        anchorFocusedElement: AXUIElement? = nil,
        axBudget: AXMessagingBudget? = nil
    ) {
        guard presentationMode == .suggestions else { return }
        present(
            items: items,
            anchorFocusedElement: anchorFocusedElement,
            axBudget: axBudget,
            keepsPanelVisibleWhenEmpty: false,
            acceptsKeyboardInput: false,
            centersOnPointerScreen: false
        )
    }

    /// Presents the Command-Backslash picker as an input-enabled mode of the same
    /// compact panel used for backslash suggestions. With no text target, the picker
    /// centers on the pointer's display and selection becomes Copy.
    /// The non-activating panel leaves the destination app frontmost in either mode.
    func showSecurePaste(
        items: [SuggestionItem],
        anchorFocusedElement: AXUIElement?,
        copiesToClipboard: Bool,
        onSearch: @escaping (String) -> [SuggestionItem],
        onSelect: @escaping (Snippet) -> Void,
        onCancel: @escaping (Bool) -> Void
    ) {
        if presentationMode == .suggestions {
            dismiss()
        } else {
            dismissSecurePasteWithoutCallback()
        }

        presentationMode = .securePaste
        securePasteSearch = onSearch
        securePasteSelection = onSelect
        securePasteCancellation = onCancel
        securePasteStartedWithHiddenApplication = NSApp.isHidden
        panel.canHide = false
        keyAppearanceCompensationView.isEnabled = true
        searchField.stringValue = ""
        searchContainer.isHidden = false
        searchContainerHeightConstraint.constant = securePasteSearchHeight
        emptyLabel.stringValue = "No matching snippets"
        if copiesToClipboard {
            searchField.setAccessibilityLabel("Search snippets to copy")
            panel.setAccessibilityTitle("Copy Snippet")
            tableView.setAccessibilityLabel("Snippets available to copy")
        } else {
            searchField.setAccessibilityLabel("Search snippets for Secure Paste")
            panel.setAccessibilityTitle("Secure Paste")
            tableView.setAccessibilityLabel("Snippets available for Secure Paste")
        }

        present(
            items: items,
            anchorFocusedElement: anchorFocusedElement,
            axBudget: AXMessagingBudget(),
            keepsPanelVisibleWhenEmpty: true,
            acceptsKeyboardInput: true,
            centersOnPointerScreen: copiesToClipboard
        )
    }

    func cancelSecurePaste(returnFocus: Bool) {
        guard presentationMode == .securePaste else { return }
        let cancellation = securePasteCancellation
        dismissSecurePasteWithoutCallback()
        cancellation?(returnFocus)
    }

    func dismissSecurePasteWithoutCallback() {
        guard presentationMode == .securePaste else { return }
        let shouldRemainHidden = securePasteStartedWithHiddenApplication
        isEndingSecurePaste = true
        hidePanel()
        if shouldRemainHidden {
            // Losing key status to an outside click can make AppKit clear the
            // application's hidden state after the non-hideable panel is removed.
            // Reassert Cmd-H before returning to that click's event tracking.
            NSApp.hide(nil)
        }
        anchor = nil
        panel.makeFirstResponder(nil)
        keyAppearanceCompensationView.isEnabled = false
        searchField.stringValue = ""
        searchContainer.isHidden = true
        searchContainerHeightConstraint.constant = 0
        emptyLabel.isHidden = true
        securePasteSearch = nil
        securePasteSelection = nil
        securePasteCancellation = nil
        panel.canHide = true
        securePasteStartedWithHiddenApplication = false
        presentationMode = .suggestions
        searchField.setAccessibilityLabel("Search snippets for Secure Paste")
        panel.setAccessibilityTitle("Snippet suggestions")
        tableView.setAccessibilityLabel("Snippet suggestions")
        isEndingSecurePaste = false
    }

    private func present(
        items: [SuggestionItem],
        anchorFocusedElement: AXUIElement?,
        axBudget: AXMessagingBudget?,
        keepsPanelVisibleWhenEmpty: Bool,
        acceptsKeyboardInput: Bool,
        centersOnPointerScreen: Bool
    ) {
        let previouslySelectedSnippetID = selectionWasUserDriven ? selectedSnippet()?.id : nil
        self.items = items
        tableView.reloadData()

        let count = items.count
        guard count > 0 || keepsPanelVisibleWhenEmpty else {
            dismiss()
            return
        }

        // Resolve the anchor from the caret BEFORE computing the visible-row cap,
        // so screen metrics come from the caret's screen rather than falling back
        // to the screen containing the mouse. The anchor is captured once per
        // suggestion session to prevent the panel from jumping as the caret moves.
        if anchor == nil {
            // Timed because this is the one place the panel talks to a possibly-stalled host, and
            // the cost is invisible from the outside: a slow answer and a fast one both just place
            // the panel. Persistent diagnostics make the bounded timeout observable and
            // say which path placed the panel when a host is slow.
            let budget = axBudget ?? AXMessagingBudget()
            let resolution = centersOnPointerScreen
                ? resolveScreenCenterAnchor()
                : resolveAnchor(
                    focusedElement: anchorFocusedElement,
                    axBudget: budget
                )
            anchor = resolution.anchor
            // For the normal activation path this starts in the engine, before text-input
            // detection. Reporting only the panel slice would hide the very cumulative stall the
            // shared deadline prevents.
            let elapsedMS = budget.elapsedMilliseconds
            let source: DiagnosticSuggestionAnchorSource = switch resolution.source {
            case .caret: .caret
            case .focusedElement: .accessibility
            case .mouse: .mouse
            }
            let reason: DiagnosticSuggestionAnchorReason = switch resolution.reason {
            case "none": .success
            case "deadline", "timeout", "timeout-configuration": .timedOut
            case "focus-unavailable", "range-unavailable", "element-unavailable": .unavailable
            default: .unknown
            }
            Diagnostics.record(.suggestionAnchor(
                source: source,
                reason: reason,
                durationMilliseconds: Int64(elapsedMS.rounded())))
        }

        let visibleCount = min(count, maxVisible, maxVisibleRowsOnScreen)

        // Make sure the table has computed row geometry.
        tableView.noteNumberOfRowsChanged()
        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom

        let listHeight: CGFloat
        if visibleCount > 0 {
            // `rect(ofRow:)` already carries half of `intercellSpacing.height` above and
            // below every row, so `maxY` is the exact document height for the visible
            // prefix. `ceil` only guards a fractional row height landing on a half
            // point; the old +4 fudge dated from the visual effect view and would now
            // show as a strip of bare glass under the last row.
            let lastRowRect = tableView.rect(ofRow: visibleCount - 1)
            listHeight = ceil(lastRowRect.maxY + insets)
        } else {
            listHeight = securePasteEmptyListHeight
        }
        let height = listHeight + (presentationMode == .securePaste ? securePasteSearchHeight : 0)

        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))

        // Position using the anchor from when suggestions first activated.
        // This prevents the panel from jumping as the caret moves.
        positionPanelAtAnchor()

        // The panel is transparent and resizes on every keystroke; without this the
        // window shadow keeps the outline of the previous size.
        panel.invalidateShadow()

        scrollView.hasVerticalScroller = count > visibleCount
        emptyLabel.isHidden = presentationMode != .securePaste || count > 0

        if !panel.isVisible {
            if acceptsKeyboardInput {
                panel.orderFrontRegardless()
                if securePasteStartedWithHiddenApplication {
                    // `canHide == false` leaves just the picker on screen. Ordinary
                    // app windows obey Cmd-H and remain hidden throughout the flow.
                    NSApp.hide(nil)
                    panel.orderFrontRegardless()
                }
                panel.makeKey()
            } else {
                panel.orderFront(nil)
            }
            installClickMonitors()
        }

        guard count > 0 else {
            tableView.deselectAll(nil)
            selectionWasUserDriven = false
            if acceptsKeyboardInput {
                panel.makeFirstResponder(searchField)
            }
            return
        }

        let selectedRow = previouslySelectedSnippetID
            .flatMap { id in items.firstIndex { $0.snippet.id == id } }
            ?? 0
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedRow)
        if let preservedID = previouslySelectedSnippetID {
            selectionWasUserDriven = items[selectedRow].snippet.id == preservedID
        } else {
            selectionWasUserDriven = false
        }
        if acceptsKeyboardInput {
            panel.makeFirstResponder(searchField)
        }
    }


    /// Temporarily hide the panel (e.g. no results), preserving anchor position.
    func hide() {
        guard presentationMode == .suggestions else { return }
        hidePanel()
    }

    private func hidePanel() {
        removeClickMonitors()
        panel.orderOut(nil)
        items = []
        // Keep the table in sync with the emptied data source; otherwise it still
        // believes it has rows and any row materialization while hidden (e.g. an
        // accessibility client walking the table) indexes past the empty array.
        tableView.reloadData()
        selectionWasUserDriven = false
    }

    /// Fully end the suggestion session — clears anchor so next activation repositions.
    func dismiss() {
        guard presentationMode == .suggestions else { return }
        hidePanel()
        anchor = nil
    }

    func moveSelectionUp() {
        guard !items.isEmpty else { return }

        let current = tableView.selectedRow
        let next = current > 0 ? current - 1 : items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        selectionWasUserDriven = true
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }

        let current = tableView.selectedRow
        let next = current >= 0 && current < items.count - 1 ? current + 1 : 0
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        selectionWasUserDriven = true
    }

    func selectedSnippet() -> Snippet? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row].snippet
    }

    private func select(_ snippet: Snippet) {
        if presentationMode == .securePaste {
            let selection = securePasteSelection
            dismissSecurePasteWithoutCallback()
            selection?(snippet)
        } else {
            onSelect?(snippet)
        }
    }

    // MARK: - Secure Paste Search

    func controlTextDidChange(_ obj: Notification) {
        guard presentationMode == .securePaste,
              let securePasteSearch else { return }
        present(
            items: securePasteSearch(searchField.stringValue),
            anchorFocusedElement: nil,
            axBudget: nil,
            keepsPanelVisibleWhenEmpty: true,
            acceptsKeyboardInput: false,
            centersOnPointerScreen: false
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard presentationMode == .securePaste else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelectionUp()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelectionDown()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard let snippet = selectedSnippet() else {
                NSSound.beep()
                return true
            }
            select(snippet)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelSecurePaste(returnFocus: true)
            return true
        default:
            return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        // Key status is the transition that made AppKit replace the correctly
        // rounded inactive shadow with a rectangular one. Ensure the root mask has
        // reached the backing layer, then ask the window server to derive the key
        // shadow from that final shape rather than the panel's frame rectangle.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard presentationMode == .securePaste,
              panel.isVisible,
              !isEndingSecurePaste else { return }
        // A click can be in flight when AppKit posts this notification. Let the
        // clicked control finish first, then cancel without pulling focus back from
        // the destination the user just chose.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.presentationMode == .securePaste,
                  self.panel.isVisible,
                  !self.panel.isKeyWindow else { return }
            self.cancelSecurePaste(returnFocus: false)
        }
    }

    func resetAccessibilityPrimingCache() {
        accessibilityPrimedPIDs.removeAll()
        enhancedAccessibilityPrimedPIDs.removeAll()
    }

    // MARK: - Click-Outside Dismissal

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }
    }

    private func removeClickMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        if panelShapeContains(mouseLocation) { return }
        if presentationMode == .securePaste {
            cancelSecurePaste(returnFocus: false)
        } else {
            onDismiss?()
        }
    }

    /// `panel.frame` is a rectangle but the surface is a rounded rect, so the four
    /// corner regions sit inside the frame and outside the visible panel. A click
    /// there passes through the transparent pixels to the host app — testing the
    /// frame would keep the panel up while the caret moves out from under it.
    private func panelShapeContains(_ point: NSPoint) -> Bool {
        let frame = panel.frame
        guard frame.contains(point) else { return false }

        let radius = LiquidGlassDesign.effectivePanelCornerRadius
        let dx = min(point.x - frame.minX, frame.maxX - point.x)
        let dy = min(point.y - frame.minY, frame.maxY - point.y)
        guard dx < radius, dy < radius else { return true }

        return hypot(radius - dx, radius - dy) <= radius
    }

    // MARK: - Positioning

    private func positionPanelAtAnchor() {
        guard let anchor else { return }

        switch anchor {
        case .screenCenter(let visibleFrame):
            let origin = NSPoint(
                x: visibleFrame.midX - (panel.frame.width / 2),
                y: visibleFrame.midY - (panel.frame.height / 2)
            )
            panel.setFrameOrigin(clampedPanelOrigin(origin, in: visibleFrame))
        case .mouse(let point):
            // Captured once with the rest of the anchor, so filtering the list cannot make a
            // mouse fallback jump around after the user moves the pointer.
            var origin = point
            origin.y -= panel.frame.height + 4
            if let screen = screenContaining(point: origin) ?? NSScreen.main {
                origin = clampedPanelOrigin(origin, in: screen.visibleFrame)
            }
            panel.setFrameOrigin(origin)
        case .rect(let rect):
            // In AppKit coords: rect.origin is bottom-left, rect.maxY is top.
            // Place panel below the caret line (below rect.origin.y).
            var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - panel.frame.height - 4)

            // Keep on screen.
            if let screen = screenContaining(point: NSPoint(x: rect.midX, y: rect.midY))
                ?? screenIntersecting(rect)
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                if origin.y < visible.minY {
                    // Show above caret instead
                    origin.y = rect.maxY + 4
                }
                origin = clampedPanelOrigin(origin, in: visible)
            }

            panel.setFrameOrigin(origin)
        }
    }

    /// Copy mode has no text destination to anchor to. Center it on the display
    /// where the pointer currently is instead of treating the pointer itself as a
    /// caret; the latter pins a full-height picker to a screen edge when invoked
    /// from a game, the menu bar, or another non-text surface.
    private func resolveScreenCenterAnchor() -> AnchorResolution {
        let pointer = mousePosition()
        guard let screen = screenContaining(point: pointer)
                ?? NSScreen.main
                ?? NSScreen.screens.first else {
            return AnchorResolution(
                anchor: .mouse(pointer),
                source: .mouse,
                reason: "focus-unavailable"
            )
        }

        return AnchorResolution(
            anchor: .screenCenter(screen.visibleFrame),
            source: .mouse,
            reason: "none"
        )
    }

    private func resolveAnchor(
        focusedElement suppliedFocusedElement: AXUIElement?,
        axBudget: AXMessagingBudget
    ) -> AnchorResolution {
        let focused: AXUIElement
        if let suppliedFocusedElement {
            focused = suppliedFocusedElement
        } else if let acquired = frontmostFocusedElement(axBudget: axBudget) {
            focused = acquired
        } else {
            return AnchorResolution(
                anchor: .mouse(mousePosition()),
                source: .mouse,
                reason: axBudget.stopReason?.telemetryValue ?? "focus-unavailable"
            )
        }

        if let caretRect = caretScreenRect(of: focused, axBudget: axBudget) {
            return AnchorResolution(
                anchor: .rect(caretRect),
                source: .caret,
                reason: axBudget.stopReason?.telemetryValue ?? "none"
            )
        }

        // `.cannotComplete` or an exhausted wall-clock budget is terminal for this callback.
        // An AX-based fallback after it would just start another individually bounded wait.
        guard axBudget.canContinue else {
            return AnchorResolution(
                anchor: .mouse(mousePosition()),
                source: .mouse,
                reason: axBudget.stopReason?.telemetryValue ?? "deadline"
            )
        }

        // Reuse the exact focused object the engine already proved was a text input. Reacquiring
        // focus here used to repeat priming, traversal, and their timeouts on the same tap callback.
        if let elementRect = elementScreenRect(of: focused, axBudget: axBudget) {
            return AnchorResolution(
                anchor: .rect(elementRect),
                source: .focusedElement,
                reason: axBudget.stopReason?.telemetryValue ?? "range-unavailable"
            )
        }

        return AnchorResolution(
            anchor: .mouse(mousePosition()),
            source: .mouse,
            reason: axBudget.stopReason?.telemetryValue ?? "element-unavailable"
        )
    }

    /// Try to get precise caret rect using AXBoundsForRange.
    private func caretScreenRect(
        of focused: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> NSRect? {

        var rangeValue: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: focused,
            attribute: kAXSelectedTextRangeAttribute as CFString,
            into: &rangeValue
        ) == .success else {
            return nil
        }

        // Get the CFRange so we can create alternative ranges if needed
        var cfRange = CFRange(location: 0, length: 0)
        guard axValue(rangeValue, type: .cfRange, into: &cfRange),
              let rangeValue else {
            return nil
        }

        // Try the selected range first
        if let rect = boundsForRange(of: focused, range: rangeValue, axBudget: axBudget) {
            return normalizedAnchorRect(
                for: rect,
                focusedElement: focused,
                axBudget: axBudget
            )
        }

        // Zero-length selection may fail in some apps (Safari, etc.)
        // Try a 1-char range ending at the insertion point
        if cfRange.length == 0 && cfRange.location > 0 {
            var altRange = CFRange(location: cfRange.location - 1, length: 1)
            if let altRangeValue = AXValueCreate(.cfRange, &altRange) {
                // This gives us the rect of the character just before the cursor
                if let rect = boundsForRange(
                    of: focused,
                    range: altRangeValue as CFTypeRef,
                    axBudget: axBudget
                ) {
                    return normalizedAnchorRect(
                        for: rect,
                        focusedElement: focused,
                        axBudget: axBudget
                    )
                }
            }
        }

        return nil
    }

    /// Some native single-line fields report a caret line rect that sits inside the control.
    /// Keep caret X, but anchor vertically to the control's bottom so the panel appears below it.
    private func normalizedAnchorRect(
        for caretRect: NSRect,
        focusedElement: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> NSRect {
        guard let role = stringAttribute(
            of: focusedElement,
            attribute: kAXRoleAttribute as CFString,
            axBudget: axBudget
        ) else {
            return caretRect
        }

        guard let controlRect = preferredControlRect(
            for: focusedElement,
            caretRect: caretRect,
            axBudget: axBudget
        ) ?? elementScreenRect(of: focusedElement, axBudget: axBudget) else {
            return caretRect
        }

        let isSingleLineRole = role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)
        let isShortTextArea = role == (kAXTextAreaRole as String) && controlRect.height <= 56
        // Safari exposes nested AX elements in the address bar; allow this path for those
        // text-like roles so we can anchor below the containing control instead of line rect.
        let isSafariTextInput = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
            && (role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) || role == (kAXTextAreaRole as String))
            && controlRect.height <= 90
        guard isSingleLineRole || isShortTextArea || isSafariTextInput else { return caretRect }

        guard controlRect.insetBy(dx: -2, dy: -2).intersects(caretRect) else { return caretRect }

        var adjusted = caretRect
        adjusted.origin.y = controlRect.minY
        adjusted.size.height = max(caretRect.height, controlRect.height)
        return adjusted
    }

    private func boundsForRange(
        of element: AXUIElement,
        range: CFTypeRef,
        axBudget: AXMessagingBudget
    ) -> NSRect? {
        var bounds = CGRect.zero
        var boundsValue: CFTypeRef?
        guard axBudget.copyParameterizedAttributeValue(
            of: element,
            attribute: kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter: range,
            into: &boundsValue
        ) == .success else {
            return nil
        }

        guard axValue(boundsValue, type: .cgRect, into: &bounds) else {
            return nil
        }

        // Reject zero-size rects – some apps return success with garbage data
        guard bounds.width > 0 || bounds.height > 0 else { return nil }

        // Ensure a minimum height so the panel doesn't overlap the text
        if bounds.height < 14 { bounds.size.height = 14 }

        return axRectToAppKit(bounds)
    }

    /// Convert an AX rectangle (top-left origin) to an AppKit rect (bottom-left origin).
    private func axRectToAppKit(_ rect: CGRect) -> NSRect? {
        var candidates: [RectCandidate] = []

        if let screen = screenContainingAXTopLeftRect(rect) {
            candidates.append(
                RectCandidate(
                    rect: convertedAXTopLeftRect(rect, on: screen),
                    screen: screen,
                    priority: 3
                )
            )
        }

        let appKitAsIs = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        if let screen = screenContaining(point: NSPoint(x: appKitAsIs.midX, y: appKitAsIs.midY))
            ?? screenIntersecting(appKitAsIs) {
            // Some Chromium/Electron fields report AppKit-style global coordinates.
            candidates.append(RectCandidate(rect: appKitAsIs, screen: screen, priority: 2))
        }

        // A few apps appear to report screen-local top-left coordinates; keep those
        // as lower-priority candidates instead of accepting any intersecting rect.
        for screen in NSScreen.screens {
            candidates.append(
                RectCandidate(
                    rect: convertedScreenLocalAXTopLeftRect(rect, on: screen),
                    screen: screen,
                    priority: 1
                )
            )
        }

        if let best = bestRectCandidate(candidates) {
            return best
        }

        return NSScreen.main.map { convertedAXTopLeftRect(rect, on: $0) }
    }

    private func convertedAXTopLeftRect(_ rect: CGRect, on screen: NSScreen) -> NSRect {
        AXCoordinateSpace.convertAXTopLeftRect(
            rect,
            on: AXScreenGeometry(screen),
            primaryScreenHeight: primaryScreenHeight
        )
    }

    private func convertedScreenLocalAXTopLeftRect(_ rect: CGRect, on screen: NSScreen) -> NSRect {
        AXCoordinateSpace.convertScreenLocalAXTopLeftRect(rect, on: AXScreenGeometry(screen))
    }

    private func axTopLeftFrame(for screen: NSScreen) -> NSRect {
        AXCoordinateSpace.axTopLeftFrame(
            for: AXScreenGeometry(screen),
            primaryScreenHeight: primaryScreenHeight
        )
    }

    private var primaryScreenHeight: CGFloat {
        AXCoordinateSpace.primaryScreenHeight(
            from: NSScreen.screens.map(AXScreenGeometry.init),
            fallbackMainHeight: NSScreen.main?.frame.height ?? 0
        )
    }

    private func screenContainingAXTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let axRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        return NSScreen.screens.first { screen in
            axTopLeftFrame(for: screen).insetBy(dx: -1, dy: -1).intersects(axRect)
        }
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        if let frameMatch = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return frameMatch
        }
        return NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) })
    }

    private func screenIntersecting(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        }.flatMap { screen in
            intersectionArea(screen.frame, rect) > 0 ? screen : nil
        }
    }

    private func bestRectCandidate(_ candidates: [RectCandidate]) -> NSRect? {
        candidates
            .compactMap { candidate -> (candidate: RectCandidate, visibleArea: CGFloat, distance: CGFloat)? in
                let visibleArea = intersectionArea(candidate.screen.visibleFrame, candidate.rect)
                let frameArea = intersectionArea(candidate.screen.frame, candidate.rect)
                guard max(visibleArea, frameArea) > 0 else { return nil }

                let distance = distanceFromPoint(
                    NSPoint(x: candidate.rect.midX, y: candidate.rect.midY),
                    to: candidate.screen.visibleFrame
                )
                return (candidate, max(visibleArea, frameArea), distance)
            }
            .max { lhs, rhs in
                if lhs.visibleArea != rhs.visibleArea {
                    return lhs.visibleArea < rhs.visibleArea
                }
                if lhs.distance != rhs.distance {
                    return lhs.distance > rhs.distance
                }
                return lhs.candidate.priority < rhs.candidate.priority
            }?
            .candidate
            .rect
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private func distanceFromPoint(_ point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func clampedPanelOrigin(_ origin: NSPoint, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: clamped(origin.x, min: visible.minX, max: visible.maxX - panel.frame.width),
            y: clamped(origin.y, min: visible.minY, max: visible.maxY - panel.frame.height)
        )
    }

    private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }

    private func mousePosition() -> NSPoint {
        NSEvent.mouseLocation
    }

    private func frontmostFocusedElement(axBudget: AXMessagingBudget) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        primeAccessibilityIfNeeded(for: app, axBudget: axBudget)
        guard axBudget.canContinue else { return nil }

        if let focused = copyFocusedElement(from: app, axBudget: axBudget) {
            return deepestFocusedElement(
                startingAt: focused,
                maxDepth: 4,
                axBudget: axBudget
            )
        }
        guard axBudget.canContinue else { return nil }

        // Retry once after forcing manual accessibility attributes for Chromium/Electron.
        primeAccessibilityIfNeeded(for: app, force: true, axBudget: axBudget)
        guard axBudget.canContinue,
              let focused = copyFocusedElement(from: app, axBudget: axBudget) else {
            return nil
        }
        return deepestFocusedElement(
            startingAt: focused,
            maxDepth: 4,
            axBudget: axBudget
        )
    }

    private func copyFocusedElement(
        from app: NSRunningApplication,
        axBudget: AXMessagingBudget
    ) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard axBudget.bind(appElement) else { return nil }
        var focusedValue: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedUIElementAttribute as CFString,
            into: &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let focused = focusedValue as! AXUIElement
        return axBudget.bind(focused) ? focused : nil
    }

    private func deepestFocusedElement(
        startingAt root: AXUIElement,
        maxDepth: Int,
        axBudget: AXMessagingBudget
    ) -> AXUIElement? {
        var current = root

        for _ in 0..<maxDepth {
            var nestedValue: CFTypeRef?
            guard axBudget.copyAttributeValue(
                of: current,
                attribute: kAXFocusedUIElementAttribute as CFString,
                into: &nestedValue
            ) == .success,
                  let nestedValue,
                  CFGetTypeID(nestedValue) == AXUIElementGetTypeID() else {
                break
            }

            let nested = nestedValue as! AXUIElement
            guard axBudget.bind(nested) else { return nil }
            if CFEqual(current, nested) {
                break
            }

            current = nested
        }

        return axBudget.canContinue ? current : nil
    }

    private func stringAttribute(
        of element: AXUIElement,
        attribute: CFString,
        axBudget: AXMessagingBudget
    ) -> String? {
        var value: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: element,
            attribute: attribute,
            into: &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func axValue<T>(_ value: CFTypeRef?, type: AXValueType, into output: inout T) -> Bool {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return false
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else {
            return false
        }

        return withUnsafeMutablePointer(to: &output) { pointer in
            AXValueGetValue(axValue, type, pointer)
        }
    }

    private func elementScreenRect(
        of element: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> NSRect? {
        var posValue: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: element,
            attribute: kAXPositionAttribute as CFString,
            into: &posValue
        ) == .success else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: element,
            attribute: kAXSizeAttribute as CFString,
            into: &sizeValue
        ) == .success else {
            return nil
        }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard axValue(posValue, type: .cgPoint, into: &pos),
              axValue(sizeValue, type: .cgSize, into: &size) else {
            return nil
        }

        return axRectToAppKit(CGRect(origin: pos, size: size))
    }

    /// Walk up AX parents and pick the smallest plausible input control that still contains the caret.
    /// This avoids anchoring to Safari's inner text node, which can place the panel over typed text.
    private func preferredControlRect(
        for focusedElement: AXUIElement,
        caretRect: NSRect,
        axBudget: AXMessagingBudget
    ) -> NSRect? {
        let candidates = inputHierarchy(
            startingAt: focusedElement,
            maxDepth: 6,
            axBudget: axBudget
        ).compactMap { element -> NSRect? in
            guard let rect = elementScreenRect(of: element, axBudget: axBudget) else { return nil }
            guard rect.width >= 40, rect.height >= 16, rect.height <= 90 else { return nil }
            guard rect.insetBy(dx: -2, dy: -2).intersects(caretRect) else { return nil }
            return rect
        }

        guard !candidates.isEmpty else { return nil }

        // Prefer a control box larger than the raw caret line when available.
        if let expanded = candidates
            .filter({ $0.height > caretRect.height + 4 })
            .min(by: { rectArea($0) < rectArea($1) }) {
            return expanded
        }

        return candidates.min(by: { rectArea($0) < rectArea($1) })
    }

    private func inputHierarchy(
        startingAt element: AXUIElement,
        maxDepth: Int,
        axBudget: AXMessagingBudget
    ) -> [AXUIElement] {
        var elements: [AXUIElement] = [element]
        var current = element

        for _ in 0..<maxDepth {
            guard let parent = parentElement(of: current, axBudget: axBudget) else { break }
            elements.append(parent)
            current = parent
        }

        return elements
    }

    private func parentElement(
        of element: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard axBudget.copyAttributeValue(
            of: element,
            attribute: kAXParentAttribute as CFString,
            into: &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        let parent = value as! AXUIElement
        return axBudget.bind(parent) ? parent : nil
    }

    private func rectArea(_ rect: NSRect) -> CGFloat {
        rect.width * rect.height
    }

    private func primeAccessibilityIfNeeded(
        for app: NSRunningApplication,
        force: Bool = false,
        axBudget: AXMessagingBudget
    ) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let shouldSetEnhancedUI = isChromiumFamily(bundleIdentifier: app.bundleIdentifier)
        let hasManualPriming = accessibilityPrimedPIDs.contains(pid)
        let hasEnhancedPriming = enhancedAccessibilityPrimedPIDs.contains(pid)

        if !force && hasManualPriming && (!shouldSetEnhancedUI || hasEnhancedPriming) {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard axBudget.bind(appElement) else { return }

        // Electron documents this explicit opt-in switch for third-party ATs.
        if force || !hasManualPriming {
            let result = axBudget.setAttributeValue(
                of: appElement,
                attribute: "AXManualAccessibility" as CFString,
                value: kCFBooleanTrue
            )
            if AXMessagingBudget.primingResultIsCacheable(result) {
                accessibilityPrimedPIDs.insert(pid)
            }
        }

        // Chromium apps may require this to expose complete accessibility data
        // for non-VoiceOver assistive tools.
        if shouldSetEnhancedUI && (force || !hasEnhancedPriming) {
            let result = axBudget.setAttributeValue(
                of: appElement,
                attribute: "AXEnhancedUserInterface" as CFString,
                value: kCFBooleanTrue
            )
            if AXMessagingBudget.primingResultIsCacheable(result) {
                enhancedAccessibilityPrimedPIDs.insert(pid)
            }
        }
    }

    private func isChromiumFamily(bundleIdentifier: String?) -> Bool {
        ChromiumBundleIDSettings.isChromiumFamily(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SuggestionTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: SuggestionCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SuggestionCellView {
            cell = reused
        } else {
            cell = SuggestionCellView()
            cell.identifier = cellID
        }

        let item = items[row]
        cell.configure(
            name: item.snippet.displayName,
            keyword: item.snippet.normalizedKeyword,
            tags: item.snippet.tags,
            isSecure: item.isSecure,
            nameMatchRanges: item.nameMatchRanges,
            keywordMatchRanges: item.keywordMatchRanges,
            availableWidth: Self.panelWidth - horizontalCellPadding
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return singleLineRowHeight }
        return shouldWrapName(for: items[row]) ? wrappedNameRowHeight : singleLineRowHeight
    }

    private func shouldWrapName(for item: SuggestionItem) -> Bool {
        let name = item.snippet.displayName as NSString
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let availableWidth = Self.panelWidth - horizontalCellPadding
        let width = name.size(withAttributes: [.font: font]).width
        return width > availableWidth
    }
}

// MARK: - Cell View

private final class SuggestionCellView: NSTableCellView {
    private let primaryLabel = MatchHighlightLabel(labelWithString: "")
    private let secondaryLabel = MatchHighlightLabel(labelWithString: "")
    private let secureBadge = NSStackView()
    private let secureIcon = NSImageView()
    private let secureLabel = NSTextField(labelWithString: "Secure")
    private let tagChipsStack = NSStackView()
    private var renderedTags: [String] = []
    private var renderedChipWidth: CGFloat = -1
    private static let maxVisibleTagChips = 2
    private static let secondaryRowSpacing: CGFloat = 6
    private static let tagChipSpacing: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        primaryLabel.lineBreakMode = .byWordWrapping
        primaryLabel.maximumNumberOfLines = 2
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.maximumNumberOfLines = 1
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The keyword is what the user types against — it must not be clipped so
        // a tag chip can stay on screen. Chips yield first; staying below
        // .required still lets a keyword wider than the row truncate on its own
        // instead of breaking the row's width constraint.
        secondaryLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue + 1),
            for: .horizontal
        )

        let lockConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        secureIcon.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: "Secure snippet"
        )?.withSymbolConfiguration(lockConfiguration)
        secureIcon.contentTintColor = .systemOrange
        secureIcon.imageScaling = .scaleProportionallyDown
        secureIcon.translatesAutoresizingMaskIntoConstraints = false

        secureLabel.font = .systemFont(ofSize: 10, weight: .medium)
        secureLabel.textColor = .systemOrange
        secureLabel.maximumNumberOfLines = 1

        secureBadge.orientation = .horizontal
        secureBadge.spacing = 3
        secureBadge.alignment = .centerY
        secureBadge.addArrangedSubview(secureIcon)
        secureBadge.addArrangedSubview(secureLabel)
        secureBadge.setContentHuggingPriority(.required, for: .horizontal)
        secureBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        secureBadge.toolTip = "Secure snippet — authentication is required for every expansion"
        secureBadge.isHidden = true

        NSLayoutConstraint.activate([
            secureIcon.widthAnchor.constraint(equalToConstant: 10),
            secureIcon.heightAnchor.constraint(equalToConstant: 10),
        ])

        tagChipsStack.orientation = .horizontal
        tagChipsStack.spacing = Self.tagChipSpacing
        tagChipsStack.alignment = .centerY
        tagChipsStack.setContentHuggingPriority(.required, for: .horizontal)
        tagChipsStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let secondaryRow = NSStackView(views: [secondaryLabel, secureBadge, tagChipsStack])
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = Self.secondaryRowSpacing
        secondaryRow.alignment = .centerY
        secondaryRow.translatesAutoresizingMaskIntoConstraints = false

        let labelsStack = NSStackView(views: [primaryLabel, secondaryRow])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 1
        labelsStack.alignment = .leading
        labelsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelsStack)

        NSLayoutConstraint.activate([
            labelsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            labelsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelsStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            labelsStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),

            primaryLabel.widthAnchor.constraint(equalTo: labelsStack.widthAnchor),
            secondaryRow.widthAnchor.constraint(equalTo: labelsStack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        name: String,
        keyword: String,
        tags: [String],
        isSecure: Bool,
        nameMatchRanges: [NSRange],
        keywordMatchRanges: [NSRange],
        availableWidth: CGFloat
    ) {
        // Read once per cell rather than per label: the style is a defaults read,
        // and this runs for every visible row on every keystroke.
        let style = MatchHighlightPreference.style

        let nameRendering = MatchHighlightRenderer.render(
            name,
            font: .systemFont(ofSize: 13),
            baseColor: .labelColor,
            matchRanges: nameMatchRanges,
            style: style
        )
        primaryLabel.attributedStringValue = nameRendering.string
        primaryLabel.applyWash(ranges: nameRendering.washRanges, color: nameRendering.washColor)

        let keywordRendering = MatchHighlightRenderer.render(
            keyword,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            baseColor: .secondaryLabelColor,
            matchRanges: keywordMatchRanges,
            style: style
        )
        secondaryLabel.attributedStringValue = keywordRendering.string
        secondaryLabel.applyWash(ranges: keywordRendering.washRanges, color: keywordRendering.washColor)
        secondaryLabel.isHidden = keyword.isEmpty
        secureBadge.isHidden = !isSecure

        var fixedWidth: CGFloat = 0
        var fixedViewCount = 0
        if !keyword.isEmpty {
            fixedWidth += ceil(keywordRendering.string.size().width)
            fixedViewCount += 1
        }
        if isSecure {
            fixedWidth += ceil(secureBadge.fittingSize.width)
            fixedViewCount += 1
        }
        if fixedViewCount > 1 {
            fixedWidth += CGFloat(fixedViewCount - 1) * Self.secondaryRowSpacing
        }
        if !tags.isEmpty, fixedViewCount > 0 {
            fixedWidth += Self.secondaryRowSpacing
        }
        updateTagChips(tags: tags, availableWidth: max(0, availableWidth - fixedWidth))
    }

    /// Fits as many chips as the space left over by the keyword allows, so the
    /// keyword always renders in full. A "+N" chip only appears when it fits
    /// too; chips that don't fit are dropped rather than squeezed.
    private func updateTagChips(tags: [String], availableWidth: CGFloat) {
        guard tags != renderedTags || availableWidth != renderedChipWidth else { return }
        renderedTags = tags
        renderedChipWidth = availableWidth

        tagChipsStack.arrangedSubviews.forEach { view in
            tagChipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var visible: [String] = []
        var usedWidth: CGFloat = 0
        for tag in tags.prefix(Self.maxVisibleTagChips) {
            let chipWidth = TagChipView.width(for: tag)
            let spacing = visible.isEmpty ? 0 : Self.tagChipSpacing
            guard usedWidth + spacing + chipWidth <= availableWidth else { break }
            usedWidth += spacing + chipWidth
            visible.append(tag)
        }

        var hidden = Array(tags.dropFirst(visible.count))
        if !hidden.isEmpty {
            let overflowWidth = TagChipView.overflowChipWidth(hiddenCount: hidden.count)
            let spacing = visible.isEmpty ? 0 : Self.tagChipSpacing
            if visible.isEmpty || usedWidth + spacing + overflowWidth > availableWidth {
                hidden = []
            }
        }

        let chips = TagChipView.makeChips(visible: visible, hidden: hidden)
        chips.forEach(tagChipsStack.addArrangedSubview)
        tagChipsStack.isHidden = chips.isEmpty
    }

}
