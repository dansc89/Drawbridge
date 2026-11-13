import CryptoKit
import AppKit
import Security

/// Resolve dynamic colors again when macOS changes appearance while Settings is open.
@MainActor private final class SettingsSidebarStack: NSStackView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
    func refreshBackground() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AppAppearance.sidebar.cgColor
        }
    }
}

/// A single retained, nonmodal native settings surface. Edits apply only within their section.
@MainActor final class SettingsWindowController: NSWindowController {
    enum Section: String, CaseIterable {
        case general = "General", shortcuts = "Keyboard Shortcuts", performance = "Performance", interface = "Interface"
    }
    private weak var editor: MainViewController?
    private let content = NSStackView()
    private let navigation = SettingsSidebarStack()
    private var panes: [Section: NSView] = [:]
    private var author = NSTextField()
    private let serverDomain = NSTextField()
    private let serverStatus = NSTextField(labelWithString: "")
    private lazy var serverSignOut = button("Sign Out", #selector(signOutOfServer))
    private let serverLoginForm = NSStackView()
    private let reviewEmail = NSTextField()
    private let reviewCode = NSTextField()
    private lazy var sendReviewCode = button("Send Code", #selector(requestReviewCode))
    private lazy var verifyReviewCode = button("Sign In", #selector(redeemReviewCode))
    private var emailChallenge: (origin: URL, email: String, id: String)?
    private var signingIn = false
    // Injectable boundaries keep offline auth tests away from browser and user Keychain.
    var reviewAuthTransport: ReviewGoogleSignIn.Transport = ReviewGoogleSignIn.liveTransport
    var reviewGoogleIdentityToken: ((String) async throws -> String)?
    var reviewDeviceKey: ((URL, String) throws -> String)?
    private static var reviewAuthGeneration = UUID()
    private static func checkReviewAuthGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == reviewAuthGeneration else { throw CancellationError() }
    }

    func reviewSignIn(origin: URL, useGoogle: Bool, username: String, password: String,
                      markupAuthor: String) async throws -> ServerSession {
        let generation = Self.reviewAuthGeneration
        let flow = ReviewGoogleSignIn(transport: reviewAuthTransport)
        let config = try await flow.configuration(origin: origin)
        try Self.checkReviewAuthGeneration(generation)
        if useGoogle {
            let clientID = try config.googleClientID()
            let idToken: String
            if let provider = reviewGoogleIdentityToken {
                idToken = try await provider(clientID)
            } else {
                let attempt = try ReviewGoogleSignIn.Attempt()
                let listener = try ReviewOAuthLoopback()
                defer { listener.cancel() }
                let url = try attempt.authorizationURL(clientID: clientID, redirect: listener.redirect)
                guard NSWorkspace.shared.open(url) else { throw SharedReviewError("Could not open the browser for Google sign-in.") }
                let callback = try await listener.callback()
                try Self.checkReviewAuthGeneration(generation)
                let code = try attempt.code(from: callback, redirect: listener.redirect)
                idToken = try await flow.idToken(code: code, clientID: clientID, redirect: listener.redirect, attempt: attempt)
                try attempt.validateNonce(in: idToken)
            }
            try Self.checkReviewAuthGeneration(generation)
            let key = try reviewDeviceKey?(origin, "google-sso") ?? Self.sharedReviewDeviceKey(origin: origin, username: "google-sso")
            let session = try await flow.exchange(origin: origin, idToken: idToken, deviceKey: key)
            try Self.checkReviewAuthGeneration(generation)
            return session
        }
        guard config.allowsPassword else { throw SharedReviewError("Password sign-in is not enabled on this server. Use Google or contact your administrator.") }
        guard !username.isEmpty, !password.isEmpty else { throw SharedReviewError("Enter your office login and password.") }
        let key = try reviewDeviceKey?(origin, username) ?? Self.sharedReviewDeviceKey(origin: origin, username: username)
        var request = URLRequest(url: origin.appendingPathComponent("v1/auth/login"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password, "markupAuthor": markupAuthor, "deviceKey": key])
        let data = try await reviewAuthTransport(request)
        try Self.checkReviewAuthGeneration(generation)
        return try JSONDecoder().decode(ServerSession.self, from: data)
    }
    static var activeReviewSession: (origin: URL, session: ServerSession)?
    static var attemptedSessionRestore = false
    static var reviewSessionDefaults = UserDefaults.standard
    // Session-only injection: offline tests never touch the user's Keychain.
    static var reviewSessionRead: @MainActor () throws -> Data? = readSessionData
    static var reviewSessionWrite: @MainActor (Data) -> Bool = writeSessionData
    static var reviewSessionDelete: @MainActor () -> Void = deleteSessionData

    private static func readSessionData() throws -> Data? {
        var query = serverKeychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = withoutKeychainPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess else { throw SharedReviewError("Review session is unavailable.") }
        return result as? Data
    }
    private static func writeSessionData(_ data: Data) -> Bool {
        let query = serverKeychainQuery
        return withoutKeychainPrompts {
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            return updated == errSecItemNotFound
                ? SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
                : updated
        } == errSecSuccess
    }
    private static func deleteSessionData() {
        _ = withoutKeychainPrompts { SecItemDelete(serverKeychainQuery as CFDictionary) }
    }
    @discardableResult
    static func persistReviewSession(origin: URL, session: ServerSession) throws -> Bool {
        let origin = try ReviewGoogleSignIn.origin(origin.absoluteString)
        guard validReviewSession(session) else { throw SharedReviewError("Invalid Review session. Sign in again.") }
        let saved = reviewSessionWrite(try JSONEncoder().encode(StoredReviewSession(version: 1, origin: origin.absoluteString, session: session)))
        reviewSessionDefaults.set(!saved, forKey: skipSessionRestoreKey)
        reviewSessionDefaults.set(origin.absoluteString, forKey: "sharedServerDomain")
        return saved
    }
    private static let skipSessionRestoreKey = "DrawbridgeSkipReviewSessionRestore"
    private struct StoredReviewSession: Codable {
        let version: Int
        let origin: String
        let session: ServerSession
    }
    private static func validReviewSession(_ session: ServerSession) -> Bool {
        [session.token, session.instanceId, session.displayName ?? ""].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
    private static let serverKeychainService = (Bundle.main.bundleIdentifier ?? "com.drawbridge.app") + ".shared-session"
    private var keys: [ShortcutAction: NSTextField] = [:]
    private var modifiers: [ShortcutAction: NSPopUpButton] = [:]
    private let validation = NSTextField(labelWithString: "")
    private let adaptive = NSButton(checkboxWithTitle: "Adaptive index cap for very large PDFs", target: nil, action: nil)
    private let cap = NSTextField()
    private let watchdog = NSButton(checkboxWithTitle: "Enable main-thread stall watchdog logging", target: nil, action: nil)
    private let threshold = NSTextField()
    private let mode = NSPopUpButton()
    private let preset = NSPopUpButton()
    private var primaryLabels: [NSTextField] = []

    init(editor: MainViewController) {
        self.editor = editor
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(section: Section = .general) {
        if window == nil { buildWindow() }
        for pane in content.arrangedSubviews { content.removeArrangedSubview(pane); pane.removeFromSuperview() }
        if let pane = panes[section] { content.addArrangedSubview(pane) }
        if section == .general { refreshServerLogin() }
        for case let button as NSButton in navigation.arrangedSubviews {
            button.state = button.title == section.rawValue ? .on : .off
        }
        window?.title = "Settings — \(section.rawValue)"
        applyTheme()
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 460)
        self.window = window
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 8
        navigation.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        for section in Section.allCases {
            let button = NSButton(title: section.rawValue, target: self, action: #selector(selectSection(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.alignment = .left
            navigation.addArrangedSubview(button)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        let root = NSStackView(views: [navigation, NSBox(), content])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        if let divider = root.arrangedSubviews[1] as? NSBox { divider.boxType = .separator }
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 200), content.widthAnchor.constraint(greaterThanOrEqualToConstant: 540)
        ])
        buildGeneral(); buildShortcuts(); buildPerformance(); buildInterface()
    }

    private func pane(_ section: Section, _ views: [NSView]) {
        let title = NSTextField(labelWithString: section.rawValue)
        primaryLabels.append(title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let stack = NSStackView(views: [title] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        panes[section] = stack
    }
    private func help(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return field
    }
    private func field(_ field: NSTextField, id: String, value: String) -> NSTextField {
        field.identifier = NSUserInterfaceItemIdentifier(id); field.stringValue = value
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return field
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ title: String, _ control: NSView) -> NSView {
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        primaryLabels.append(label)
        return NSStackView(views: [label, control])
    }
    private func buildGeneral() {
        let defaults = UserDefaults.standard
        serverDomain.placeholderString = "https://review.example.com"
        serverStatus.lineBreakMode = .byTruncatingTail
        serverStatus.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let reviewName = NSTextField(labelWithString: "")
        reviewName.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.drawbridgeReviewUsername",
                        options: [.nullPlaceholder: "Choose when opening a review"])
        serverLoginForm.orientation = .vertical
        serverLoginForm.alignment = .leading
        serverLoginForm.spacing = 8
        serverLoginForm.detachesHiddenViews = true
        for view in [
            row("Server domain", field(serverDomain, id: "serverDomain", value: defaults.string(forKey: "sharedServerDomain") ?? "")),
            row("Work email", field(reviewEmail, id: "reviewEmail", value: "")),
            row("Verification code", field(reviewCode, id: "reviewCode", value: "")),
            NSStackView(views: [sendReviewCode, verifyReviewCode])
        ] { serverLoginForm.addArrangedSubview(view) }
        pane(.general, [
            row("Markup author", field(author, id: "markupAuthor", value: MarkupAuthorPreference.currentName)),
            help("Used for new markups. Leave blank to use your macOS account name."),
            button("Save General", #selector(saveGeneral)),
            serverLoginForm, serverStatus, serverSignOut,
            row("Review username", reviewName)
        ])
    }

    func refreshServerLogin(message: String? = nil) {
        let current = try? Self.sharedReviewCredentials()
        serverLoginForm.isHidden = current != nil
        serverSignOut.isHidden = current == nil
        sendReviewCode.isEnabled = !signingIn && current == nil
        verifyReviewCode.isEnabled = !signingIn && current == nil && emailChallenge != nil
        if let message { serverStatus.stringValue = message }
        else if let (_, session) = current {
            serverStatus.stringValue = session.displayName.map { "Signed in as " + $0 } ?? "Signed in to Review."
        } else if !signingIn { serverStatus.stringValue = "" }
    }

    // Review credentials use the macOS file-based Keychain. Silence its UI only
    // for the duration of each synchronous operation, including update and delete.
    private static func withoutKeychainPrompts(_ action: () -> OSStatus) -> OSStatus {
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return errSecInteractionNotAllowed
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return action()
    }

    private static var serverKeychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serverKeychainService,
         kSecAttrAccount as String: "session"]
    }

    static let reviewSessionDidChange = Notification.Name("DrawbridgeReviewSessionDidChange")

    @objc func signOutOfServer() {
        Self.reviewAuthGeneration = UUID()
        let previousSession = Self.activeReviewSession
        Self.activeReviewSession = nil
        // If Keychain is locked, prevent the old entry from restoring next launch.
        Self.reviewSessionDefaults.set(true, forKey: Self.skipSessionRestoreKey)
        Self.reviewSessionDelete()
        Self.reviewSessionDefaults.removeObject(forKey: "drawbridgeReviewUsername")
        emailChallenge = nil
        reviewCode.stringValue = ""
        refreshServerLogin(message: "Signed out on this Mac.")
        NotificationCenter.default.post(name: Self.reviewSessionDidChange, object: nil)
        if let (origin, session) = previousSession, session.workspaceIdentity == true {
            let transport = reviewAuthTransport
            let generation = Self.reviewAuthGeneration
            Task {
                var request = URLRequest(url: origin.appendingPathComponent("v1/auth/logout"), timeoutInterval: 15)
                request.httpMethod = "POST"
                request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
                do {
                    _ = try await transport(request)
                } catch {
                    guard generation == Self.reviewAuthGeneration, Self.activeReviewSession == nil else { return }
                    refreshServerLogin(message: "Signed out on this Mac. The server could not confirm sign-out.")
                }
            }
        }
    }

    private func emailRequest(origin: URL, endpoint: String, values: [String: String]) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent("v1/auth/email/" + endpoint), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(values)
        return try await reviewAuthTransport(request)
    }

    @objc private func requestReviewCode() {
        runEmailSignIn(message: "Sending code…") {
            struct Challenge: Decodable { let challengeId: String }
            self.emailChallenge = nil
            self.reviewCode.stringValue = ""
            let origin = try ReviewGoogleSignIn.origin(self.serverDomain.stringValue)
            let email = self.reviewEmail.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let data = try await self.emailRequest(origin: origin, endpoint: "request", values: ["email": email])
            let challenge = try JSONDecoder().decode(Challenge.self, from: data)
            self.emailChallenge = (origin, email, challenge.challengeId)
            self.serverStatus.stringValue = "Check your work inbox for the six-digit code."
            self.window?.makeFirstResponder(self.reviewCode)
        }
    }

    @objc private func redeemReviewCode() {
        guard let challenge = emailChallenge else { return }
        runEmailSignIn(message: "Verifying code…") {
            let generation = Self.reviewAuthGeneration
            let origin = try ReviewGoogleSignIn.origin(self.serverDomain.stringValue)
            let email = self.reviewEmail.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard origin == challenge.origin, email == challenge.email else {
                throw SharedReviewError("Request a new code for this server and work email.")
            }
            let code = self.reviewCode.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = try await self.emailRequest(origin: origin, endpoint: "verify",
                                                   values: ["challengeId": challenge.id, "code": code])
            try Self.checkReviewAuthGeneration(generation)
            let session = try JSONDecoder().decode(ServerSession.self, from: data)
            guard session.workspaceIdentity == true, !session.token.isEmpty, !session.instanceId.isEmpty else {
                throw SharedReviewError("The server did not return a verified Review identity.")
            }
            let saved = try Self.persistReviewSession(origin: origin, session: session)
            Self.activeReviewSession = (origin, session)
            self.emailChallenge = nil
            self.reviewCode.stringValue = ""
            NotificationCenter.default.post(name: Self.reviewSessionDidChange, object: nil)
            let suffix = saved ? "" : " for this launch"
            self.refreshServerLogin(message: "Signed in as " + (session.displayName ?? "Review user") + suffix + ".")
        }
    }

    private func runEmailSignIn(message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !signingIn, Self.activeReviewSession == nil else { return }
        window?.makeFirstResponder(nil)
        signingIn = true
        sendReviewCode.isEnabled = false
        verifyReviewCode.isEnabled = false
        serverStatus.stringValue = message
        Task {
            defer {
                signingIn = false
                sendReviewCode.isEnabled = Self.activeReviewSession == nil
                verifyReviewCode.isEnabled = Self.activeReviewSession == nil && emailChallenge != nil
            }
            do { try await action() }
            catch let error as SharedReviewError {
                switch error.statusCode {
                case 400: serverStatus.stringValue = "Enter a valid work email or six-digit code."
                case 401: serverStatus.stringValue = "That code is invalid or expired. Try again or request a new code."
                case 429: serverStatus.stringValue = "Too many code requests. Wait before requesting another code."
                case 503: serverStatus.stringValue = "Email delivery is unavailable. Try again later."
                default: serverStatus.stringValue = error.localizedDescription
                }
            } catch { serverStatus.stringValue = error.localizedDescription }
        }
    }

    struct ServerSession: Codable {
        let token: String
        let instanceId: String
        let displayName: String?
        var workspaceIdentity: Bool? = nil
    }

    static func sharedReviewCredentials() throws -> (URL, ServerSession) {
        if let activeReviewSession { return activeReviewSession }
        defer { attemptedSessionRestore = true }
        if !attemptedSessionRestore, !reviewSessionDefaults.bool(forKey: skipSessionRestoreKey),
           let domain = reviewSessionDefaults.string(forKey: "sharedServerDomain"),
           let url = try? ReviewGoogleSignIn.origin(domain) {
            if let data = try? reviewSessionRead(),
               let stored = try? JSONDecoder().decode(StoredReviewSession.self, from: data),
               stored.version == 1,
               let boundOrigin = try? ReviewGoogleSignIn.origin(stored.origin),
               stored.origin == boundOrigin.absoluteString,
               boundOrigin == url, validReviewSession(stored.session) {
                activeReviewSession = (boundOrigin, stored.session)
                return (boundOrigin, stored.session)
            }
        }
        throw SharedReviewError("Sign in under Drawbridge → Settings → General.")
    }

    private static func sharedReviewDeviceKey(origin: URL, username: String) throws -> String {
        var query = serverKeychainQuery
        query[kSecAttrAccount as String] = "review-device:" + origin.absoluteString + ":" + username.lowercased()
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = withoutKeychainPrompts { SecItemCopyMatching(lookup as CFDictionary, &result) }
        if status == errSecSuccess, let data = result as? Data,
           let key = String(data: data, encoding: .utf8) { return key }
        guard status == errSecItemNotFound else { throw SharedReviewError("Drawbridge can’t access your Review identity. Unlock the login keychain in Keychain Access and try again.") }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        query[kSecValueData as String] = Data(key.utf8)
        guard withoutKeychainPrompts({ SecItemAdd(query as CFDictionary, nil) }) == errSecSuccess else {
            throw SharedReviewError("Could not save your shared review identity in Keychain.")
        }
        return key
    }

    static func authenticate(origin: URL, username: String, password: String, markupAuthor: String, deviceKey: String) async throws -> ServerSession {
        var request = URLRequest(url: origin.appendingPathComponent("v1/auth/login"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password, "markupAuthor": markupAuthor, "deviceKey": deviceKey])
        let session = URLSession(configuration: .ephemeral, delegate: ServerLoginRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (response as? HTTPURLResponse)?.statusCode == 401
                ? "The server rejected the username or password." : "The server could not complete sign-in."
            throw NSError(domain: "DrawbridgeServerLogin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(ServerSession.self, from: data)
    }

    @objc private func saveGeneral() {
        window?.makeFirstResponder(nil)
        UserDefaults.standard.set(author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: MarkupAuthorPreference.defaultsKey)
    }
    private func buildShortcuts() {
        guard let editor else { return }
        var views: [NSView] = [help("Customize Select Text, Invert, Show/Hide Hyperlinks, Highlight, and Match Properties bindings. All other tool shortcuts remain unchanged. Use one letter, number, or supported punctuation character.")]
        for action in ShortcutAction.allCases {
            let binding = editor.currentShortcutBinding(for: action)
            let key = field(NSTextField(), id: "shortcut.\(action.rawValue)", value: binding.key.uppercased())
            let modifier = NSPopUpButton(); modifier.addItems(withTitles: ["None", "Shift", "Cmd+Shift", "Ctrl", "Cmd+Option+Shift"])
            modifier.selectItem(at: ShortcutModifier.allCases.firstIndex(of: binding.modifier) ?? 0)
            keys[action] = key; modifiers[action] = modifier
            views.append(row(action.displayName, NSStackView(views: [modifier, key])))
        }
        validation.textColor = .systemRed
        views += [validation, NSStackView(views: [button("Save Shortcuts", #selector(saveShortcuts)), button("Restore Defaults", #selector(restoreShortcuts))])]
        pane(.shortcuts, views)
    }
    @objc private func saveShortcuts() {
        window?.makeFirstResponder(nil)
        guard let editor else { return }
        var updated: [ShortcutAction: ShortcutBinding] = [:]; var seen = Set<String>()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]\\;',./`-="))
        for action in ShortcutAction.allCases {
            let key = keys[action]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.count == 1, key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { validation.stringValue = "Each shortcut must use a single supported character."; return }
            let binding = ShortcutBinding(key: key, modifier: ShortcutModifier.allCases[modifiers[action]!.indexOfSelectedItem])
            guard seen.insert(binding.encoded).inserted else { validation.stringValue = "Each shortcut combination can only be assigned once."; return }
            updated[action] = binding
        }
        editor.shortcutBindings = updated; editor.saveShortcutBindings(); editor.updateShortcutHintLabel()
        validation.stringValue = "Shortcuts saved."
    }
    @objc private func restoreShortcuts() {
        editor?.resetShortcutBindingsToDefaults()
        for action in ShortcutAction.allCases {
            keys[action]?.stringValue = action.defaultBinding.key.uppercased()
            modifiers[action]?.selectItem(at: ShortcutModifier.allCases.firstIndex(of: action.defaultBinding.modifier)!)
        }
        validation.stringValue = "Defaults restored."
    }
    private func buildPerformance() {
        guard let editor else { return }
        let defaults = UserDefaults.standard
        adaptive.state = defaults.bool(forKey: MainViewController.defaultsAdaptiveIndexCapEnabledKey) ? .on : .off
        watchdog.state = defaults.bool(forKey: MainViewController.defaultsWatchdogEnabledKey) ? .on : .off
        pane(.performance, [adaptive, row("Max indexed markups", field(cap, id: "indexCap", value: "\(editor.configuredIndexCap())")), watchdog, row("Stall threshold (seconds)", field(threshold, id: "watchdogThreshold", value: "\(max(0.5, defaults.double(forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)))")), help("Watchdog logs: ~/Library/Application Support/Drawbridge/Logs/watchdog.log"), button("Apply Performance", #selector(savePerformance))])
    }
    @objc private func savePerformance() {
        window?.makeFirstResponder(nil)
        guard let editor else { return }
        let defaults = UserDefaults.standard
        defaults.set(adaptive.state == .on, forKey: MainViewController.defaultsAdaptiveIndexCapEnabledKey)
        defaults.set(min(max(cap.integerValue, editor.minimumIndexedMarkupItems), editor.maximumIndexedMarkupItems), forKey: MainViewController.defaultsIndexCapKey)
        defaults.set(watchdog.state == .on, forKey: MainViewController.defaultsWatchdogEnabledKey)
        defaults.set(min(max(threshold.doubleValue, 0.5), 30), forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)
        editor.configureWatchdogFromDefaults()
        editor.scheduleMarkupsRefresh(selecting: editor.currentSelectedAnnotation())
        cap.integerValue = defaults.integer(forKey: MainViewController.defaultsIndexCapKey)
        threshold.doubleValue = defaults.double(forKey: MainViewController.defaultsWatchdogThresholdSecondsKey)
    }
    private func buildInterface() {
        mode.addItems(withTitles: ["Follow macOS", "Custom Colors"])
        preset.addItems(withTitles: InterfaceTheme.presets.map(\.title))
        let theme = InterfaceTheme.current
        mode.selectItem(at: theme == .system ? 0 : 1)
        preset.selectItem(at: InterfaceTheme.presets.firstIndex(of: theme) ?? 0)
        preset.isEnabled = theme != .system
        mode.target = self; mode.action = #selector(changeTheme)
        preset.target = self; preset.action = #selector(changeTheme)
        mode.identifier = NSUserInterfaceItemIdentifier("interfaceMode")
        preset.identifier = NSUserInterfaceItemIdentifier("interfacePreset")
        pane(.interface, [row("Appearance", mode), row("Palette", preset), help("Follow macOS keeps automatic light and dark appearance. Custom Colors changes only the interface, never PDF pages, markup colors, or PDF inversion. Native selection, focus rings, and accessibility contrast remain enabled.")])
    }
    @objc private func changeTheme() {
        preset.isEnabled = mode.indexOfSelectedItem == 1
        InterfaceTheme.select(mode.indexOfSelectedItem == 0 ? .system : InterfaceTheme.presets[preset.indexOfSelectedItem])
        applyTheme()
    }
    @objc private func selectSection(_ sender: NSButton) {
        if let section = Section(rawValue: sender.title) { prepare(section: section) }
    }
    private func applyTheme() {
        let theme = InterfaceTheme.current
        AppAppearance.applyInterface(to: window)
        navigation.refreshBackground()
        for label in primaryLabels { label.textColor = theme.color(for: "foreground") ?? .labelColor }
        for case let button as NSButton in navigation.arrangedSubviews {
            button.bezelColor = theme.color(for: "accent")
        }
    }
}

private final class ServerLoginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
