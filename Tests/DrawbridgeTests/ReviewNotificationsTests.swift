import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewNotificationsTests: XCTestCase {
    private func alert(_ id: Int, read: Bool = false) -> [String: Any] {
        ["id": id, "document": ["id": "doc", "name": "Plans.pdf", "file_size": 123],
         "markupId": "markup", "page": 2, "bounds": [10,20,30,40], "sender": "alice@example.com",
         "kind": "line", "createdAt": 1_800_000_000_000, "readAt": read ? 1_800_000_000_001 : NSNull()]
    }
    func testInboxDeduplicatesPingsPagesAndScopesReadReceiptsToAccount() async throws {
        let suite = "ReviewNotificationsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = ReviewNotificationsInbox(defaults: defaults)
        var pings = 0, reads = 0, round = 0
        inbox.onPing = { pings += 1 }
        var api = SharedReviewAPI(origin: URL(string:"https://offline.invalid")!,token:"fake",displayName:"Bob",instanceID:"device")
        api.transport = { request in
            let body: [String: Any]
            if request.url!.path.hasSuffix("/read") { reads += 1; body = ["ok":true] }
            else {
                round += 1
                body = ["userId":"bob", "alerts": round == 1 ? [self.alert(5)] : [self.alert(5),self.alert(6)],
                        "cursor": round == 1 ? 5 : 6, "oldest":5,"hasMore":false]
            }
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        await inbox.poll(api:api,force:true)
        XCTAssertEqual(inbox.items.map(\.id),[5]); XCTAssertEqual(pings,1)
        await inbox.poll(api:api,force:true)
        XCTAssertEqual(inbox.items.map(\.id),[6,5]); XCTAssertEqual(pings,2)
        await inbox.poll(api:api,force:true)
        XCTAssertEqual(inbox.items.count,2); XCTAssertEqual(pings,2)
        await inbox.markRead(5,api:api)
        XCTAssertEqual(reads,1); XCTAssertEqual(inbox.unreadCount,1)
        var other = SharedReviewAPI(origin:api.origin,token:"other-fake",displayName:"Other",instanceID:"other")
        other.transport = { request in
            let data = Data(#"{"userId":"other","alerts":[],"cursor":0,"oldest":null,"hasMore":false}"#.utf8)
            return(data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        await inbox.poll(api:other,force:true)
        XCTAssertTrue(inbox.items.isEmpty); XCTAssertEqual(inbox.unreadCount,0)
    }
    func testPanelStartsHiddenAndUnbindsPreviousInbox() {
        let panel = ReviewNotificationsPanel(frame:.zero)
        XCTAssertTrue(panel.isHidden)
        let inbox = ReviewNotificationsInbox()
        panel.bind(inbox); XCTAssertEqual(panel.numberOfRows(in:panel.table),0)
        panel.bind(nil); XCTAssertEqual(panel.title.stringValue,"Notifications")
        XCTAssertTrue(panel.isHidden,"Binding an inbox must never show the panel on a local PDF")
    }
}
