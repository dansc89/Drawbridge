import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewCapabilityPresentationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testBrowserIdentifiesApplicationSeparatelyFromWorkspace() throws {
        let controller = SharedReviewWindowController()
        controller.buildWindow() // Construct only; never show or activate a window.
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        XCTAssertEqual(window.title, "Drawbridge Review — Server Documents")
        XCTAssertEqual(window.subtitle, "")
        let path = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSPathControl }.first)
        XCTAssertEqual(path.pathItems.map(\.title), ["Server Documents"])
    }

    func testExplanationMatrixMatchesExistingGatesWithoutInventingCapabilities() {
        for busy in [false, true] {
            for folders in [false, true] {
                for organization in [false, true] {
                    for selection in [0, 1, 3] {
                        let state = ReviewCapabilityPresentation(busy: busy, foldersAvailable: folders,
                                                                 organizationActions: organization, selectionCount: selection)
                        XCTAssertEqual(state.newFolderReason == nil, !busy && folders && organization)
                        XCTAssertEqual(state.deleteReason == nil, !busy && organization && selection > 0)
                        if !folders { XCTAssertTrue(state.newFolderToolTip.contains("has not advertised folder support")) }
                        if !organization { XCTAssertTrue(state.deleteToolTip.contains("has not advertised deletion support")) }
                        if busy {
                            XCTAssertTrue(state.newFolderToolTip.contains("Wait for the current operation"))
                            XCTAssertTrue(state.deleteToolTip.contains("Wait for the current operation"))
                        }
                        if organization && selection == 0 { XCTAssertTrue(state.deleteToolTip.contains("Select one or more")) }
                        XCTAssertEqual(state.explanation.isEmpty, !busy && folders && organization && selection > 0)
                    }
                }
            }
        }
    }

    func testOptionalCapabilityResponseStaysFailClosedAndEmptyFoldersAreSupported() throws {
        for json in [#"{"documents":[]}"#, #"{"documents":[],"folders":null,"organizationActions":false}"#] {
            let list = try JSONDecoder().decode(SharedReviewAPI.DocumentList.self, from: Data(json.utf8))
            let state = ReviewCapabilityPresentation(busy: false, foldersAvailable: list.folders != nil,
                                                     organizationActions: list.organizationActions == true, selectionCount: 1)
            XCTAssertNotNil(state.newFolderReason)
            XCTAssertNotNil(state.deleteReason)
        }
        let list = try JSONDecoder().decode(SharedReviewAPI.DocumentList.self,
            from: Data(#"{"documents":[],"folders":[],"organizationActions":true}"#.utf8))
        let state = ReviewCapabilityPresentation(busy: false, foldersAvailable: list.folders != nil,
                                                 organizationActions: list.organizationActions == true, selectionCount: 1)
        XCTAssertNil(state.newFolderReason)
        XCTAssertNil(state.deleteReason)
        XCTAssertTrue(state.deleteToolTip.contains("after confirming"))
    }

    func testDecodedDocumentDeletionCapabilityIsRetainedSeparately() throws {
        for value in [true, false] {
            let json = "{\"documents\":[],\"organizationActions\":false,\"documentDeletion\":\(value)}"
            let list = try JSONDecoder().decode(SharedReviewAPI.DocumentList.self, from: Data(json.utf8))
            // Inspect decoded storage so an unknown JSON key silently ignored by Decodable fails at runtime.
            let decoded = Mirror(reflecting: list).children.first { $0.label == "documentDeletion" }?.value as? Bool
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(list.organizationActions, false)
        }
    }

    func testWorkspaceNameIsDisclosedVerbatimAndNeverUsedAsApplicationIdentity() {
        for name in ["Example Review Pilot", "Design & Engineering", "日本語 Workspace"] {
            XCTAssertEqual(ReviewCapabilityPresentation.subtitle(workspace: name), "Workspace: " + name)
            XCTAssertEqual(ReviewCapabilityPresentation.browserTitle, "Drawbridge Review — Server Documents")
        }
        XCTAssertEqual(ReviewCapabilityPresentation.subtitle(workspace: nil), "")
    }

    func testUnavailableControlsExplainMissingServerCapabilitiesPersistently() throws {
        let controller = SharedReviewWindowController()
        controller.buildWindow()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let items = try XCTUnwrap(window.toolbar).items
        let folder = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "review.newFolder" })
        let delete = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "review.delete" })
        XCTAssertFalse(folder.isEnabled)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(folder.toolTip?.contains("has not advertised folder support") == true)
        XCTAssertTrue(delete.toolTip?.contains("has not advertised deletion support") == true)
        let fields = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
        let explanation = fields.first { $0.identifier?.rawValue == "review.capabilityExplanation" }
        XCTAssertNotNil(explanation, "Disabled toolbar items need a persistent, accessible explanation too")
        XCTAssertTrue(explanation?.stringValue.contains("New Folder unavailable") == true)
        XCTAssertTrue(explanation?.stringValue.contains("Delete unavailable") == true)
        XCTAssertFalse(explanation?.isHidden ?? true)
    }
}
