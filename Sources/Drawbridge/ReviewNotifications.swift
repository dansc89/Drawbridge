import AppKit
import Foundation
import CryptoKit

extension SharedReviewAPI {
    struct AlertRecipient: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let email: String?
        var label: String { email ?? name }
    }
    struct AlertRecipients: Decodable, Sendable { let users: [AlertRecipient] }
    struct ReviewNotification: Decodable, Sendable, Identifiable {
        let id: Int
        let document: Document
        let markupId: String
        let page: Int
        let bounds: [Double]
        let sender: String
        let kind: String
        let createdAt: Double
        var readAt: Double?
        var isValid: Bool {
            id > 0 && (0..<1_000_000).contains(page) && bounds.count == 4 && bounds.allSatisfy(\.isFinite)
                && bounds[2] >= 0 && bounds[3] >= 0 && markupId.utf8.count <= 512 && sender.utf8.count <= 512
                && !document.id.isEmpty && document.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        var region: CGRect { CGRect(x: bounds[0], y: bounds[1], width: max(2, bounds[2]), height: max(2, bounds[3])) }
    }
    struct NotificationsPage: Decodable, Sendable {
        let userId: String
        let alerts: [ReviewNotification]
        let cursor: Int
        let oldest: Int?
        let hasMore: Bool
    }
    struct AlertRequest: Encodable, Sendable {
        let sessionId: String
        let recipientId: String
        let markupId: String
        let clientId: String
    }
    struct AlertReceipt: Decodable, Sendable { let alert: ReviewNotification; let duplicate: Bool }
}

@MainActor final class ReviewNotificationsInbox {
    private final class Observer: NSObject { let callback: () -> Void; init(_ callback: @escaping () -> Void) { self.callback = callback } }
    private let observers = NSMapTable<NSObject, Observer>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var entries: [Int: SharedReviewAPI.ReviewNotification] = [:]
    private var identity: ObjectIdentifier?
    private var owner: String?
    private var origin: URL?
    private var highWaterMark = 0
    private var oldest: Int?
    private var loaded = false
    private var busy = false
    private var lastPoll = Date.distantPast
    private var pendingReads = Set<Int>()
    private var sendKeys: [String: (id: String, date: Date)] = [:]
    private(set) var items: [SharedReviewAPI.ReviewNotification] = []
    private(set) var canLoadOlder = false
    private(set) var status = "Loading alerts…"
    var unreadCount: Int { items.filter { $0.readAt == nil }.count }
    var onPing: () -> Void = { NSSound(named: "Glass")?.play() }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func observe(_ owner: NSObject, _ callback: @escaping () -> Void) { observers.setObject(Observer(callback), forKey: owner) }
    func removeObserver(_ owner: NSObject) { observers.removeObject(forKey: owner) }
    private func changed() { for observer in observers.objectEnumerator()?.allObjects as? [Observer] ?? [] { observer.callback() } }
    private var readKey: String? {
        guard let owner, let origin else { return nil }
        let hash = SHA256.hash(data: Data((origin.absoluteString + "|" + owner).utf8)).map { String(format: "%02x", $0) }.joined()
        return "DrawbridgeReviewPendingNotificationReads." + hash
    }
    private func saveReads() { if let key = readKey { defaults.set(Array(pendingReads).sorted(), forKey: key) } }
    func reset() {
        entries.removeAll(); items.removeAll(); pendingReads.removeAll(); sendKeys.removeAll()
        highWaterMark = 0; oldest = nil; owner = nil; identity = nil; origin = nil; loaded = false; canLoadOlder = false
        lastPoll = .distantPast; status = "Loading alerts…"; changed()
    }
    func retryKey(document: String, markup: String, recipient: String) -> String {
        let key = document + "|" + markup + "|" + recipient
        sendKeys = sendKeys.filter { Date().timeIntervalSince($0.value.date) < 300 }
        if let existing = sendKeys[key] { return existing.id }
        let id = UUID().uuidString; sendKeys[key] = (id, Date()); return id
    }
    func sent(document: String, markup: String, recipient: String) { sendKeys.removeValue(forKey: document + "|" + markup + "|" + recipient) }
    private func attach(_ api: SharedReviewAPI) {
        guard identity != api.sharedIdentityKey else { return }
        reset(); identity = api.sharedIdentityKey; origin = api.origin
    }
    private func merge(_ response: SharedReviewAPI.NotificationsPage, initial: Bool, older: Bool) throws {
        guard response.cursor >= 0, response.alerts.allSatisfy(\.isValid), response.alerts.allSatisfy({ $0.id <= response.cursor }) else { throw SharedReviewError("Invalid alert response.") }
        if let owner, owner != response.userId { throw SharedReviewError("Review account changed while loading alerts.") }
        if owner == nil {
            owner = response.userId
            if let key = readKey { pendingReads = Set((defaults.array(forKey: key) as? [Int] ?? []).filter { $0 > 0 }) }
        }
        let oldStatus = status, oldPagination = canLoadOlder
        var didChange = !loaded
        var newUnread = false
        for var item in response.alerts {
            if entries[item.id] == nil && item.readAt == nil { newUnread = true }
            if pendingReads.contains(item.id) { item.readAt = Date().timeIntervalSince1970 * 1000 }
            if entries[item.id] == nil || entries[item.id]?.readAt != item.readAt { didChange = true }
            entries[item.id] = item
        }
        highWaterMark = max(highWaterMark, response.cursor)
        if initial || older { oldest = response.oldest ?? oldest; canLoadOlder = response.hasMore }
        items = entries.values.sorted { $0.id > $1.id }
        loaded = true; status = items.isEmpty ? "No alerts yet" : ""
        if didChange || status != oldStatus || canLoadOlder != oldPagination { changed() }
        if newUnread && !older { onPing() }
    }
    func poll(api: SharedReviewAPI, force: Bool = false) async {
        attach(api)
        guard !busy, force || Date().timeIntervalSince(lastPoll) >= 3 else { return }
        busy = true; lastPoll = Date(); let expected = api.sharedIdentityKey
        defer { busy = false }
        do {
            let initial = !loaded
            let query = initial ? [] : [URLQueryItem(name: "after", value: String(highWaterMark))]
            let page: SharedReviewAPI.NotificationsPage = try await api.get("notifications", query: query)
            guard identity == expected else { return }
            try merge(page, initial: initial, older: false)
            for id in pendingReads.sorted().prefix(20) {
                do {
                    let _: SharedReviewAPI.OrganizationReceipt = try await api.post("notifications/\(id)/read", EmptyRequest())
                    guard identity == expected else { return }
                    pendingReads.remove(id); saveReads()
                } catch { break }
            }
            // Catch up a full new-event page on the next pass without a 3s delay.
            if !initial && page.hasMore { lastPoll = .distantPast }
        } catch {
            guard identity == expected else { return }
            let text = (error as? SharedReviewError)?.statusCode == 404 ? "Notifications need the updated Review server." : "Offline · alerts will refresh when connected."
            if status != text { status = text; changed() }
        }
    }
    func older(api: SharedReviewAPI) async {
        guard identity == api.sharedIdentityKey, !busy, canLoadOlder, let oldest else { return }
        busy = true; let expected = identity; defer { busy = false }
        do {
            let page: SharedReviewAPI.NotificationsPage = try await api.get("notifications", query: [URLQueryItem(name: "before", value: String(oldest))])
            guard identity == expected else { return }
            try merge(page, initial: false, older: true)
        } catch { status = "Couldn’t load older alerts. Try Refresh."; changed() }
    }
    func markRead(_ id: Int, api: SharedReviewAPI) async {
        guard identity == api.sharedIdentityKey, var item = entries[id] else { return }
        item.readAt = Date().timeIntervalSince1970 * 1000; entries[id] = item
        pendingReads.insert(id); saveReads(); items = entries.values.sorted { $0.id > $1.id }; changed()
        let expected = identity
        do {
            let _: SharedReviewAPI.OrganizationReceipt = try await api.post("notifications/\(id)/read", EmptyRequest())
            guard identity == expected else { return }
            pendingReads.remove(id); saveReads()
        } catch { /* A small durable receipt retries on the next authenticated poll. */ }
    }
    private struct EmptyRequest: Encodable { }
}
