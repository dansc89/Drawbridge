import AppKit
import PDFKit

@MainActor
extension MainViewController {
    func ensureLayerVisibilityDefaults() {
        for layer in snapshotLayerOptions where layerVisibilityByName[layer] == nil {
            layerVisibilityByName[layer] = true
        }
    }

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

    func selectedStatusLayerName() -> String {
        let selected = statusLayerPopup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty {
            return selected
        }
        return snapshotLayerOptions.first ?? "DEFAULT"
    }

    func refreshStatusLayerControls() {
        let layer = selectedStatusLayerName()
        let isDefaultLayer = layer == "DEFAULT"
        statusLayerColorWell.isEnabled = !isDefaultLayer
        if let tint = tintColor(forSnapshotLayer: layer) {
            statusLayerColorWell.color = tint.withAlphaComponent(1.0)
        } else {
            statusLayerColorWell.color = .white
        }
    }

    func refreshLayerTintColorWell(for layer: String) {
        guard let well = layerTintColorWells[layer] else { return }
        well.isEnabled = (layer != "DEFAULT")
        if let tint = tintColor(forSnapshotLayer: layer) {
            well.color = tint.withAlphaComponent(1.0)
        } else {
            well.color = .white
        }
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
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
        scheduleAutosave()
    }

    func promptSnapshotLayerSelection(
        defaultLayer: String = "ARCHITECTURAL",
        messageText: String = "What layer?",
        informativeText: String = "Choose the layer for this pasted grab.",
        confirmTitle: String = "Apply",
        cancelTitle: String = "Cancel"
    ) -> String? {
        ensureLayerVisibilityDefaults()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
        popup.addItems(withTitles: snapshotLayerOptions)
        if let idx = snapshotLayerOptions.firstIndex(of: defaultLayer) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        popup.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: accessory.centerYAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    func configureLayersSectionUI() {
        ensureLayerVisibilityDefaults()
        layersSectionContent.orientation = .vertical
        layersSectionContent.spacing = 6
        layersRowsStack.orientation = .vertical
        layersRowsStack.spacing = 4

        for view in layersRowsStack.arrangedSubviews {
            layersRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        layerVisibilityButtons.removeAll()
        layerTintColorWells.removeAll()

        for layer in snapshotLayerOptions {
            let visibilityButton = NSButton(title: "", target: self, action: #selector(layerVisibilityButtonChanged(_:)))
            visibilityButton.identifier = NSUserInterfaceItemIdentifier(layer)
            visibilityButton.isBordered = false
            visibilityButton.imagePosition = .imageOnly
            visibilityButton.setButtonType(.momentaryChange)
            visibilityButton.translatesAutoresizingMaskIntoConstraints = false
            visibilityButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
            visibilityButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
            layerVisibilityButtons[layer] = visibilityButton
            refreshLayerVisibilityButton(for: layer)

            let colorWell = NSColorWell(frame: .zero)
            colorWell.identifier = NSUserInterfaceItemIdentifier(layer)
            colorWell.target = self
            colorWell.action = #selector(layerTintColorWellChanged(_:))
            colorWell.translatesAutoresizingMaskIntoConstraints = false
            colorWell.widthAnchor.constraint(equalToConstant: 22).isActive = true
            colorWell.heightAnchor.constraint(equalToConstant: 16).isActive = true
            layerTintColorWells[layer] = colorWell
            refreshLayerTintColorWell(for: layer)

            let label = NSTextField(labelWithString: layer)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail

            let row = NSStackView(views: [visibilityButton, colorWell, label, NSView()])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            layersRowsStack.addArrangedSubview(row)
        }

        layersSectionContent.addArrangedSubview(layersRowsStack)
    }

    @objc func layerVisibilityButtonChanged(_ sender: NSButton) {
        guard let layer = sender.identifier?.rawValue, !layer.isEmpty else { return }
        let current = layerVisibilityByName[layer] ?? true
        layerVisibilityByName[layer] = !current
        refreshLayerVisibilityButton(for: layer)
        applySnapshotLayerVisibility()
    }

    @objc func statusLayerSelectionChanged(_ sender: NSPopUpButton) {
        _ = sender
        refreshStatusLayerControls()
    }

    @objc func statusLayerColorChanged(_ sender: NSColorWell) {
        let layer = selectedStatusLayerName()
        guard layer != "DEFAULT" else {
            refreshStatusLayerControls()
            return
        }
        layerTintColorByName[layer] = sender.color.withAlphaComponent(1.0)
        applyLayerTintColorToAllSnapshots(layer: layer)
        refreshLayerTintColorWell(for: layer)
        refreshStatusLayerControls()
    }

    @objc func layerTintColorWellChanged(_ sender: NSColorWell) {
        guard let layer = sender.identifier?.rawValue, !layer.isEmpty else { return }
        guard layer != "DEFAULT" else {
            refreshLayerTintColorWell(for: layer)
            return
        }
        layerTintColorByName[layer] = sender.color.withAlphaComponent(1.0)
        applyLayerTintColorToAllSnapshots(layer: layer)
        refreshLayerTintColorWell(for: layer)
        if selectedStatusLayerName() == layer {
            refreshStatusLayerControls()
        }
    }

    func applySnapshotLayerVisibility() {
        guard let document = pdfView.document else { return }
        ensureLayerVisibilityDefaults()
        var hidSelectedSnapshot = false
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let snapshot = annotation as? PDFSnapshotAnnotation else { continue }
                let layer = snapshot.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isVisible = layer.isEmpty ? true : (layerVisibilityByName[layer] ?? true)
                snapshot.shouldDisplay = isVisible
                snapshot.shouldPrint = isVisible
                if !isVisible, lastDirectlySelectedAnnotation === snapshot {
                    hidSelectedSnapshot = true
                }
            }
        }
        if hidSelectedSnapshot {
            clearMarkupSelection()
        } else {
            updateSelectionOverlay()
            updateToolSettingsUIForCurrentTool()
            updateStatusBar()
        }
        pdfView.needsDisplay = true
    }

    func promptSnapshotLayerAssignmentIfNeeded() {
        let snapshots = currentSelectedMarkupItems().compactMap { $0.annotation as? PDFSnapshotAnnotation }
        guard snapshots.count == 1, let selectedSnapshot = snapshots.first else { return }
        let currentLayer = selectedSnapshot.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentLayer.isEmpty else { return }
        guard let layer = promptSnapshotLayerSelection(
            defaultLayer: "ARCHITECTURAL",
            messageText: "Assign Snapshot Layer",
            informativeText: "Choose the layer for this pasted grab markup.",
            confirmTitle: "Assign Layer",
            cancelTitle: "Skip"
        ), !layer.isEmpty else { return }
        assignLayer(layer, to: [selectedSnapshot])
    }

    func assignSnapshotLayerForCurrentSelection() {
        let selectedSnapshots = currentSelectedMarkupItems().compactMap { $0.annotation as? PDFSnapshotAnnotation }
        let snapshots: [PDFSnapshotAnnotation]
        if !selectedSnapshots.isEmpty {
            snapshots = selectedSnapshots
        } else if let direct = lastDirectlySelectedAnnotation as? PDFSnapshotAnnotation {
            snapshots = [direct]
        } else {
            beep()
            return
        }

        let defaultLayer: String
        if snapshots.count == 1 {
            let current = snapshots[0].snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            defaultLayer = current.isEmpty ? "ARCHITECTURAL" : current
        } else {
            defaultLayer = "ARCHITECTURAL"
        }
        guard let layer = promptSnapshotLayerSelection(defaultLayer: defaultLayer), !layer.isEmpty else { return }
        assignLayer(layer, to: snapshots)
    }

    func assignLayer(_ layer: String, to snapshots: [PDFSnapshotAnnotation]) {
        guard !snapshots.isEmpty else { return }
        for annotation in snapshots {
            let previous = snapshot(for: annotation)
            annotation.snapshotLayerName = layer
            applyLayerRenderingStyle(to: annotation, layer: layer)
            registerAnnotationStateUndo(annotation: annotation, previous: previous, actionName: "Assign Snapshot Layer")
            markPageMarkupCacheDirty(annotation.page)
        }
        markMarkupChanged()
        applySnapshotLayerVisibility()
        performRefreshMarkups(selecting: snapshots.first)
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
        scheduleAutosave()
    }
}
