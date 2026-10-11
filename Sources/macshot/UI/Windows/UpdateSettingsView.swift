import Cocoa

/// The update check on the About tab of Settings: the automatic check, the result of the
/// last check, Check Now and, when a new version is out, a button for its release page.
final class UpdateSettingsView: NSStackView {
    private let checker: UpdateChecker
    private let automaticCheckbox = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let releasePageButton = NSButton(title: "Open Release Page", target: nil, action: nil)

    init(checker: UpdateChecker = .shared) {
        self.checker = checker
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false

        automaticCheckbox.target = self
        automaticCheckbox.action = #selector(automaticChanged(_:))
        automaticCheckbox.state = Preferences.checkForUpdates ? .on : .off

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        for button in [checkNowButton, releasePageButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
        }
        checkNowButton.action = #selector(checkNow)
        releasePageButton.action = #selector(openReleasePage)
        let buttons = NSStackView(views: [checkNowButton, releasePageButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.detachesHiddenViews = true

        let note = NSTextField(wrappingLabelWithString: """
            macshot asks GitHub for the latest release once a day, and when you click Check Now. \
            It sends nothing about you or your captures. To update, download the new version and replace the app.
            """)
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.preferredMaxLayoutWidth = 420

        for view in [automaticCheckbox, statusLabel, buttons, note] {
            addArrangedSubview(view)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange),
                                               name: UpdateChecker.didChange, object: checker)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        statusLabel.stringValue = checker.statusText
        checkNowButton.isEnabled = checker.state != .checking
        if case .available = checker.state {
            releasePageButton.isHidden = false
        } else {
            releasePageButton.isHidden = true
        }
    }

    @objc private func stateDidChange() {
        refresh()
    }

    @objc private func automaticChanged(_ sender: NSButton) {
        Preferences.checkForUpdates = sender.state == .on
        Task { await checker.checkIfDue() }
    }

    @objc private func checkNow() {
        Task { await checker.check(showingResult: false) }
    }

    @objc private func openReleasePage() {
        if case .available(_, let page) = checker.state {
            NSWorkspace.shared.open(page)
        }
    }
}
