import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewLogoutLifecycleTests: XCTestCase {
    typealias Settings = SettingsWindowController
    let origin = URL(string: "https://offline.invalid")!

    func isolated(_ body: @MainActor () async throws -> Void) async throws {
        let active = Settings.activeReviewSession, attempted = Settings.attemptedSessionRestore
        let defaults = Settings.reviewSessionDefaults, delete = Settings.reviewSessionDelete
        let suite = "ReviewLogoutLifecycleTests." + UUID().uuidString
        Settings.reviewSessionDefaults = UserDefaults(suiteName: suite)!
        Settings.reviewSessionDelete = {}
        Settings.attemptedSessionRestore = true
        Settings.activeReviewSession = (origin, .init(token: "old-token", instanceId: "old-device", displayName: "Old User"))
        defer {
            Settings.reviewSessionDefaults.removePersistentDomain(forName: suite)
            Settings.reviewSessionDefaults = defaults; Settings.reviewSessionDelete = delete
            Settings.activeReviewSession = active; Settings.attemptedSessionRestore = attempted
        }
        try await body()
    }
    func response(_ request: URLRequest, _ text: String) -> (Data, URLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func capturedAPI(_ controller: SharedReviewWindowController) -> SharedReviewAPI? {
        Mirror(reflecting: controller).children.first { $0.label == "api" }?.value as? SharedReviewAPI
    }
    func testLogoutInvalidatesEveryRetainedControllerAndCapturedAPICopy() async throws {
        try await isolated {
            var requests = 0
            let controllers = [SharedReviewWindowController(), SharedReviewWindowController()]
            for controller in controllers {
                controller.makeReviewAPI = { origin, session in
                    var api = SharedReviewAPI(origin: origin, token: session.token, displayName: session.displayName, instanceID: session.instanceId)
                    api.transport = { request in
                        requests += 1
                        return self.response(request, request.url!.path == "/v1/projects" ? "{\"projects\":[{\"id\":\"p\",\"name\":\"Project\"}]}" : "{\"documents\":[]}")
                    }
                    return api
                }
                try await controller.loadDocuments()
            }
            let copies = try controllers.map { try XCTUnwrap(capturedAPI($0)) }
            Settings(editor: MainViewController()).signOutOfServer()
            let atLogout = requests
            for (controller, api) in zip(controllers, copies) {
                XCTAssertNil(capturedAPI(controller), "retained controller must release identity")
                do { let _: SharedReviewAPI.ProjectList = try await api.get("projects"); XCTFail("old API read accepted") } catch {}
                do { let _: SharedReviewAPI.Identity = try await api.claimUsername("another"); XCTFail("old API write accepted") } catch {}
            }
            XCTAssertEqual(requests, atLogout, "logout must block even captured API copies before transport")
        }
    }
    func testDelayedProjectsCannotIssueFollowupOrRestoreControllerAfterLogout() async throws {
        try await delayedCompletion(accountSwitch: false)
    }
    func testDelayedProjectsCannotIssueFollowupOrRestoreControllerAfterAccountSwitch() async throws {
        try await delayedCompletion(accountSwitch: true)
    }
    func testInvalidatedReloadCannotAdoptNewAccountUntilExplicitRefresh() async throws {
        try await isolated {
            let controller = SharedReviewWindowController()
            var constructions = 0, requests = 0
            controller.makeReviewAPI = { origin, session in
                constructions += 1
                XCTAssertEqual(session.token, "new-token")
                var api = SharedReviewAPI(origin: origin, token: session.token, displayName: session.displayName, instanceID: session.instanceId)
                api.transport = { request in
                    requests += 1
                    return self.response(request, request.url!.path == "/v1/projects" ? "{\"projects\":[{\"id\":\"p\",\"name\":\"Project\"}]}" : "{\"documents\":[]}")
                }
                return api
            }
            Settings(editor: MainViewController()).signOutOfServer()
            Settings.activeReviewSession = (origin, .init(token: "new-token", instanceId: "new-device", displayName: "New User"))
            do { try await controller.loadDocuments(); XCTFail("implicit stale reload reauthorized") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(constructions, 0, "invalidated reload must fail before API construction")
            XCTAssertEqual(requests, 0)
            XCTAssertNil(capturedAPI(controller))
            controller.perform(NSSelectorFromString("refreshDocuments:"), with: nil)
            for _ in 0..<1000 { if self.capturedAPI(controller) != nil { break }; await Task.yield() }
            XCTAssertNotNil(capturedAPI(controller), "explicit browser refresh must authorize the new identity")
            XCTAssertEqual(constructions, 1)
            XCTAssertEqual(requests, 2)
        }
    }
    func testCanceledReloadFailsBeforeAPIConstruction() async throws {
        try await isolated {
            let controller = SharedReviewWindowController()
            var constructions = 0, requests = 0
            controller.makeReviewAPI = { origin, session in
                constructions += 1
                var api = SharedReviewAPI(origin: origin, token: session.token, displayName: session.displayName, instanceID: session.instanceId)
                api.transport = { request in
                    requests += 1
                    return self.response(request, "{\"projects\":[]}")
                }
                return api
            }
            let task = Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { try await controller.loadDocuments(); return false }
                catch { return error is CancellationError }
            }
            let canceled = await task.value
            XCTAssertTrue(canceled)
            XCTAssertEqual(constructions, 0, "even a non-invalidated canceled reload must not construct an API")
            XCTAssertEqual(requests, 0)
            XCTAssertNil(capturedAPI(controller))
        }
    }
    func delayedCompletion(accountSwitch: Bool) async throws {
        try await isolated {
            let controller = SharedReviewWindowController()
            var requests = 0
            var resume: CheckedContinuation<Void, Never>?
            controller.makeReviewAPI = { origin, session in
                var api = SharedReviewAPI(origin: origin, token: session.token, displayName: session.displayName, instanceID: session.instanceId)
                api.transport = { request in
                    requests += 1
                    if requests == 1 { await withCheckedContinuation { resume = $0 } }
                    return self.response(request, request.url!.path == "/v1/projects" ? "{\"projects\":[{\"id\":\"p\",\"name\":\"Project\"}]}" : "{\"documents\":[]}")
                }
                return api
            }
            let task = Task { () -> Bool in
                do { try await controller.loadDocuments(); return true } catch { return false }
            }
            for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
            let completion = try XCTUnwrap(resume)
            if accountSwitch {
                Settings.activeReviewSession = (origin, .init(token: "new-token", instanceId: "new-device", displayName: "New User"))
                NotificationCenter.default.post(name: Settings.reviewSessionDidChange, object: nil)
            } else { Settings(editor: MainViewController()).signOutOfServer() }
            completion.resume()
            let accepted = await task.value
            XCTAssertFalse(accepted, "stale completion must be rejected")
            XCTAssertEqual(requests, 1, "no follow-up document read with old bearer")
            XCTAssertNil(capturedAPI(controller))
        }
    }
}
