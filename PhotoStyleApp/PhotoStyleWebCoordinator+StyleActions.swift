import Foundation
import AppKit
import UniformTypeIdentifiers
import PhotoStyleShared

extension PhotoStyleWebCoordinator {
    func promptToSaveCustomFilm(name: String = "") {
        guard sourceImage != nil, canImport, let window = webView?.window, window.attachedSheet == nil else { return }
        let generation = photoGeneration
        let style = selectedStyle
        let recipe = adjustmentStore.adjustment(for: style)
        let alert = NSAlert()
        alert.messageText = PhotoL10n.text("儲存自訂底片")
        alert.informativeText = PhotoL10n.text("為目前的調整參數命名，之後即可從底片庫套用。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.placeholderString = PhotoL10n.text("底片名稱")
        field.stringValue = name
        alert.accessoryView = field
        alert.addButton(withTitle: PhotoL10n.text("儲存"))
        alert.addButton(withTitle: PhotoL10n.text("取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canImport,
                  self.photoGeneration == generation, self.selectedStyle == style,
                  self.adjustmentStore.adjustment(for: style) == recipe else { return }
            do {
                let film = try self.customFilmStore.save(name: field.stringValue, baseStyle: style, adjustment: recipe)
                if self.selectedCustomFilmID == nil { self.customFilmBaseAdjustment = recipe }
                self.selectedCustomFilmID = film.id
                self.recordEditHistory()
                self.persistCurrentPhotoEdits()
                self.sendState(includeImages: false, externalEdit: true)
                self.sendToast("已儲存「\(film.name)」。")
            } catch { self.sendToast(error.localizedDescription) }
        }
    }

    func promptToDeleteCustomFilm(_ payload: [String: Any]) {
        guard canImport, let id = payload["id"] as? String, let film = customFilmStore.film(id: id),
              let window = webView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = PhotoL10n.text("刪除自訂底片「\(film.name)」？")
        alert.informativeText = PhotoL10n.text("刪除後，已套用到照片上的調整會保留。")
        alert.addButton(withTitle: PhotoL10n.text("刪除"))
        alert.addButton(withTitle: PhotoL10n.text("取消"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.deleteCustomFilm(id: id) }
            catch { self.sendToast(error.localizedDescription) }
        }
    }

    @discardableResult
    func deleteCustomFilm(id: String) throws -> Bool {
        guard canImport, let film = customFilmStore.film(id: id), try customFilmStore.remove(id: id) else { return false }
        filmHoverPreview.cancel(clearCache: true)
        // Detach the recipe identity without changing any photo's working parameters.
        if selectedCustomFilmID == id {
            selectedCustomFilmID = nil
            customFilmBaseAdjustment = nil
            persistCurrentPhotoEdits()
        }
        func detach(_ snapshot: EditSnapshot) -> EditSnapshot {
            var snapshot = snapshot
            if snapshot.customFilmID == id {
                snapshot.customFilmID = nil
                snapshot.customFilmBaseAdjustment = nil
            }
            return snapshot
        }
        editUndoStack = editUndoStack.map(detach)
        editRedoStack = editRedoStack.map(detach)
        lastEditSnapshot = lastEditSnapshot.map(detach)
        sendState(includeImages: false, externalEdit: true)
        sendToast("\(film.name) 已刪除")
        return true
    }

    // The active custom recipe occupies its base style's working slot. Restore
    // that slot before switching, without adding an intermediate history step.
    func restoreCustomFilmBaseAdjustment() {
        guard selectedCustomFilmID != nil else { return }
        let wasRestoring = isRestoringPhotoEdits
        isRestoringPhotoEdits = true
        adjustmentStore.setAdjustment(customFilmBaseAdjustment ?? .default(for: selectedStyle), for: selectedStyle)
        isRestoringPhotoEdits = wasRestoring
        selectedCustomFilmID = nil
        customFilmBaseAdjustment = nil
    }

    func applyCustomFilm(_ film: CustomFilm) {
        guard let base = PhotoStyle(rawValue: film.baseStyle) else { return }
        restoreCustomFilmBaseAdjustment()
        customFilmBaseAdjustment = adjustmentStore.adjustment(for: base)
        selectedStyle = base
        selectedCustomFilmID = film.id
        UserDefaults.standard.set(base.rawValue, forKey: Self.selectedStyleDefaultsKey)
        adjustmentStore.setAdjustment(film.adjustment, for: base)
        recordEditHistory()
        persistCurrentPhotoEdits()
        applySelectedStyle()
        sendState(includeImages: true, externalEdit: true)
    }

    func sampleWhiteBalance(_ payload: [String: Any]) {
        guard let rgb = payload["rgb"] as? [Double], rgb.count == 3,
              rgb.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), sourceImage != nil,
              !isRenderingPreview, !isLoadingImage, !isComputing, !isSavingImage, !isMCPMutating,
              !isDetectingSubjectMask, !isTerminating,
              payload["photoGeneration"] as? String == photoGeneration.uuidString,
              payload["style"] as? String == selectedStyle.rawValue,
              payload["customFilmID"] as? String == selectedCustomFilmID,
              (payload["previewRevision"] as? NSNumber)?.uint64Value == previewRevision else { return }
        guard !selectedStyle.isMonochrome else { sendToast("請使用彩色照片取樣白平衡。"); return }
        let style = selectedStyle, generation = photoGeneration, customID = selectedCustomFilmID
        let revision = previewRevision
        let adjustment = adjustmentStore.adjustment(for: style)
        guard adjustment.intensity > 0 else { sendToast("請先提高風格強度，再取樣白平衡。"); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PhotoToneProcessor.neutralBalance(sRGB: rgb,
                warmth: adjustment.whiteBalanceWarmth, tint: adjustment.whiteBalanceTint,
                strength: adjustment.intensity / 100)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.photoGeneration == generation, self.selectedStyle == style,
                      self.selectedCustomFilmID == customID, self.previewRevision == revision,
                      !self.isLoadingImage, !self.isComputing, !self.isSavingImage, !self.isMCPMutating,
                      !self.isDetectingSubjectMask, !self.isTerminating,
                      self.adjustmentStore.adjustment(for: style) == adjustment else { return }
                guard let result else { self.sendToast("此處過暗或已過曝，請改選灰色或白色區域。"); return }
                self.updateAdjustments([
                    ["style": style.rawValue, "key": "whiteBalanceWarmth", "value": result.warmth],
                    ["style": style.rawValue, "key": "whiteBalanceTint", "value": result.tint]
                ])
                self.sendState(includeImages: true, externalEdit: true)
            }
        }
    }

    func setStyle(_ payload: [String: Any]) {
        if let id = payload["style"] as? String, let film = customFilmStore.film(id: id) {
            applyCustomFilm(film)
            return
        }
        guard let rawValue = payload["style"] as? String,
              let style = PhotoStyle(rawValue: rawValue) else {
            return
        }
        let wasCustom = selectedCustomFilmID != nil
        let hasAvailableAI = aiModelStore.status.ready && !aiModelStore.isBusy
        guard wasCustom || style != selectedStyle || !hasAvailableAI || style == .original else { return }
        let nextAdjustment = adjustmentForSelectingStyle(style)
        restoreCustomFilmBaseAdjustment()
        selectedStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.selectedStyleDefaultsKey)
        adjustmentStore.setAdjustment(nextAdjustment, for: style)
        applySelectedStyle()
        sendState(includeImages: true)
    }

    // Both hover and a committed selection resolve the same recipe without writes.
    func adjustmentForSelectingStyle(_ style: PhotoStyle) -> StyleAdjustment {
        let currentAdjustment = adjustmentStore.adjustment(for: selectedStyle)
        let previous = selectedCustomFilmID != nil && style == selectedStyle
            ? (customFilmBaseAdjustment ?? .default(for: style)) : adjustmentStore.adjustment(for: style)
        let hasAvailableAI = aiModelStore.status.ready && !aiModelStore.isBusy
        if !hasAvailableAI || style == .original {
            return StyleAdjustmentStore.defaultAdjustment(for: style, previous: previous, preservingCropFrom: currentAdjustment)
        }
        let currentExposure = currentAdjustment.exposure
        var nextAdjustment = previous
        // Keep an existing image-specific AI result when revisiting a style.
        // Styles without an analysis continue to share the photo's base exposure.
        if nextAdjustment.sourceToneZones == nil {
            nextAdjustment.exposure = currentExposure
        }
        nextAdjustment.hdrAmount = currentAdjustment.hdrAmount
        if nextAdjustment.hdrToneCurve == nil {
            nextAdjustment.hdrToneCurve = currentAdjustment.hdrToneCurve
        }
        nextAdjustment.cropAspectRatio = currentAdjustment.cropAspectRatio
        nextAdjustment.cropRotation = currentAdjustment.cropRotation
        nextAdjustment.cropScale = currentAdjustment.cropScale
        nextAdjustment.cropWidth = currentAdjustment.cropWidth
        nextAdjustment.cropHeight = currentAdjustment.cropHeight
        nextAdjustment.cropHorizontalPosition = currentAdjustment.cropHorizontalPosition
        nextAdjustment.cropVerticalPosition = currentAdjustment.cropVerticalPosition
        nextAdjustment.imageScoped = nextAdjustment.imageScoped
            || abs(currentExposure) > 0.001
            || currentAdjustment.hdrToneCurve != nil
            || currentAdjustment.cropAspectRatio != .original
            || currentAdjustment.cropRotation != 0
        return nextAdjustment
    }

    func resetAdjustments(_ payload: [String: Any]) {
        guard sourceImage != nil, !isTerminating, !isLoadingImage, !isComputing,
              !isSavingImage, !isMCPMutating, !isDetectingSubjectMask,
              payload["style"] as? String == selectedStyle.rawValue else { return }
        adjustmentStore.setAdjustment(currentFilmDefaults, for: selectedStyle)
        if let url = sourceFileURL { photoEditStore.clearEdited(at: url) }
        resetEditHistory()
        applySelectedStyle()
        sendState(includeImages: true)
        sendToast("\(customFilmStore.film(id: selectedCustomFilmID)?.name ?? PhotoL10n.text(selectedStyle.title)) 已恢復預設值。")
    }

    func setLanguage(_ payload: [String: Any]) {
        let preference = payload["preference"] as? String ?? payload["language"] as? String ?? "automatic"
        let language = PhotoL10n.resolve(preference)
        UserDefaults.standard.set(preference, forKey: PhotoL10n.preferenceKey)
        promptLanguage = language
        UserDefaults.standard.set(language, forKey: Self.promptLanguageDefaultsKey)
        sendState(includeImages: false)
    }

    func setOriginalResolutionEditing(_ payload: [String: Any]) {
        guard let enabled = boolValue(from: payload["enabled"]),
              enabled != originalResolutionEditing else { return }
        originalResolutionEditing = enabled
        UserDefaults.standard.set(enabled, forKey: Self.originalResolutionEditingDefaultsKey)
        applySelectedStyle()
        sendState(includeImages: true)
    }

    func setHDRFeatureEnabled(_ payload: [String: Any]) {
        guard let enabled = boolValue(from: payload["enabled"]),
              enabled != hdrFeatureEnabled else {
            return
        }
        hdrFeatureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hdrFeatureEnabledDefaultsKey)
        applySelectedStyle()
        sendState(includeImages: true)
    }

    func updateAdjustment(_ payload: [String: Any]) {
        updateAdjustments([payload])
    }

    // Apply a transaction before rendering so MCP batches never publish partial edits.
    func updateAdjustments(_ payloads: [[String: Any]], detectSubjectMask: Bool = true, interactive: Bool = false) {
        guard !payloads.isEmpty else { return }
        let previousHistoryBatch = editHistoryBatchID
        editHistoryBatchID = previousHistoryBatch ?? UUID().uuidString
        defer { editHistoryBatchID = previousHistoryBatch }
        // Film edits have a strict shared contract. Reject a malformed batch before
        // changing any style so a bad enum/value cannot partially apply other edits.
        let filmKeys = Set(["scannerProfile", "scannerIlluminant", "scanExposure", "scanContrast", "scanSaturation", "scanDensityCorrection", "scanFlare", "scanMidtoneWarmth", "scanHighlightWarmth", "printIlluminant", "viewIlluminant", "filmColorModel", "printExposure", "printContrast", "developmentAmount", "developmentTime", "developmentDiffusion", "developmentAgitation", "grainMode", "grainSize", "grainClumping", "grainChroma",
                            "bloomAmount", "bloomRadius", "bloomThreshold",
                            "halationAmount", "halationRadius", "halationThreshold",
                            "monochromeFilter", "monochromeFilterStrength"])
        for payload in payloads {
            if let key = payload["key"] as? String, filmKeys.contains(key) {
                guard let value = payload["value"],
                      (try? PhotoStyleMCPTools.validate("update_adjustments", arguments: ["changes": [key: value]])) != nil else { return }
            }
        }
        var updates: [PhotoStyle: StyleAdjustment] = [:]
        var needsSubjectMask = false
        for payload in payloads {
            let style = (payload["style"] as? String).flatMap(PhotoStyle.init(rawValue:)) ?? selectedStyle
            var adjustment = updates[style] ?? adjustmentStore.adjustment(for: style)
            let previous = adjustment

            if let cropValues = payload["cropValues"] as? [String: Any] {
                var hasValidCropValue = false
                if let raw = cropValues["cropAspectRatio"] as? String, let ratio = CropAspectRatio(rawValue: raw) {
                    adjustment.cropAspectRatio = ratio
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropRotation"]) {
                    adjustment.cropRotation = value
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropScale"]) {
                    adjustment.cropScale = value
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropWidth"]) {
                    adjustment.cropWidth = value
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropHeight"]) {
                    adjustment.cropHeight = value
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropHorizontalPosition"]) {
                    adjustment.cropHorizontalPosition = value
                    hasValidCropValue = true
                }
                if let value = doubleValue(from: cropValues["cropVerticalPosition"]) {
                    adjustment.cropVerticalPosition = value
                    hasValidCropValue = true
                }
                if hasValidCropValue { adjustment.imageScoped = true }
            } else if let key = payload["key"] as? String {
                let value = payload["value"]
                if updateSourceToneAdjustment(&adjustment, key: key, value: value) {
                    adjustment.imageScoped = true
                } else {
                    switch key {
                case "intensity":
                    adjustment.intensity = doubleValue(from: value) ?? adjustment.intensity
                case "exposure":
                    adjustment.exposure = doubleValue(from: value) ?? adjustment.exposure
                case "whiteBalanceWarmth":
                    adjustment.whiteBalanceWarmth = doubleValue(from: value) ?? adjustment.whiteBalanceWarmth
                case "whiteBalanceTint":
                    adjustment.whiteBalanceTint = doubleValue(from: value) ?? adjustment.whiteBalanceTint
                case "brightness":
                    adjustment.brightness = doubleValue(from: value) ?? adjustment.brightness
                case "contrast":
                    adjustment.contrast = doubleValue(from: value) ?? adjustment.contrast
                case "grain":
                    adjustment.grain = doubleValue(from: value) ?? adjustment.grain
                case "grainMode":
                    if let rawValue = value as? String, let mode = PhotoFilmEffects.GrainMode(rawValue: rawValue) { adjustment.filmEffects.grainMode = mode }
                case "filmColorModel":
                    if let rawValue = value as? String, let model = PhotoFilmEffects.ColorModel(rawValue: rawValue) { adjustment.filmEffects.colorModel = model }
                case "printIlluminant": adjustment.filmEffects.printIlluminant = PhotoFilmEffects.Illuminant(rawValue: value as! String)!
                case "viewIlluminant": adjustment.filmEffects.viewIlluminant = PhotoFilmEffects.Illuminant(rawValue: value as! String)!
                case "scannerProfile": adjustment.filmEffects.scannerProfile = PhotoFilmEffects.ScannerProfile(rawValue: value as! String)!
                case "scannerIlluminant": adjustment.filmEffects.scannerIlluminant = PhotoFilmEffects.Illuminant(rawValue: value as! String)!
                case "scanExposure": adjustment.filmEffects.scanExposure = doubleValue(from: value)!
                case "scanContrast": adjustment.filmEffects.scanContrast = doubleValue(from: value)!
                case "scanSaturation": adjustment.filmEffects.scanSaturation = doubleValue(from: value)!
                case "scanDensityCorrection": adjustment.filmEffects.scanDensityCorrection = doubleValue(from: value)!
                case "scanFlare": adjustment.filmEffects.scanFlare = doubleValue(from: value)!
                case "scanMidtoneWarmth": adjustment.filmEffects.scanMidtoneWarmth = doubleValue(from: value)!
                case "scanHighlightWarmth": adjustment.filmEffects.scanHighlightWarmth = doubleValue(from: value)!
                case "printExposure": adjustment.filmEffects.printExposure = doubleValue(from: value)!
                case "printContrast": adjustment.filmEffects.printContrast = doubleValue(from: value)!
                case "developmentAmount": adjustment.filmEffects.developmentAmount = doubleValue(from: value)!
                case "developmentTime": adjustment.filmEffects.developmentTime = doubleValue(from: value)!
                case "developmentDiffusion": adjustment.filmEffects.developmentDiffusion = doubleValue(from: value)!
                case "developmentAgitation": adjustment.filmEffects.developmentAgitation = doubleValue(from: value)!
                case "monochromeFilter":
                    if let rawValue = value as? String, let filter = PhotoFilmEffects.MonochromeFilter(rawValue: rawValue) { adjustment.filmEffects.monochromeFilter = filter }
                case "grainSize": adjustment.filmEffects.grainSize = doubleValue(from: value)!
                case "grainClumping": adjustment.filmEffects.grainClumping = doubleValue(from: value)!
                case "grainChroma": adjustment.filmEffects.grainChroma = doubleValue(from: value)!
                case "bloomAmount": adjustment.filmEffects.bloomAmount = doubleValue(from: value)!
                case "bloomRadius": adjustment.filmEffects.bloomRadius = doubleValue(from: value)!
                case "bloomThreshold": adjustment.filmEffects.bloomThreshold = doubleValue(from: value)!
                case "halationAmount": adjustment.filmEffects.halationAmount = doubleValue(from: value)!
                case "halationRadius": adjustment.filmEffects.halationRadius = doubleValue(from: value)!
                case "halationThreshold": adjustment.filmEffects.halationThreshold = doubleValue(from: value)!
                case "monochromeFilterStrength": adjustment.filmEffects.monochromeFilterStrength = doubleValue(from: value)!
                case "vignette":
                    adjustment.vignette = doubleValue(from: value) ?? adjustment.vignette
                case "denoise":
                    adjustment.denoise = doubleValue(from: value) ?? adjustment.denoise
                case "devignette":
                    adjustment.devignette = doubleValue(from: value) ?? adjustment.devignette
                case "vignetteBalance":
                    guard let rawBalance = doubleValue(from: value) else { continue }
                    let balance: Double = min(max(rawBalance, -100.0), 100.0)
                    adjustment.vignette = max(balance, 0.0)
                    adjustment.devignette = max(-balance, 0.0)
                case "backgroundBlur":
                    adjustment.backgroundBlur = doubleValue(from: value) ?? adjustment.backgroundBlur
                case "skinWhitening":
                    adjustment.skinWhitening = doubleValue(from: value) ?? adjustment.skinWhitening
                case "skinSmoothing":
                    adjustment.skinSmoothing = doubleValue(from: value) ?? adjustment.skinSmoothing
                case "hdrAmount":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.hdrAmount = number
                case "cropAspectRatio":
                    if let value = value as? String,
                       let cropAspectRatio = CropAspectRatio(rawValue: value) {
                        adjustment.cropAspectRatio = cropAspectRatio
                        adjustment.imageScoped = true
                    }
                case "cropRotation":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropRotation = number
                    adjustment.imageScoped = true
                case "cropScale":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropScale = number
                    adjustment.imageScoped = true
                case "cropWidth":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropWidth = number
                    adjustment.imageScoped = true
                case "cropHeight":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropHeight = number
                    adjustment.imageScoped = true
                case "cropHorizontalPosition":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropHorizontalPosition = number
                    adjustment.imageScoped = true
                case "cropVerticalPosition":
                    guard let number = doubleValue(from: value) else { continue }
                    adjustment.cropVerticalPosition = number
                    adjustment.imageScoped = true
                case "highlightExposure":
                    adjustment.highlightExposure = doubleValue(from: value) ?? adjustment.highlightExposure
                case "highlightIntensity":
                    adjustment.highlightIntensity = doubleValue(from: value) ?? adjustment.highlightIntensity
                case "highlightWarmth":
                    adjustment.highlightWarmth = doubleValue(from: value) ?? adjustment.highlightWarmth
                case "highlightGrain":
                    adjustment.highlightGrain = doubleValue(from: value) ?? adjustment.highlightGrain
                case "midtoneExposure":
                    adjustment.midtoneExposure = doubleValue(from: value) ?? adjustment.midtoneExposure
                case "midtoneIntensity":
                    adjustment.midtoneIntensity = doubleValue(from: value) ?? adjustment.midtoneIntensity
                case "midtoneWarmth":
                    adjustment.midtoneWarmth = doubleValue(from: value) ?? adjustment.midtoneWarmth
                case "midtoneGrain":
                    adjustment.midtoneGrain = doubleValue(from: value) ?? adjustment.midtoneGrain
                case "shadowExposure":
                    adjustment.shadowExposure = doubleValue(from: value) ?? adjustment.shadowExposure
                case "shadowIntensity":
                    adjustment.shadowIntensity = doubleValue(from: value) ?? adjustment.shadowIntensity
                case "shadowWarmth":
                    adjustment.shadowWarmth = doubleValue(from: value) ?? adjustment.shadowWarmth
                case "shadowGrain":
                    adjustment.shadowGrain = doubleValue(from: value) ?? adjustment.shadowGrain
                case "frameEnabled":
                    adjustment.frameEnabled = boolValue(from: value) ?? adjustment.frameEnabled
                case "dateEnabled":
                    adjustment.dateEnabled = boolValue(from: value) ?? adjustment.dateEnabled
                case "frameStyle":
                    if let value = value as? String {
                        adjustment.frameStyle = FrameStyle(rawValue: value) ?? adjustment.frameStyle
                    }
                case "dateStyle":
                    if let value = value as? String {
                        adjustment.dateStyle = DateStampStyle(rawValue: value) ?? adjustment.dateStyle
                    }
                default:
                    break
                    }
                }
            }

            if adjustment != previous {
                updates[style] = adjustment
                if style == selectedStyle {
                    needsSubjectMask = needsSubjectMask
                        || (adjustment.backgroundBlur > 0 && adjustment.backgroundBlur != previous.backgroundBlur)
                        || (adjustment.skinWhitening > 0 && adjustment.skinWhitening != previous.skinWhitening)
                        || (adjustment.skinSmoothing > 0 && adjustment.skinSmoothing != previous.skinSmoothing)
                }
            }
        }
        guard !updates.isEmpty else { return }
        for (style, adjustment) in updates {
            adjustmentStore.setAdjustment(adjustment, for: style)
        }
        if updates[selectedStyle] != nil {
            applySelectedStyle(detectSubjectMask: detectSubjectMask && needsSubjectMask, interactive: interactive,
                cropPreview: payloads.contains { $0["cropValues"] != nil || ($0["key"] as? String)?.hasPrefix("crop") == true })
        }
        sendState(includeImages: true)
    }

    private func updateSourceToneAdjustment(
        _ adjustment: inout StyleAdjustment,
        key: String,
        value: Any?
    ) -> Bool {
        let region: String
        let field: String
        if key.hasPrefix("highlightPlan") {
            region = "highlights"
            field = String(key.dropFirst("highlightPlan".count))
        } else if key.hasPrefix("midtonePlan") {
            region = "midtones"
            field = String(key.dropFirst("midtonePlan".count))
        } else if key.hasPrefix("shadowPlan") {
            region = "shadows"
            field = String(key.dropFirst("shadowPlan".count))
        } else {
            return false
        }

        guard ["BaseTone", "Contrast", "Softness", "Highlights", "Shadows", "Fade", "Tint"].contains(field),
              let rawValue = doubleValue(from: value) else { return false }
        var toneZones = adjustment.sourceToneZones ?? emptyToneZones()

        func update(_ toneAdjustment: inout PhotoStylePlan.ToneAdjustment) {
            let signedValue = Int(rawValue.rounded().clamped(to: -100...100))
            let unsignedValue = Int(rawValue.rounded().clamped(to: 0...100))
            switch field {
            case "BaseTone":
                toneAdjustment.baseTone = signedValue
            case "Contrast":
                toneAdjustment.contrast = signedValue
            case "Softness":
                toneAdjustment.softness = unsignedValue
            case "Highlights":
                toneAdjustment.highlights = signedValue
            case "Shadows":
                toneAdjustment.shadows = signedValue
            case "Fade":
                toneAdjustment.fade = unsignedValue
            case "Tint":
                toneAdjustment.tint = signedValue
            default:
                break
            }
        }

        switch region {
        case "highlights":
            update(&toneZones.highlights)
        case "midtones":
            update(&toneZones.midtones)
        default:
            update(&toneZones.shadows)
        }
        adjustment.sourceToneZones = toneZones
        return true
    }

    private func emptyToneZones() -> PhotoStylePlan.ToneZones {
        let empty = PhotoStylePlan.ToneAdjustment(
            baseTone: 0,
            exposure: 0,
            contrast: 0,
            softness: 0,
            grain: 0,
            highlights: 0,
            shadows: 0,
            fade: 0,
            warmth: 0,
            tint: 0
        )
        return PhotoStylePlan.ToneZones(
            shadows: empty,
            midtones: empty,
            highlights: empty
        )
    }

    func updateStylePrompt(_ payload: [String: Any]) {
        guard let rawValue = payload["style"] as? String,
              let style = PhotoStyle(rawValue: rawValue),
              let prompt = payload["prompt"] as? String else {
            return
        }
        let language = StylePromptStore.normalizedLanguage(payload["language"] as? String)
        stylePromptStore.setPrompt(prompt, for: style, language: language)
        sendState(includeImages: false)
        sendToast("Prompt 已更新。")
    }

    func resetStylePrompt(_ payload: [String: Any]) {
        guard let rawValue = payload["style"] as? String,
              let style = PhotoStyle(rawValue: rawValue) else {
            return
        }
        let language = StylePromptStore.normalizedLanguage(payload["language"] as? String)
        stylePromptStore.resetPrompt(for: style, language: language)
        sendState(includeImages: false)
        sendToast("Prompt 已還原。")
    }
}


extension PhotoStyleWebCoordinator {
    func openColorCalibrationPicker() {
        guard sourceImage != nil else { sendToast("請先選取照片。"); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = PhotoL10n.text("匯入目前照片／風格的線性色彩校準 JSON")
        // Snapshot the intended photo/style across the asynchronous picker.
        let photo = currentPhotoEditKey, style = selectedStyle
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard !self.isTerminating, !self.isComputing, !self.isLoadingImage, !self.isSavingImage,
                  !self.isMCPMutating, self.currentPhotoEditKey == photo, self.selectedStyle == style else { return }
            do { try self.importColorCalibration(from: url) }
            catch { self.sendToast(error.localizedDescription) }
        }
    }
    func importColorCalibration(from url: URL) throws {
        guard sourceImage != nil else { throw PhotoStyleMCPTools.failure("請先選取照片。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 65536 else { throw PhotoStyleMCPTools.failure("校準檔不得超過 64 KB。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 65536 else { throw PhotoStyleMCPTools.failure("校準檔不得超過 64 KB。") }
        let calibration = try JSONDecoder().decode(PhotoColorCalibration.self, from: data)
        setColorCalibration(calibration)
    }
    func setColorCalibration(_ calibration: PhotoColorCalibration?) {
        guard sourceImage != nil else { return }
        var adjustment = adjustmentStore.adjustment(for: selectedStyle)
        adjustment.colorCalibration = calibration
        adjustment.imageScoped = true
        adjustmentStore.setAdjustment(adjustment, for: selectedStyle)
        applySelectedStyle(detectSubjectMask: false)
        sendState(includeImages: false)
    }
}
