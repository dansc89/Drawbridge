import AppKit
import PDFKit

private final class LayerColorChipButton: NSButton {
    var swatchColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let insetRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let corner = min(insetRect.width, insetRect.height) * 0.5
        let path = NSBezierPath(roundedRect: insetRect, xRadius: corner, yRadius: corner)
        swatchColor.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}

@MainActor
extension MainViewController {

    func tintColor(forSnapshotLayer layer: String) -> NSColor? {
        if let override = layerTintColorByName[layer] {
            return override
        }
        switch layer {
        case "DEFAULT":
            return nil
        case "ARCHITECTURAL":
            return NSColor(calibratedWhite: 0.72, alpha: 1.0)
        case "STRUCTURAL":
            return .systemRed
        case "MECHANICAL":
            return .systemGreen
        case "ELECTRICAL":
            return .systemOrange
        case "PLUMBING":
            return .systemBlue
        case "CIVL":
            return .systemTeal
        case "LANDSCAPE":
            return NSColor.systemGreen.blended(withFraction: 0.35, of: .systemBrown) ?? .systemGreen
        default:
            return .systemRed
        }
    }

    func applyLayerRenderingStyle(to snapshot: PDFSnapshotAnnotation, layer: String) {
        if let tint = tintColor(forSnapshotLayer: layer) {
            snapshot.renderTintColor = tint
            snapshot.renderTintStrength = 1.0
            snapshot.lineworkOnlyTint = true
        } else {
            snapshot.renderTintColor = nil
            snapshot.renderTintStrength = 0.0
            snapshot.lineworkOnlyTint = false
        }
    }

    func refreshLayerTintColorWell(for layer: String) {
        guard let colorButton = layerTintColorWells[layer] as? LayerColorChipButton else { return }
        colorButton.isEnabled = (layer != "DEFAULT")
        if let tint = tintColor(forSnapshotLayer: layer) {
            colorButton.swatchColor = tint.withAlphaComponent(1.0)
        } else {
            colorButton.swatchColor = .white
        }
        colorButton.alphaValue = (layer == "DEFAULT") ? 0.65 : 1.0
    }

    func refreshLayerVisibilityButton(for layer: String) {
        guard let button = layerVisibilityButtons[layer] else { return }
        let isVisible = layerVisibilityByName[layer] ?? true
        let symbolName = isVisible ? "eye" : "eye.slash"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isVisible ? "Visible" : "Hidden")
        button.contentTintColor = isVisible ? .secondaryLabelColor : .tertiaryLabelColor
    }

    func applyLayerTintColorToAllSnapshots(layer: String) {
        guard let document = pdfView.document else { return }
        var changedAny = false
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var markedDirty = false
            for annotation in page.annotations {
                guard let snapshot = annotation as? PDFSnapshotAnnotation else { continue }
                let snapshotLayer = snapshot.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard snapshotLayer == layer else { continue }
                applyLayerRenderingStyle(to: snapshot, layer: layer)
                changedAny = true
                markedDirty = true
            }
            if markedDirty {
                markPageMarkupCacheDirty(page)
            }
        }
        guard changedAny else { return }
        markMarkupChanged()
        applySnapshotLayerVisibility()
        updateStatusBar()
        scheduleAutosave()
    }

    @objc func layerVisibilityButtonChanged(_ sender: NSButton) {
        guard let layer = sender.identifier?.rawValue, !layer.isEmpty else { return }
        let current = layerVisibilityByName[layer] ?? true
        layerVisibilityByName[layer] = !current
        refreshLayerVisibilityButton(for: layer)
        applySnapshotLayerVisibility()
    }

    @objc func layerTintColorWellChanged(_ sender: NSButton) {
        guard let layer = sender.identifier?.rawValue, !layer.isEmpty else { return }
        guard layer != "DEFAULT" else {
            refreshLayerTintColorWell(for: layer)
            return
        }
        activeLayerTintSelection = layer
        let panel = NSColorPanel.shared
        panel.color = (tintColor(forSnapshotLayer: layer) ?? .white).withAlphaComponent(1.0)
        panel.setTarget(self)
        panel.setAction(#selector(layerTintColorPanelChanged(_:)))
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func layerTintColorPanelChanged(_ sender: NSColorPanel) {
        guard let layer = activeLayerTintSelection, layer != "DEFAULT" else { return }
        layerTintColorByName[layer] = sender.color.withAlphaComponent(1.0)
        applyLayerTintColorToAllSnapshots(layer: layer)
        refreshLayerTintColorWell(for: layer)
    }

    func applySnapshotLayerVisibility() {
        // Compatibility entry point: annotation authoring is unavailable.
    }

}
