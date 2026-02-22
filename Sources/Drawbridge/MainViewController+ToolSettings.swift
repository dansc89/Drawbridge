import AppKit
import PDFKit

@MainActor
extension MainViewController {
    private func isFreeTextType(_ annotationTypeLowercased: String) -> Bool {
        annotationTypeLowercased.contains("freetext") ||
        (annotationTypeLowercased.contains("free") && annotationTypeLowercased.contains("text"))
    }

    @objc func toolSettingsOpacityChanged() {
        let opacityPercent = Int(round(toolSettingsOpacitySlider.doubleValue * 100))
        toolSettingsOpacityValueLabel.stringValue = "\(opacityPercent)%"
        applyToolSettingsToPDFView()
    }

    @objc func toolSettingsChanged() {
        applyToolSettingsToPDFView()
    }

    private func applyTextMarkupStyle(
        foreground: NSColor,
        background: NSColor,
        outlineColor: NSColor,
        outlineWidth: CGFloat,
        font: NSFont
    ) {
        pdfView.textForegroundColor = foreground
        pdfView.textBackgroundColor = background
        pdfView.textOutlineColor = outlineColor.withAlphaComponent(1.0)
        pdfView.textOutlineWidth = max(0, outlineWidth)
        pdfView.textFontName = font.fontName
        pdfView.textFontSize = font.pointSize
    }

    private func makeToolSettingsState(
        strokeColor: NSColor,
        fillColor: NSColor,
        opacity: CGFloat,
        lineWeightLevel: Int,
        fontName: String,
        fontSize: CGFloat,
        calloutArrowStyleRawValue: Int,
        arrowHeadSize: CGFloat,
        outlineColor: NSColor = .clear,
        outlineWidth: CGFloat = 0
    ) -> ToolSettingsState {
        ToolSettingsState(
            strokeColor: strokeColor,
            fillColor: fillColor,
            outlineColor: outlineColor,
            opacity: opacity,
            lineWeightLevel: lineWeightLevel,
            outlineWidth: outlineWidth,
            fontName: fontName,
            fontSize: fontSize,
            calloutArrowStyleRawValue: calloutArrowStyleRawValue,
            arrowHeadSize: arrowHeadSize
        )
    }

    @objc func colorizeSnapshotsBlackToRed() {
        let snapshots = currentSelectedMarkupItems().compactMap { $0.annotation as? PDFSnapshotAnnotation }
        guard !snapshots.isEmpty else {
            NSSound.beep()
            return
        }
        var first: PDFSnapshotAnnotation?
        for snap in snapshots {
            let previous = snapshot(for: snap)
            snap.renderTintColor = .systemRed
            snap.renderTintStrength = 1.0
            snap.lineworkOnlyTint = true
            registerAnnotationStateUndo(annotation: snap, previous: previous, actionName: "Colorize Black to Red")
            markPageMarkupCacheDirty(snap.page)
            if first == nil { first = snap }
        }
        commitMarkupMutation(selecting: first)
    }

    func applyToolSettingsToPDFView() {
        let selectedItems = currentSelectedMarkupItems()
        let selectedCount = selectedItems.count
        let settingsSpan = PerformanceMetrics.begin(
            "apply_tool_settings",
            thresholdMs: 20,
            fields: [
                "tool": "\(pdfView.toolMode)",
                "selected_count": "\(selectedCount)"
            ]
        )
        let opacity = normalizedOpacity(CGFloat(toolSettingsOpacitySlider.doubleValue), for: pdfView.toolMode)
        if toolSettingsOpacitySlider.doubleValue != Double(opacity) {
            toolSettingsOpacitySlider.doubleValue = Double(opacity)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
        }
        let currentWidth = widthValue(for: selectedLineWeightLevel(), tool: pdfView.toolMode)
        let stroke = toolSettingsStrokeColorWell.color.withAlphaComponent(opacity)
        let fill = toolSettingsFillColorWell.color.withAlphaComponent(opacity)
        let outlineColor = toolSettingsOutlineColorWell.color.withAlphaComponent(1.0)
        let outlineWidth = selectedTextOutlineWidth()
        let textFont = resolvedToolSettingsFont()
        let calloutArrowStyle = resolvedCalloutArrowStyleFromUI()
        let arrowHeadSize = selectedArrowHeadSize()

        if pdfView.toolMode == .select, !selectedItems.isEmpty {
            var editedAny = false
            var firstEdited: PDFAnnotation?
            for item in selectedItems {
                let annotation = item.annotation
                let annotationType = (annotation.type ?? "").lowercased()
                let previous = snapshot(for: annotation)
                var didEdit = false

                if isFreeTextType(annotationType) {
                    annotation.color = stroke.withAlphaComponent(opacity * 0.5)
                    annotation.interiorColor = nil
                    assignLineWidth(0.0, to: annotation)
                    annotation.fontColor = fill
                    annotation.font = textFont
                    pdfView.syncTextOutlineAppearance(for: annotation, outlineColor: outlineColor, outlineWidth: outlineWidth)
                    if pdfView.linkedCalloutLeader(for: annotation) != nil {
                        _ = pdfView.updateCalloutLeaderAppearance(
                            for: annotation,
                            style: calloutArrowStyle,
                            headSize: arrowHeadSize,
                            lineWidth: widthValue(for: selectedLineWeightLevel(), tool: .callout),
                            strokeColor: stroke
                        )
                    }
                    didEdit = true
                } else if let snapshot = annotation as? PDFSnapshotAnnotation {
                    if let sourceURL = snapshot.snapshotURL,
                       let sourceData = try? Data(contentsOf: sourceURL) {
                        snapshot.tintBlendStyle = preferredSnapshotTintBlendStyle(for: sourceData)
                    }
                    snapshot.renderOpacity = opacity
                    snapshot.renderTintColor = toolSettingsStrokeColorWell.color.withAlphaComponent(1.0)
                    snapshot.renderTintStrength = 1.0
                    snapshot.lineworkOnlyTint = true
                    didEdit = true
                } else {
                    annotation.color = stroke
                    if annotationType.contains("square") || annotationType.contains("circle") {
                        annotation.interiorColor = fill
                    }
                    if !annotationType.contains("highlight") {
                        let inferredTool = inferredToolMode(for: annotation)
                        let updatedWidth = widthValue(for: selectedLineWeightLevel(), tool: inferredTool)
                        assignLineWidth(updatedWidth, to: annotation)
                    }
                    didEdit = true
                }

                if didEdit {
                    registerAnnotationStateUndo(annotation: annotation, previous: previous, actionName: "Edit Markup Appearance")
                    markPageMarkupCacheDirty(annotation.page)
                    editedAny = true
                    if firstEdited == nil {
                        firstEdited = annotation
                    }
                }
            }
            if editedAny {
                commitMarkupMutation(selecting: firstEdited)
            }
            PerformanceMetrics.end(
                settingsSpan,
                extra: [
                    "result": "selection_edit",
                    "edited_count": "\(selectedItems.count)"
                ]
            )
            return
        }

        switch pdfView.toolMode {
        case .grab:
            break
        case .pen, .line, .polyline:
            pdfView.penColor = stroke
            pdfView.penLineWidth = currentWidth
        case .arrow:
            pdfView.arrowStrokeColor = stroke
            pdfView.arrowLineWidth = currentWidth
            pdfView.calloutArrowStyle = calloutArrowStyle
            pdfView.arrowHeadSize = arrowHeadSize
        case .area:
            pdfView.penColor = stroke
            pdfView.areaLineWidth = currentWidth
        case .highlighter:
            pdfView.highlighterColor = stroke
            pdfView.highlighterLineWidth = currentWidth
        case .cloud, .rectangle:
            pdfView.rectangleStrokeColor = stroke
            pdfView.rectangleFillColor = fill
            pdfView.rectangleLineWidth = currentWidth
        case .text:
            applyTextMarkupStyle(
                foreground: fill,
                background: stroke.withAlphaComponent(opacity * 0.5),
                outlineColor: outlineColor,
                outlineWidth: outlineWidth,
                font: textFont
            )
        case .callout:
            pdfView.calloutStrokeColor = stroke
            pdfView.calloutLineWidth = currentWidth
            pdfView.calloutArrowStyle = calloutArrowStyle
            pdfView.calloutArrowHeadSize = arrowHeadSize
            applyTextMarkupStyle(
                foreground: fill,
                background: stroke.withAlphaComponent(opacity * 0.5),
                outlineColor: outlineColor,
                outlineWidth: outlineWidth,
                font: textFont
            )
        case .measure, .calibrate:
            pdfView.measurementStrokeColor = stroke
            pdfView.calibrationStrokeColor = stroke
            pdfView.measurementLineWidth = currentWidth
        case .select:
            break
        }
        persistToolSettingsFromControls(for: pdfView.toolMode)
        PerformanceMetrics.end(settingsSpan, extra: ["result": "tool_state_updated"])
    }

    private func resolvedToolSettingsFont() -> NSFont {
        let size = selectedToolFontSize()
        return resolveFont(family: defaultToolFontName(), size: size)
    }

    private func defaultToolFontName() -> String {
        NSFont.systemFont(ofSize: 15, weight: .regular).fontName
    }

    private func selectedToolFontSize() -> CGFloat {
        let fallback: CGFloat = 15
        guard let title = toolSettingsFontSizePopup.titleOfSelectedItem,
              let raw = Double(title.replacingOccurrences(of: " pt", with: "")) else {
            selectToolFontSize(fallback)
            return fallback
        }
        let size = max(6.0, min(256.0, CGFloat(raw)))
        selectToolFontSize(size)
        return size
    }

    private func selectToolFontSize(_ size: CGFloat) {
        let nearest = standardFontSizes.min { lhs, rhs in
            abs(CGFloat(lhs) - size) < abs(CGFloat(rhs) - size)
        } ?? 15
        toolSettingsFontSizePopup.selectItem(withTitle: "\(nearest) pt")
    }

    private func resolvedCalloutArrowStyleFromUI() -> MarkupPDFView.ArrowEndStyle {
        let selectedTitle = toolSettingsArrowPopup.titleOfSelectedItem ?? MarkupPDFView.ArrowEndStyle.solidArrow.displayName
        return MarkupPDFView.ArrowEndStyle.allCases.first(where: { $0.displayName == selectedTitle }) ?? .solidArrow
    }

    private func selectedArrowHeadSize() -> CGFloat {
        let fallback: CGFloat = 8.0
        guard let title = toolSettingsArrowSizePopup.titleOfSelectedItem,
              let raw = Double(title.replacingOccurrences(of: " pt", with: "")) else {
            selectArrowHeadSize(fallback)
            return fallback
        }
        let size = max(1.0, min(100.0, CGFloat(raw)))
        selectArrowHeadSize(size)
        return size
    }

    private func selectArrowHeadSize(_ size: CGFloat) {
        let standardSizes: [CGFloat] = [2, 3, 4, 5, 6, 8, 10, 12, 16, 20]
        let nearest = standardSizes.min { lhs, rhs in
            abs(lhs - size) < abs(rhs - size)
        } ?? 8
        toolSettingsArrowSizePopup.selectItem(withTitle: "\(Int(nearest)) pt")
    }

    private func selectedTextOutlineWidth() -> CGFloat {
        guard let title = toolSettingsOutlineWidthPopup.titleOfSelectedItem else {
            selectTextOutlineWidth(0)
            return 0
        }
        if title == "None" {
            return 0
        }
        let raw = title.replacingOccurrences(of: " pt", with: "")
        let value = CGFloat(Double(raw) ?? 0)
        let clamped = max(0, min(10, value))
        selectTextOutlineWidth(clamped)
        return clamped
    }

    private func selectTextOutlineWidth(_ width: CGFloat) {
        if width <= 0.01 {
            toolSettingsOutlineWidthPopup.selectItem(withTitle: "None")
            return
        }
        let standard: [CGFloat] = [1, 2, 3, 4, 5, 6, 8, 10]
        let nearest = standard.min { lhs, rhs in
            abs(lhs - width) < abs(rhs - width)
        } ?? 1
        toolSettingsOutlineWidthPopup.selectItem(withTitle: "\(Int(nearest)) pt")
    }

    func resolveFont(family: String, size: CGFloat) -> NSFont {
        _ = family
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    func updateToolSettingsUIForCurrentTool() {
        let selectedItems = currentSelectedMarkupItems()
        if pdfView.toolMode == .select, let primary = selectedItems.first?.annotation {
            let inferredTool = inferredToolMode(for: primary)
            let annotationType = (primary.type ?? "").lowercased()
            let count = selectedItems.count
            toolSettingsToolLabel.stringValue = count == 1 ? "Selected Markup" : "Selected Markups: \(count)"
            toolSettingsArrowRow.isHidden = true
            toolSettingsArrowPopup.isEnabled = false
            toolSettingsArrowSizeRow.isHidden = true
            toolSettingsArrowSizePopup.isEnabled = false
            toolSettingsOutlineRow.isHidden = true
            toolSettingsOutlineColorWell.isEnabled = false
            toolSettingsOutlineWidthPopup.isEnabled = false

            if isFreeTextType(annotationType) {
                let calloutLeader = pdfView.linkedCalloutLeader(for: primary)
                let isCalloutText = (calloutLeader != nil)
                toolSettingsStrokeTitleLabel.stringValue = "Background:"
                toolSettingsFillTitleLabel.stringValue = "Text:"
                toolSettingsOutlineTitleLabel.stringValue = "Outline:"
                toolSettingsFontTitleLabel.stringValue = "Text Size:"
                toolSettingsFillRow.isHidden = false
                toolSettingsOutlineRow.isHidden = false
                toolSettingsFontRow.isHidden = false
                toolSettingsWidthRow.isHidden = !isCalloutText
                toolSettingsLineWidthPopup.isEnabled = isCalloutText
                toolSettingsArrowRow.isHidden = !isCalloutText
                toolSettingsArrowPopup.isEnabled = isCalloutText
                toolSettingsArrowSizeRow.isHidden = !isCalloutText
                toolSettingsArrowSizePopup.isEnabled = isCalloutText
                toolSettingsOpacitySlider.doubleValue = 1.0
                toolSettingsFillColorWell.color = (primary.fontColor ?? NSColor.labelColor).withAlphaComponent(1.0)
                let background = primary.color.withAlphaComponent(1.0)
                toolSettingsStrokeColorWell.color = background
                let outlineStyle = pdfView.textOutlineStyle(for: primary)
                toolSettingsOutlineColorWell.color = (outlineStyle?.color ?? NSColor.black).withAlphaComponent(1.0)
                let outlineWidth = outlineStyle?.width ?? 0
                selectTextOutlineWidth(outlineWidth)
                let font = primary.font ?? NSFont.systemFont(ofSize: 15, weight: .regular)
                selectToolFontSize(font.pointSize)
                if let calloutLeader {
                    let style = pdfView.calloutArrowStyle(for: calloutLeader) ?? .solidArrow
                    toolSettingsArrowPopup.selectItem(withTitle: style.displayName)
                    let headSize = pdfView.calloutArrowHeadSize(for: calloutLeader) ?? pdfView.calloutArrowHeadSize
                    selectArrowHeadSize(headSize)
                    let leaderWidth = resolvedLineWidth(for: calloutLeader)
                    selectLineWeightLevel(
                        for: leaderWidth > 0 ? leaderWidth : widthValue(for: 5, tool: .callout),
                        tool: .callout
                    )
                }
            } else if let snapshot = primary as? PDFSnapshotAnnotation {
                toolSettingsStrokeTitleLabel.stringValue = "Linework:"
                toolSettingsFillTitleLabel.stringValue = "Fill:"
                toolSettingsFillRow.isHidden = true
                toolSettingsFontRow.isHidden = true
                toolSettingsWidthRow.isHidden = true
                toolSettingsLineWidthPopup.isEnabled = false
                toolSettingsStrokeColorWell.color = (snapshot.renderTintColor ?? NSColor.systemRed).withAlphaComponent(1.0)
                toolSettingsOpacitySlider.doubleValue = Double(snapshot.renderOpacity)
                snapshotColorizeButton.isHidden = false
                snapshotColorizeButton.isEnabled = true
            } else {
                toolSettingsStrokeTitleLabel.stringValue = "Color:"
                toolSettingsFillTitleLabel.stringValue = "Fill:"
                let contents = (primary.contents ?? "").lowercased()
                let isArrowMarkup =
                    contents.contains("arrow|style:") ||
                    contents.contains("arrow dot|") ||
                    contents.contains("arrow square|") ||
                    contents.contains("callout leader|arrow:")
                toolSettingsFillRow.isHidden = !(annotationType.contains("square") || annotationType.contains("circle"))
                toolSettingsFontRow.isHidden = true
                toolSettingsArrowRow.isHidden = !isArrowMarkup
                toolSettingsArrowPopup.isEnabled = isArrowMarkup
                toolSettingsArrowSizeRow.isHidden = !isArrowMarkup
                toolSettingsArrowSizePopup.isEnabled = isArrowMarkup
                toolSettingsOutlineRow.isHidden = true
                toolSettingsOutlineColorWell.isEnabled = false
                toolSettingsOutlineWidthPopup.isEnabled = false
                if isArrowMarkup,
                   let style = pdfView.calloutArrowStyle(for: primary) {
                    toolSettingsArrowPopup.selectItem(withTitle: style.displayName)
                }
                if isArrowMarkup {
                    let headSize = pdfView.calloutArrowHeadSize(for: primary)
                        ?? ((inferredTool == .callout) ? pdfView.calloutArrowHeadSize : pdfView.arrowHeadSize)
                    selectArrowHeadSize(headSize)
                }
                toolSettingsWidthRow.isHidden = false
                toolSettingsLineWidthPopup.isEnabled = true
                toolSettingsStrokeColorWell.color = primary.color.withAlphaComponent(1.0)
                toolSettingsOpacitySlider.doubleValue = Double(primary.color.alphaComponent)
                toolSettingsFillColorWell.color = (primary.interiorColor ?? NSColor.systemYellow).withAlphaComponent(1.0)
                let currentLineWidth = resolvedLineWidth(for: primary)
                selectLineWeightLevel(
                    for: currentLineWidth > 0 ? currentLineWidth : widthValue(for: 5, tool: inferredTool),
                    tool: inferredTool
                )
            }

            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            toolSettingsOpacitySlider.isEnabled = !isFreeTextType(annotationType)
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = !toolSettingsFillRow.isHidden
            toolSettingsOutlineColorWell.isEnabled = !toolSettingsOutlineRow.isHidden
            toolSettingsOutlineWidthPopup.isEnabled = !toolSettingsOutlineRow.isHidden
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = !toolSettingsFontRow.isHidden
            if !(primary is PDFSnapshotAnnotation) {
                snapshotColorizeButton.isHidden = true
                snapshotColorizeButton.isEnabled = false
            }
            return
        }

        toolSettingsToolLabel.stringValue = "Active Tool: \(currentToolName())"
        toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
        snapshotColorizeButton.isHidden = true
        snapshotColorizeButton.isEnabled = false
        toolSettingsArrowRow.isHidden = true
        toolSettingsArrowPopup.isEnabled = false
        toolSettingsArrowSizeRow.isHidden = true
        toolSettingsArrowSizePopup.isEnabled = false
        toolSettingsOutlineRow.isHidden = true
        toolSettingsOutlineColorWell.isEnabled = false
        toolSettingsOutlineWidthPopup.isEnabled = false

        switch pdfView.toolMode {
        case .grab:
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFontTitleLabel.stringValue = "Text Size:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = false
            toolSettingsFillColorWell.isEnabled = false
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = false
            toolSettingsOutlineRow.isHidden = true
        case .arrow:
            toolSettingsStrokeColorWell.color = pdfView.arrowStrokeColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.arrowStrokeColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.arrowLineWidth, tool: .arrow)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFontTitleLabel.stringValue = "Text Size:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsArrowRow.isHidden = false
            toolSettingsArrowPopup.isEnabled = true
            toolSettingsArrowPopup.selectItem(withTitle: pdfView.calloutArrowStyle.displayName)
            toolSettingsArrowSizeRow.isHidden = false
            toolSettingsArrowSizePopup.isEnabled = true
            selectArrowHeadSize(pdfView.arrowHeadSize)
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = false
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        case .select:
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFontTitleLabel.stringValue = "Text Size:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = false
            toolSettingsFillColorWell.isEnabled = false
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = false
            toolSettingsOutlineRow.isHidden = true
        case .pen, .line, .polyline:
            toolSettingsStrokeColorWell.color = pdfView.penColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.penColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.penLineWidth, tool: pdfView.toolMode)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        case .area:
            toolSettingsStrokeColorWell.color = pdfView.penColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.penColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.areaLineWidth, tool: .area)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        case .highlighter:
            toolSettingsStrokeColorWell.color = pdfView.highlighterColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.highlighterColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.highlighterLineWidth, tool: .highlighter)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        case .cloud, .rectangle:
            selectLineWeightLevel(for: pdfView.rectangleLineWidth, tool: .rectangle)
            toolSettingsStrokeTitleLabel.stringValue = "Stroke:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = false
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        case .text:
            let state = toolSettingsByTool[.text] ?? defaultToolSettings(for: .text)
            toolSettingsStrokeColorWell.color = state.strokeColor.withAlphaComponent(1.0)
            toolSettingsFillColorWell.color = state.fillColor.withAlphaComponent(1.0)
            toolSettingsOutlineColorWell.color = state.outlineColor.withAlphaComponent(1.0)
            selectTextOutlineWidth(state.outlineWidth)
            selectToolFontSize(state.fontSize)
            toolSettingsOpacitySlider.doubleValue = 1.0
            toolSettingsOpacityValueLabel.stringValue = "100%"
            toolSettingsStrokeTitleLabel.stringValue = "Background:"
            toolSettingsFillTitleLabel.stringValue = "Text:"
            toolSettingsOutlineTitleLabel.stringValue = "Outline:"
            toolSettingsFontTitleLabel.stringValue = "Text Size:"
            toolSettingsFillRow.isHidden = false
            toolSettingsOutlineRow.isHidden = false
            toolSettingsFontRow.isHidden = false
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsOutlineColorWell.isEnabled = true
            toolSettingsOutlineWidthPopup.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = false
        case .callout:
            let state = toolSettingsByTool[.callout] ?? defaultToolSettings(for: .callout)
            toolSettingsStrokeColorWell.color = state.strokeColor.withAlphaComponent(1.0)
            toolSettingsFillColorWell.color = state.fillColor.withAlphaComponent(1.0)
            toolSettingsOutlineColorWell.color = state.outlineColor.withAlphaComponent(1.0)
            selectTextOutlineWidth(state.outlineWidth)
            selectToolFontSize(state.fontSize)
            toolSettingsOpacitySlider.doubleValue = 1.0
            toolSettingsOpacityValueLabel.stringValue = "100%"
            selectLineWeightLevel(for: widthValue(for: state.lineWeightLevel, tool: .callout), tool: .callout)
            toolSettingsStrokeTitleLabel.stringValue = "Leader:"
            toolSettingsFillTitleLabel.stringValue = "Text:"
            toolSettingsOutlineTitleLabel.stringValue = "Outline:"
            toolSettingsFontTitleLabel.stringValue = "Text Size:"
            toolSettingsFillRow.isHidden = false
            toolSettingsOutlineRow.isHidden = false
            toolSettingsFontRow.isHidden = false
            toolSettingsArrowRow.isHidden = false
            toolSettingsArrowPopup.isEnabled = true
            let style = MarkupPDFView.ArrowEndStyle(rawValue: state.calloutArrowStyleRawValue) ?? .solidArrow
            toolSettingsArrowPopup.selectItem(withTitle: style.displayName)
            toolSettingsArrowSizeRow.isHidden = false
            toolSettingsArrowSizePopup.isEnabled = true
            selectArrowHeadSize(state.arrowHeadSize)
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsOutlineColorWell.isEnabled = true
            toolSettingsOutlineWidthPopup.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .measure, .calibrate:
            selectLineWeightLevel(for: pdfView.measurementLineWidth, tool: .measure)
            toolSettingsStrokeTitleLabel.stringValue = "Line:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsFontRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsFontPopup.isEnabled = false
            toolSettingsFontSizePopup.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = true
            toolSettingsOutlineRow.isHidden = true
        }
    }

    private func selectedLineWeightLevel() -> Int {
        let selected = Int(toolSettingsLineWidthPopup.titleOfSelectedItem ?? "") ?? 5
        return min(max(selected, 1), 10)
    }

    private func selectLineWeightLevel(for lineWidth: CGFloat, tool: ToolMode) {
        let nearest = lineWeightLevels.min { lhs, rhs in
            abs(widthValue(for: lhs, tool: tool) - lineWidth) < abs(widthValue(for: rhs, tool: tool) - lineWidth)
        } ?? 5
        toolSettingsLineWidthPopup.selectItem(withTitle: "\(nearest)")
    }

    private func widthValue(for lineWeightLevel: Int, tool: ToolMode) -> CGFloat {
        let level = min(max(lineWeightLevel, 1), 10)
        switch tool {
        case .grab:
            return 1
        case .area:
            return interpolateLevel(level, lowAt1: 1, midAt5: 2, highAt10: 4)
        case .arrow:
            return interpolateLevel(level, lowAt1: 1, midAt5: 2, highAt10: 4)
        case .pen, .line, .polyline:
            return interpolateLevel(level, lowAt1: 6, midAt5: 15, highAt10: 25)
        case .highlighter:
            return interpolateLevel(level, lowAt1: 12, midAt5: 25, highAt10: 40)
        case .cloud, .rectangle:
            return interpolateLevel(level, lowAt1: 12, midAt5: 25, highAt10: 50)
        case .callout, .measure, .calibrate:
            return interpolateLevel(level, lowAt1: 1, midAt5: 2, highAt10: 4)
        case .select, .text:
            return 1
        }
    }

    private func supportsStoredToolSettings(_ tool: ToolMode) -> Bool {
        switch tool {
        case .select, .grab:
            return false
        default:
            return true
        }
    }

    private func normalizedOpacity(_ value: CGFloat, for tool: ToolMode) -> CGFloat {
        if tool == .text || tool == .callout {
            return 1.0
        }
        return min(max(value, 0.0), 1.0)
    }

    private func defaultToolSettings(for tool: ToolMode) -> ToolSettingsState {
        let defaultFontName = defaultToolFontName()
        let defaultFontSize = max(6.0, pdfView.textFontSize)
        let defaultArrowRaw = MarkupPDFView.ArrowEndStyle.solidArrow.rawValue
        let defaultArrowHeadSize: CGFloat = 8.0
        let defaultTextOutlineColor = MarkupStyleDefaults.textOutlineColor
        let defaultTextOutlineWidth: CGFloat = MarkupStyleDefaults.textOutlineWidth
        switch tool {
        case .pen:
            return makeToolSettingsState(strokeColor: pdfView.penColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.penColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .arrow:
            return makeToolSettingsState(strokeColor: pdfView.arrowStrokeColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.arrowStrokeColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: pdfView.calloutArrowStyle.rawValue, arrowHeadSize: max(1.0, pdfView.arrowHeadSize))
        case .line:
            return makeToolSettingsState(strokeColor: pdfView.penColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.penColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .polyline:
            return makeToolSettingsState(strokeColor: pdfView.penColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.penColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .highlighter:
            return makeToolSettingsState(strokeColor: pdfView.highlighterColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.highlighterColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .cloud:
            return makeToolSettingsState(strokeColor: pdfView.rectangleStrokeColor.withAlphaComponent(1.0), fillColor: pdfView.rectangleFillColor.withAlphaComponent(1.0), opacity: pdfView.rectangleStrokeColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .rectangle:
            return makeToolSettingsState(strokeColor: pdfView.rectangleStrokeColor.withAlphaComponent(1.0), fillColor: pdfView.rectangleFillColor.withAlphaComponent(1.0), opacity: pdfView.rectangleStrokeColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .text:
            return makeToolSettingsState(strokeColor: pdfView.textBackgroundColor.withAlphaComponent(1.0), fillColor: pdfView.textForegroundColor.withAlphaComponent(1.0), opacity: 1.0, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize, outlineColor: defaultTextOutlineColor, outlineWidth: defaultTextOutlineWidth)
        case .callout:
            return makeToolSettingsState(strokeColor: pdfView.calloutStrokeColor.withAlphaComponent(1.0), fillColor: pdfView.textForegroundColor.withAlphaComponent(1.0), opacity: 1.0, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: pdfView.calloutArrowStyle.rawValue, arrowHeadSize: max(1.0, pdfView.calloutArrowHeadSize), outlineColor: defaultTextOutlineColor, outlineWidth: defaultTextOutlineWidth)
        case .area:
            return makeToolSettingsState(strokeColor: pdfView.penColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.penColor.alphaComponent, lineWeightLevel: 1, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .measure:
            return makeToolSettingsState(strokeColor: pdfView.measurementStrokeColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.measurementStrokeColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .calibrate:
            return makeToolSettingsState(strokeColor: pdfView.calibrationStrokeColor.withAlphaComponent(1.0), fillColor: .clear, opacity: pdfView.calibrationStrokeColor.alphaComponent, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        case .select, .grab:
            return makeToolSettingsState(strokeColor: .systemRed, fillColor: .systemYellow, opacity: 1.0, lineWeightLevel: 5, fontName: defaultFontName, fontSize: defaultFontSize, calloutArrowStyleRawValue: defaultArrowRaw, arrowHeadSize: defaultArrowHeadSize)
        }
    }

    func initializePerToolSettings() {
        let tools: [ToolMode] = [.pen, .arrow, .line, .polyline, .highlighter, .cloud, .rectangle, .text, .callout, .area, .measure, .calibrate]
        for tool in tools {
            toolSettingsByTool[tool] = defaultToolSettings(for: tool)
        }
    }

    func persistToolSettingsFromControls(for tool: ToolMode) {
        guard supportsStoredToolSettings(tool), pdfView.toolMode != .select else { return }
        var state = toolSettingsByTool[tool] ?? defaultToolSettings(for: tool)
        state.strokeColor = toolSettingsStrokeColorWell.color.withAlphaComponent(1.0)
        state.fillColor = toolSettingsFillColorWell.color.withAlphaComponent(1.0)
        state.outlineColor = toolSettingsOutlineColorWell.color.withAlphaComponent(1.0)
        state.opacity = normalizedOpacity(CGFloat(toolSettingsOpacitySlider.doubleValue), for: tool)
        state.lineWeightLevel = selectedLineWeightLevel()
        state.outlineWidth = selectedTextOutlineWidth()
        let font = resolvedToolSettingsFont()
        state.fontName = font.fontName
        state.fontSize = font.pointSize
        state.calloutArrowStyleRawValue = resolvedCalloutArrowStyleFromUI().rawValue
        state.arrowHeadSize = selectedArrowHeadSize()
        toolSettingsByTool[tool] = state
    }

    func applyStoredToolSettings(to tool: ToolMode) {
        guard supportsStoredToolSettings(tool) else { return }
        let state = toolSettingsByTool[tool] ?? defaultToolSettings(for: tool)
        let opacity = normalizedOpacity(state.opacity, for: tool)
        let stroke = state.strokeColor.withAlphaComponent(opacity)
        let fill = state.fillColor.withAlphaComponent(opacity)
        switch tool {
        case .pen:
            pdfView.penColor = stroke
            pdfView.penLineWidth = widthValue(for: state.lineWeightLevel, tool: .pen)
        case .arrow:
            pdfView.arrowStrokeColor = stroke
            pdfView.arrowLineWidth = widthValue(for: state.lineWeightLevel, tool: .arrow)
            pdfView.calloutArrowStyle = MarkupPDFView.ArrowEndStyle(rawValue: state.calloutArrowStyleRawValue) ?? .solidArrow
            pdfView.arrowHeadSize = max(1.0, state.arrowHeadSize)
        case .line:
            pdfView.penColor = stroke
            pdfView.penLineWidth = widthValue(for: state.lineWeightLevel, tool: .line)
        case .polyline:
            pdfView.penColor = stroke
            pdfView.penLineWidth = widthValue(for: state.lineWeightLevel, tool: .polyline)
        case .highlighter:
            pdfView.highlighterColor = stroke
            pdfView.highlighterLineWidth = widthValue(for: state.lineWeightLevel, tool: .highlighter)
        case .cloud:
            pdfView.rectangleStrokeColor = stroke
            pdfView.rectangleFillColor = fill
            pdfView.rectangleLineWidth = widthValue(for: state.lineWeightLevel, tool: .cloud)
        case .rectangle:
            pdfView.rectangleStrokeColor = stroke
            pdfView.rectangleFillColor = fill
            pdfView.rectangleLineWidth = widthValue(for: state.lineWeightLevel, tool: .rectangle)
        case .text:
            applyTextMarkupStyle(
                foreground: state.fillColor.withAlphaComponent(1.0),
                background: state.strokeColor.withAlphaComponent(1.0),
                outlineColor: state.outlineColor.withAlphaComponent(1.0),
                outlineWidth: state.outlineWidth,
                font: resolveFont(family: state.fontName, size: state.fontSize)
            )
        case .callout:
            pdfView.calloutStrokeColor = state.strokeColor.withAlphaComponent(1.0)
            pdfView.calloutLineWidth = widthValue(for: state.lineWeightLevel, tool: .callout)
            pdfView.calloutArrowStyle = MarkupPDFView.ArrowEndStyle(rawValue: state.calloutArrowStyleRawValue) ?? .solidArrow
            pdfView.calloutArrowHeadSize = max(1.0, state.arrowHeadSize)
            applyTextMarkupStyle(
                foreground: state.fillColor.withAlphaComponent(1.0),
                background: state.strokeColor.withAlphaComponent(1.0),
                outlineColor: state.outlineColor.withAlphaComponent(1.0),
                outlineWidth: state.outlineWidth,
                font: resolveFont(family: state.fontName, size: state.fontSize)
            )
        case .area:
            pdfView.penColor = stroke
            pdfView.areaLineWidth = widthValue(for: state.lineWeightLevel, tool: .area)
        case .measure:
            pdfView.measurementStrokeColor = stroke
            pdfView.measurementLineWidth = widthValue(for: state.lineWeightLevel, tool: .measure)
        case .calibrate:
            pdfView.calibrationStrokeColor = stroke
            pdfView.measurementLineWidth = widthValue(for: state.lineWeightLevel, tool: .calibrate)
        case .select, .grab:
            break
        }
    }

    private func inferredToolMode(for annotation: PDFAnnotation) -> ToolMode {
        let type = (annotation.type ?? "").lowercased()
        let contents = (annotation.contents ?? "").lowercased()
        if isFreeTextType(type) {
            return .text
        }
        if (type.contains("square") || type.contains("circle")) &&
            (contents.contains("arrow dot|") || contents.contains("arrow square|")) {
            return contents.contains("callout") ? .callout : .arrow
        }
        if type.contains("square") || type.contains("circle") {
            return .rectangle
        }
        if type.contains("highlight") {
            return .highlighter
        }
        if type.contains("ink") {
            if contents.contains("arrow|style:") {
                return .arrow
            }
            if contents.contains("highlighter") {
                return .highlighter
            }
            if contents.contains("polyline") {
                return .polyline
            }
            if contents == "line" {
                return .line
            }
            if contents.contains("area") {
                return .area
            }
            if contents.contains("callout") {
                return .callout
            }
            if contents.contains("measure") {
                return .measure
            }
            return .pen
        }
        if type.contains("line") {
            return .measure
        }
        return .pen
    }

    private func interpolateLevel(_ level: Int, lowAt1: CGFloat, midAt5: CGFloat, highAt10: CGFloat) -> CGFloat {
        if level <= 5 {
            let t = CGFloat(level - 1) / 4.0
            return lowAt1 + (midAt5 - lowAt1) * t
        }
        let t = CGFloat(level - 5) / 5.0
        return midAt5 + (highAt10 - midAt5) * t
    }
}
