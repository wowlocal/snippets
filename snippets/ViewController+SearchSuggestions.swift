import AppKit
import Carbon.HIToolbox

private enum SearchSuggestionOverlayMetrics {
    static let topMargin: CGFloat = 8
    static let horizontalMargin: CGFloat = 16
    static let minimumWidth: CGFloat = 320
}

extension ViewController {
    func buildSearchSuggestionOverlay(in rootView: NSView) {
        searchSuggestionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        searchSuggestionOverlayView.isHidden = true
        searchSuggestionOverlayView.onSelect = { [weak self] snippet in
            guard let self else { return }
            acceptSearchSuggestion(snippet)
        }

        rootView.addSubview(searchSuggestionOverlayView)

        let leading = searchSuggestionOverlayView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        let top = searchSuggestionOverlayView.topAnchor.constraint(equalTo: rootView.topAnchor)
        let width = searchSuggestionOverlayView.widthAnchor.constraint(equalToConstant: SearchSuggestionOverlayMetrics.minimumWidth)
        let height = searchSuggestionOverlayView.heightAnchor.constraint(equalToConstant: 1)

        NSLayoutConstraint.activate([leading, top, width, height])

        searchSuggestionLeadingConstraint = leading
        searchSuggestionTopConstraint = top
        searchSuggestionWidthConstraint = width
        searchSuggestionHeightConstraint = height
    }

    func updateSearchSuggestionOverlay() {
        guard shouldShowSearchSuggestionOverlay else {
            hideSearchSuggestionOverlay()
            return
        }

        searchSuggestionOverlayView.update(
            snippets: visibleSnippets,
            selectedSnippetID: selectedSnippetID
        )
        searchSuggestionOverlayView.isHidden = false
        updateSearchSuggestionOverlayLayout()
        installSearchSuggestionClickMonitorIfNeeded()
    }

    func updateSearchSuggestionOverlayLayout() {
        guard !searchSuggestionOverlayView.isHidden else { return }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let margin = SearchSuggestionOverlayMetrics.horizontalMargin
        let maxWidth = max(1, view.bounds.width - (margin * 2))
        let searchRect = searchFieldRectInRootView()
        let preferredWidth = max(
            SearchSuggestionOverlayMetrics.minimumWidth,
            min(searchRect.width, maxWidth)
        )
        let width = min(preferredWidth, maxWidth)
        let leading = min(
            max(searchRect.minX, margin),
            max(margin, view.bounds.width - margin - width)
        )
        let top = SearchSuggestionOverlayMetrics.topMargin
        let maxHeight = max(1, view.bounds.height - top - SearchSuggestionOverlayMetrics.horizontalMargin)
        let height = searchSuggestionOverlayView.preferredHeight(maxHeight: maxHeight)

        searchSuggestionLeadingConstraint?.constant = leading
        searchSuggestionTopConstraint?.constant = top
        searchSuggestionWidthConstraint?.constant = width
        searchSuggestionHeightConstraint?.constant = height
    }

    func hideSearchSuggestionOverlay() {
        guard !searchSuggestionOverlayView.isHidden || searchSuggestionClickMonitor != nil else { return }

        searchSuggestionOverlayView.isHidden = true

        if let searchSuggestionClickMonitor {
            NSEvent.removeMonitor(searchSuggestionClickMonitor)
            self.searchSuggestionClickMonitor = nil
        }
    }

    func dismissSearchInteraction() {
        hideSearchSuggestionOverlay()

        if isSidebarCollapsed {
            let target: NSResponder = selectedSnippetID == nil ? view : snippetTextView
            requestFirstResponder(target)
        } else {
            requestFirstResponder(tableView)
        }
    }

    var isSearchSuggestionOverlayVisible: Bool {
        !searchSuggestionOverlayView.isHidden
    }

    var shouldShowSearchSuggestionOverlay: Bool {
        guard isSidebarCollapsed else { return false }
        guard !visibleSnippets.isEmpty else { return false }

        return isSearchFieldActive || searchSuggestionOverlayView.containsFirstResponder(in: view.window)
    }

    var isSidebarCollapsed: Bool {
        if mainSidebarSplitItem?.isCollapsed == true {
            return true
        }

        guard let sidebarView = mainSplitView.subviews.first else { return false }
        return sidebarView.isHidden || sidebarView.frame.width <= 1
    }

    func handleSearchSuggestionKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if !isSearchSuggestionOverlayVisible {
            guard shouldActivateSearchSuggestionOverlay(forKeyCode: event.keyCode, flags: flags) else {
                return false
            }
            updateSearchSuggestionOverlay()
        }
        guard isSearchSuggestionOverlayVisible else { return false }

        if flags.isEmpty {
            switch event.keyCode {
            case UInt16(kVK_DownArrow):
                searchSuggestionOverlayView.moveSelectionDown()
                selectHighlightedSearchSuggestion()
                return true

            case UInt16(kVK_UpArrow):
                searchSuggestionOverlayView.moveSelectionUp()
                selectHighlightedSearchSuggestion()
                return true

            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                acceptHighlightedSearchSuggestion()
                return true

            default:
                return false
            }
        }

        if flags == [.control] {
            switch event.keyCode {
            case UInt16(kVK_ANSI_N):
                searchSuggestionOverlayView.moveSelectionDown()
                selectHighlightedSearchSuggestion()
                return true

            case UInt16(kVK_ANSI_P):
                searchSuggestionOverlayView.moveSelectionUp()
                selectHighlightedSearchSuggestion()
                return true

            default:
                return false
            }
        }

        return false
    }

    private func shouldActivateSearchSuggestionOverlay(
        forKeyCode keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        if flags.isEmpty {
            return keyCode == UInt16(kVK_DownArrow)
                || keyCode == UInt16(kVK_UpArrow)
                || keyCode == UInt16(kVK_Return)
                || keyCode == UInt16(kVK_ANSI_KeypadEnter)
        }

        if flags == [.control] {
            return keyCode == UInt16(kVK_ANSI_N)
                || keyCode == UInt16(kVK_ANSI_P)
        }

        return false
    }

    func selectSnippetFromSearchSuggestions(_ snippet: Snippet) {
        selectSnippet(id: snippet.id, focusEditorName: false)
        searchSuggestionOverlayView.update(
            snippets: visibleSnippets,
            selectedSnippetID: selectedSnippetID
        )
    }

    private func selectHighlightedSearchSuggestion() {
        guard let snippet = searchSuggestionOverlayView.selectedSnippet() else { return }
        selectSnippetFromSearchSuggestions(snippet)
    }

    private func acceptHighlightedSearchSuggestion() {
        guard let snippet = searchSuggestionOverlayView.selectedSnippet() else { return }
        acceptSearchSuggestion(snippet)
    }

    private func acceptSearchSuggestion(_ snippet: Snippet) {
        selectSnippetFromSearchSuggestions(snippet)
        hideSearchSuggestionOverlay()
        requestFirstResponder(snippetTextView)
    }

    private func searchFieldRectInRootView() -> NSRect {
        guard searchField.window === view.window else {
            let width = min(max(SearchSuggestionOverlayMetrics.minimumWidth, view.bounds.width * 0.75), view.bounds.width)
            return NSRect(
                x: (view.bounds.width - width) / 2,
                y: view.bounds.maxY,
                width: width,
                height: 0
            )
        }

        let fieldRectInWindow = searchField.convert(searchField.bounds, to: nil)
        return view.convert(fieldRectInWindow, from: nil)
    }

    private func installSearchSuggestionClickMonitorIfNeeded() {
        guard searchSuggestionClickMonitor == nil else { return }

        searchSuggestionClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, isSearchSuggestionOverlayVisible else { return event }

            if eventHitsSearchSuggestionOverlay(event) || eventHitsSearchField(event) {
                return event
            }

            hideSearchSuggestionOverlay()
            return event
        }
    }

    private func eventHitsSearchSuggestionOverlay(_ event: NSEvent) -> Bool {
        guard event.window === view.window else { return false }
        let point = searchSuggestionOverlayView.convert(event.locationInWindow, from: nil)
        return searchSuggestionOverlayView.bounds.contains(point)
    }

    func eventHitsSearchField(_ event: NSEvent) -> Bool {
        guard event.window === searchField.window else { return false }
        let point = searchField.convert(event.locationInWindow, from: nil)
        return searchField.bounds.contains(point)
    }
}
