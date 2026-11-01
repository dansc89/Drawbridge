import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class ColorPickerTests: XCTestCase {
    func testEditableFieldResolvedContrastAcrossAppearanceSwitches() throws {
        let well = SwatchColorWell()
        let picker = SwatchPickerViewController(well: well)
        _ = picker.view
        for theme in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: theme))
            picker.view.appearance = appearance
            appearance.performAsCurrentDrawingAppearance {
                for field in [picker.hexField, picker.redField, picker.greenField, picker.blueField, picker.opacityField] {
                    // Do not substitute semantic colors for nil getters: that would hide a default-color defect.
                    print("FIELD_COLOR theme=\(theme.rawValue) field=\(field.toolTip ?? "") background=\(String(describing: field.backgroundColor)) text=\(String(describing: field.textColor)) draws=\(field.drawsBackground)")
                    guard let background = field.backgroundColor?.usingColorSpace(.sRGB),
                          let text = field.textColor?.usingColorSpace(.sRGB) else {
                        XCTFail("Missing actual field colors for \(theme.rawValue)"); continue
                    }
                    func luminance(_ color: NSColor, over background: NSColor? = nil) -> Double {
                        let channels: [Double] = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
                        let backing: [Double] = background.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] } ?? [0, 0, 0]
                        let alpha = Double(color.alphaComponent)
                        var linear: [Double] = []
                        for i in 0..<3 {
                            let v = channels[i] * alpha + backing[i] * (1.0 - alpha)
                            linear.append(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
                        }
                        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
                    }
                    let b = luminance(background), t = luminance(text, over: background)
                    let contrast = (max(b, t) + 0.05) / (min(b, t) + 0.05)
                    print("FIELD_RESOLVED theme=\(theme.rawValue) background=\(background) text=\(text) contrast=\(contrast)")
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(theme.rawValue) \(field.toolTip ?? "")")
                    XCTAssertTrue(field.isEditable)
                }
            }
        }
    }

    private final class Receiver: NSObject {
        var calls = 0
        @objc func changed(_ sender: NSColorWell) { calls += 1 }
    }

    private final class RecordingPopover: NSPopover {
        weak var anchor: NSView?
        var anchorRect: NSRect?
        override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
            anchor = positioningView
            anchorRect = positioningRect
        }
    }

    func testDetachedSwatchWellPresentsRelativeToAttachedAnchorWithoutGlobalPanel() throws {
        let well = SwatchColorWell()
        let popover = RecordingPopover()
        well.makeSwatchPopover = { popover }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 24, height: 24))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        let panelExisted = NSColorPanel.sharedColorPanelExists
        XCTAssertNil(well.window)
        well.showSwatches(relativeTo: anchor)
        XCTAssertTrue(popover.anchor === anchor)
        XCTAssertEqual(popover.anchorRect, anchor.bounds)
        XCTAssertTrue((popover.contentViewController as? SwatchPickerViewController)?.well === well)
        XCTAssertEqual(NSColorPanel.sharedColorPanelExists, panelExisted)
        XCTAssertFalse(window.isVisible)
    }

    func testSnapshotTintButtonCommitsOpaqueColorToMatchingSnapshotsOnly() throws {
        let controller = MainViewController(); _ = controller.view
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0)
        controller.pdfView.setMarkupDocument(document)
        let matching = PDFSnapshotAnnotation(bounds: NSRect(x: 10, y: 10, width: 30, height: 20), forType: .stamp)
        matching.snapshotLayerName = " STRUCTURAL "
        let other = PDFSnapshotAnnotation(bounds: NSRect(x: 50, y: 10, width: 30, height: 20), forType: .stamp)
        other.snapshotLayerName = "MECHANICAL"; other.renderTintColor = .green
        page.addAnnotation(matching); page.addAnnotation(other)
        let button = LayerColorChipButton(frame: .zero)
        button.identifier = NSUserInterfaceItemIdentifier("STRUCTURAL")
        button.target = controller; button.action = #selector(MainViewController.layerTintColorWellChanged(_:))
        controller.layerTintColorWells["STRUCTURAL"] = button
        let panelExisted = NSColorPanel.sharedColorPanelExists
        button.performClick(nil)
        XCTAssertTrue(button.tintWell.target === controller)
        XCTAssertEqual(button.tintWell.identifier, button.identifier)
        XCTAssertFalse(button.tintWell.allowsOpacity)
        XCTAssertFalse(button.tintWell.allowsNoColor)
        let version = controller.markupChangeVersion
        button.tintWell.selectColor(.blue.withAlphaComponent(0.2), preservingOpacity: true)
        XCTAssertEqual(SwatchColorValue.hex(try XCTUnwrap(matching.renderTintColor)), "#0000FF")
        XCTAssertEqual(matching.renderTintColor?.alphaComponent, 1)
        XCTAssertEqual(matching.renderTintStrength, 1)
        XCTAssertTrue(matching.lineworkOnlyTint)
        XCTAssertEqual(SwatchColorValue.hex(try XCTUnwrap(other.renderTintColor)), "#00FF00")
        XCTAssertEqual(controller.markupChangeVersion, version + 1)
        XCTAssertEqual(SwatchColorValue.hex(button.swatchColor), "#0000FF")
        XCTAssertEqual(controller.layerTintColorByName["STRUCTURAL"]?.alphaComponent, 1)
        button.tintWell.selectNoColor()
        XCTAssertEqual(controller.markupChangeVersion, version + 1)
        XCTAssertFalse(button.tintWell.isNoColor)
        XCTAssertNil(controller.activeLayerTintSelection)
        XCTAssertEqual(NSColorPanel.sharedColorPanelExists, panelExisted)
    }

    func testSnapshotTintButtonAnchorsPickerWithoutChangingExistingGlobalPanel() throws {
        let controller = MainViewController(); _ = controller.view
        let button = LayerColorChipButton(frame: NSRect(x: 10, y: 10, width: 24, height: 24))
        button.identifier = NSUserInterfaceItemIdentifier("ELECTRICAL")
        button.target = controller; button.action = #selector(MainViewController.layerTintColorWellChanged(_:))
        controller.layerTintColorWells["ELECTRICAL"] = button
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        try XCTUnwrap(window.contentView).addSubview(button)
        let popover = RecordingPopover(); button.tintWell.makeSwatchPopover = { popover }
        let panelExisted = NSColorPanel.sharedColorPanelExists
        let panel = panelExisted ? NSColorPanel.shared : nil
        let color = panel?.color
        let wasVisible = panel?.isVisible
        button.performClick(nil)
        XCTAssertTrue(popover.anchor === button)
        XCTAssertEqual(SwatchColorValue.hex(button.tintWell.color), SwatchColorValue.hex(try XCTUnwrap(controller.tintColor(forSnapshotLayer: "ELECTRICAL"))))
        XCTAssertEqual(button.action, #selector(MainViewController.layerTintColorWellChanged(_:)))
        XCTAssertTrue(button.target === controller)
        XCTAssertEqual(NSColorPanel.sharedColorPanelExists, panelExisted)
        XCTAssertEqual(panel?.color, color)
        XCTAssertEqual(panel?.isVisible, wasVisible)
    }

    func testDefaultSnapshotLayerDisablesChipAndRejectsTintCommit() {
        let controller = MainViewController(); _ = controller.view
        let button = LayerColorChipButton(frame: .zero)
        button.identifier = NSUserInterfaceItemIdentifier("DEFAULT")
        controller.layerTintColorWells["DEFAULT"] = button
        controller.refreshLayerTintColorWell(for: "DEFAULT")
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(button.tintWell.isEnabled)
        XCTAssertEqual(button.alphaValue, 0.65)
        controller.layerTintColorWellChanged(button)
        button.tintWell.selectColor(.red)
        XCTAssertNil(controller.layerTintColorByName["DEFAULT"])
        XCTAssertNil(controller.tintColor(forSnapshotLayer: "DEFAULT"))
        XCTAssertNil(button.tintWell.swatchPopover)
        XCTAssertFalse(button.tintWell.allowsNoColor)
    }

    func testInspectorUsesAnchoredSwatchesForEveryColorRole() {
        let inspector = MarkupPropertiesViewController()
        _ = inspector.view
        for well in [inspector.stroke, inspector.fill, inspector.hatchForeground, inspector.hatchBackground, inspector.snapshotColor] {
            XCTAssertTrue(well is SwatchColorWell)
        }
    }

    func testSelectionDispatchesOncePreservesAlphaAndProgrammaticSyncIsSilent() {
        let well = SwatchColorWell()
        let receiver = Receiver()
        well.target = receiver; well.action = #selector(Receiver.changed(_:))
        well.color = .red.withAlphaComponent(0.37)
        XCTAssertEqual(receiver.calls, 0)
        well.selectColor(.blue, preservingOpacity: true)
        XCTAssertEqual(receiver.calls, 1)
        XCTAssertEqual(well.color.alphaComponent, 0.37, accuracy: 0.001)
        XCTAssertEqual(well.color.usingColorSpace(.deviceRGB)!.blueComponent, 1, accuracy: 0.001)
        well.isEnabled = false
        well.selectColor(.green)
        XCTAssertEqual(receiver.calls, 1)
    }

    func testRGBOnlyRoleNeverPreservesTransparentInput() {
        let well = SwatchColorWell()
        well.allowsOpacity = false
        well.color = .red.withAlphaComponent(0.25)
        well.selectColor(.blue.withAlphaComponent(0.1), preservingOpacity: true)
        XCTAssertEqual(well.color.alphaComponent, 1, "RGB-only roles must override opacity preservation")
    }

    func testHexEntryValidatesAndSupportsExplicitAlpha() throws {
        XCTAssertNil(SwatchColorValue.parse("#GG0000"))
        XCTAssertNil(SwatchColorValue.parse("12345"))
        XCTAssertEqual(try XCTUnwrap(SwatchColorValue.parse("#33669980")).alphaComponent, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(SwatchColorValue.hex(try XCTUnwrap(SwatchColorValue.parse("369"))), "#336699")
    }

    func testRecentAndFavoritePersistenceDeduplicatesAndBounds() {
        let name = "ColorPickerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SwatchColorStore(defaults: defaults)
        for i in 0..<20 { store.remember(NSColor(srgbRed: CGFloat(i) / 20, green: 0, blue: 0, alpha: 0.5)) }
        store.remember(.blue); store.remember(.blue)
        XCTAssertEqual(store.recents.count, 12)
        store.toggleFavorite(.red.withAlphaComponent(0.4))
        let reloaded = SwatchColorStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.count, 1)
        XCTAssertEqual(reloaded.favorites.first?.alphaComponent ?? -1, 0.4, accuracy: 0.001)
        reloaded.toggleFavorite(.red.withAlphaComponent(0.4))
        XCTAssertTrue(reloaded.favorites.isEmpty)
    }

    func testCustomEntryCommitsRGBHexAndRejectsInvalidDrafts() {
        let well = SwatchColorWell(); well.color = .red.withAlphaComponent(0.4)
        let picker = SwatchPickerViewController(well: well); _ = picker.view
        picker.hexField.stringValue = "#336699"
        picker.applyHex()
        XCTAssertEqual(SwatchColorValue.hex(well.color), "#336699")
        XCTAssertEqual(well.color.alphaComponent, 0.4, accuracy: 0.001)
        picker.redField.stringValue = "12"; picker.greenField.stringValue = "34"; picker.blueField.stringValue = "56"
        picker.opacityField.stringValue = "25"; picker.applyRGB()
        XCTAssertEqual(SwatchColorValue.hex(well.color), "#0C2238")
        XCTAssertEqual(well.color.alphaComponent, 0.25, accuracy: 0.001)
        picker.redField.stringValue = "999"; picker.applyRGB()
        XCTAssertEqual(SwatchColorValue.hex(well.color), "#0C2238")
        picker.hexField.stringValue = "#invalid"; picker.applyHex()
        XCTAssertEqual(SwatchColorValue.hex(well.color), "#0C2238")
        XCTAssertGreaterThan(picker.view.fittingSize.width, 150)
        XCTAssertGreaterThan(picker.view.fittingSize.height, 200)
    }

    func testInspectorColorOpacityAndNoFillUseRealMutationUndoPaths() throws {
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0)
        let session = RectangleMarkupController(); session.bind(to: document)
        session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.create(on: page, bounds: NSRect(x: 20, y: 20, width: 100, height: 60)))
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        let oldColor = RectangleMarkupRecord.markupColor(annotation)
        let oldOpacity = MarkupStyle.strokeOpacity(annotation)
        inspector.stroke.selectColor(.blue.withAlphaComponent(0.42))
        XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.42, accuracy: 0.001)
        XCTAssertEqual(SwatchColorValue.hex(RectangleMarkupRecord.markupColor(annotation)), "#0000FF")
        session.undo.undo()
        XCTAssertEqual(SwatchColorValue.hex(RectangleMarkupRecord.markupColor(annotation)), SwatchColorValue.hex(oldColor))
        XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), oldOpacity, accuracy: 0.001)
        session.undo.redo(); inspector.refresh()
        session.undo.beginUndoGrouping(); inspector.fill.selectColor(.green.withAlphaComponent(0.3)); session.undo.endUndoGrouping()
        XCTAssertEqual(try XCTUnwrap(RectangleMarkupRecord.polygonFill(annotation)).alphaComponent, 0.3, accuracy: 0.001)
        session.undo.beginUndoGrouping(); inspector.fill.selectNoColor(); session.undo.endUndoGrouping()
        XCTAssertNil(RectangleMarkupRecord.polygonFill(annotation))
        session.undo.undo()
        XCTAssertEqual(try XCTUnwrap(RectangleMarkupRecord.polygonFill(annotation)).alphaComponent, 0.3, accuracy: 0.001)
    }

    func testNativeRGBActionPreservesOpacityWhilePickerEntriesPersistToolDefaults() throws {
        let name = "ColorPickerOpacity-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for tool: RectangleMarkupController.Tool in [.highlight, .rectangle, .text] {
            let session = RectangleMarkupController(defaults: defaults); session.tool = tool
            let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
            session.setLineAppearance(pattern: session.linePattern, opacity: 0.45); inspector.refresh()
            inspector.stroke.color = .orange
            XCTAssertTrue(inspector.stroke.sendAction(inspector.stroke.action, to: inspector.stroke.target))
            XCTAssertEqual(session.strokeOpacity, 0.45, accuracy: 0.001)
            inspector.stroke.selectColor(.blue, preservingOpacity: true)
            XCTAssertEqual(session.strokeOpacity, 0.45, accuracy: 0.001)
            let picker = SwatchPickerViewController(well: inspector.stroke); _ = picker.view
            picker.opacityField.stringValue = "27"; picker.commitFields(picker.opacityField)
            XCTAssertEqual(session.strokeOpacity, 0.27, accuracy: 0.001)
            picker.hexField.stringValue = "#33669980"; picker.commitFields(picker.hexField)
            XCTAssertEqual(session.strokeOpacity, 128.0 / 255, accuracy: 0.001)
            inspector.saveDefault(nil)
            let reloaded = RectangleMarkupController(defaults: defaults); reloaded.tool = tool
            XCTAssertEqual(reloaded.strokeOpacity, 128.0 / 255, accuracy: 0.001)
            XCTAssertEqual(SwatchColorValue.hex(reloaded.strokeColor), "#336699")
        }
    }

    func testPickerOpacityEntryChangesSelectedStrokeAndFillWithUndo() throws {
        let document = PDFDocument(), page = PDFPage(); document.insert(page, at: 0)
        let session = RectangleMarkupController(); session.bind(to: document)
        session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.create(on: page, bounds: NSRect(x: 20, y: 20, width: 100, height: 60)))
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.refresh()
        let previous = MarkupStyle.strokeOpacity(annotation)
        let strokePicker = SwatchPickerViewController(well: inspector.stroke); _ = strokePicker.view
        strokePicker.opacityField.stringValue = "23"; strokePicker.commitFields(strokePicker.opacityField)
        XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), 0.23, accuracy: 0.001)
        session.undo.undo(); XCTAssertEqual(MarkupStyle.strokeOpacity(annotation), previous, accuracy: 0.001)
        session.undo.redo(); inspector.refresh()
        let oldFill = RectangleMarkupRecord.polygonFill(annotation)
        let fillPicker = SwatchPickerViewController(well: inspector.fill); _ = fillPicker.view
        session.undo.beginUndoGrouping()
        fillPicker.opacityField.stringValue = "31"; fillPicker.commitFields(fillPicker.opacityField)
        session.undo.endUndoGrouping()
        XCTAssertEqual(try XCTUnwrap(RectangleMarkupRecord.polygonFill(annotation)).alphaComponent, 0.31, accuracy: 0.001)
        session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.polygonFill(annotation), oldFill)
        session.undo.redo()
        XCTAssertEqual(try XCTUnwrap(RectangleMarkupRecord.polygonFill(annotation)).alphaComponent, 0.31, accuracy: 0.001)
    }

    func testNoColorIsDistinctFromTransparentAndOnlyOfferedWhenAllowed() {
        let well = SwatchColorWell()
        well.selectNoColor()
        XCTAssertFalse(well.isNoColor)
        well.allowsNoColor = true
        well.selectNoColor()
        XCTAssertTrue(well.isNoColor)
        well.selectColor(.red.withAlphaComponent(0))
        XCTAssertFalse(well.isNoColor)
        XCTAssertEqual(well.color.alphaComponent, 0)
    }
}
