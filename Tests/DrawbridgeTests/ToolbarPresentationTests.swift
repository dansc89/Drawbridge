import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class ToolbarPresentationTests: XCTestCase {
    func testInvertToggleDoesNotChangePDFOrMarkupState() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = try XCTUnwrap(buttons(controller.view).first { $0.identifier?.rawValue == "drawbridgeInvertColors" })
        XCTAssertFalse(button.isEnabled)
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 400, height: 300).fill(); image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument(); document.insert(page, at: 0)
        controller.pdfView.document = document
        controller.updateStatusBar()
        // PDFKit serializations generate fresh document IDs. Compare the actual
        // page rendering and geometry instead of those nondeterministic IDs.
        let before = page.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox).tiffRepresentation
        let bounds = page.bounds(for: .mediaBox)
        let scale = controller.pdfView.scaleFactor
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertTrue(controller.pdfView.isColorInverted)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(controller.pdfView.contentFilters.first?.name, "CIColorInvert")
        XCTAssertEqual(page.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox).tiffRepresentation, before)
        XCTAssertEqual(page.bounds(for: .mediaBox), bounds)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(controller.pdfView.rectangleMarkup.hasUnsavedChanges)
        XCTAssertEqual(controller.pdfView.scaleFactor, scale)
        let menu = NSMenuItem(title: "Invert", action: #selector(MainViewController.commandToggleInvert(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(menu)); XCTAssertEqual(menu.state, .on)
        button.performClick(nil)
        XCTAssertFalse(controller.pdfView.isColorInverted)
        XCTAssertEqual(button.state, .off)
        XCTAssertTrue(controller.pdfView.contentFilters.isEmpty)
        XCTAssertEqual(page.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox).tiffRepresentation, before)
    }

    func testMarkupPropertyMenusKeepTheirChoicesEnabled() {
        _ = NSApplication.shared
        let toolbar = RectangleMarkupToolbar(frame:.zero)
        for popup in [toolbar.colorPopup,toolbar.widthPopup,toolbar.fontPopup] {
            XCTAssertFalse(popup.menu?.autoenablesItems ?? true)
            XCTAssertTrue(popup.itemArray.allSatisfy(\.isEnabled))
        }
    }

    func testBusyCancellationRemainsClickableWhileDocumentIsLocked() {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.beginBusyIndicator("Testing")
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.setBusyCancelAction({})
        XCTAssertFalse(window.ignoresMouseEvents)
        controller.setBusyCancelAction(nil)
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.endBusyIndicator()
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testPageNavigationButtonsAreSeparateFromHistoryAndDisabledWithoutDocument() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = controller; window.layoutIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let all = buttons(controller.view)
        let previous = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgePreviousPage" })
        let next = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgeNextPage" })
        let back = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgeNavigateBack" })
        XCTAssertEqual(previous.action,#selector(MainViewController.commandPreviousPage(_:)))
        XCTAssertEqual(next.action,#selector(MainViewController.commandNextPage(_:)))
        XCTAssertEqual(back.action,#selector(MainViewController.commandNavigateBack(_:)))
        XCTAssertFalse(previous.isEnabled); XCTAssertFalse(next.isEnabled)
        XCTAssertNotNil(previous.image); XCTAssertNotNil(next.image)
        XCTAssertFalse(previous.superview === back.superview)
    }

    func testAppKitInstallsPrimaryCommandButtons() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbar = controller.makeToolbar()
        window.layoutIfNeeded()
        let toolbar = try XCTUnwrap(window.toolbar)
        let primary = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .drawbridgePrimaryControls }, "AppKit must install the commands, not just return their identifiers")
        XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == .drawbridgePrimaryControls } == true)
        let stack = try XCTUnwrap(primary.view as? NSStackView)
        XCTAssertNotNil(stack.superview)
        XCTAssertGreaterThan(stack.frame.width, 0)
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 7)
        XCTAssertEqual(buttons.map(\.action), [#selector(MainViewController.openPDF), #selector(MainViewController.commandAutoGenerateSheetNames(_:)), #selector(MainViewController.commandBatchLinkSheetNumbers(_:)), #selector(MainViewController.commandFlattenPDF(_:)), #selector(MainViewController.commandReduceFileSize(_:)), #selector(MainViewController.commandGoToSheet(_:)), #selector(MainViewController.commandFitPage(_:))])
        XCTAssertTrue(buttons.allSatisfy { $0.target === controller && !$0.isHidden && $0.image != nil })
        XCTAssertEqual(buttons[4].image?.name(), NSImage.Name("DrawbridgeCompressionClamp"))
        XCTAssertTrue(buttons[4].image?.isTemplate == true)
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.toolbarAllowedItemIdentifiers(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.outlineViewSelectionDidChange(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.splitViewDidResizeSubviews(_:))))
    }
}
