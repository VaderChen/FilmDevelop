import Foundation
import PhotoStyleShared
import AppKit

extension PhotoStyleWebCoordinator {
    func updateActionAvailability() {
        canImport = !isTerminating && !isMCPMutating && !isLoadingImage && !isComputing && !isSavingImage && !isRepairingImage
        canExport = canImport && !isRenderingPreview && sourceImage != nil && outputImage != nil
        canCompute = selectedStyle != .original && canImport && sourceImage != nil && aiModelStore.status.ready && !aiModelStore.isBusy
    }

    func sendState(includeImages: Bool, externalEdit: Bool = false) {
        updateActionAvailability()
        guard webView != nil else { return }
        var payload = baseStatePayload()
        payload["externalEdit"] = externalEdit
        if includeImages {
            payload["loadingPreviewImage"] = loadingPreviewImagePayload ?? NSNull()
            for key in ["cropSourceImage", "repairSourceImage", "sourceImage", "outputImage"] {
                payload[key] = previewImagePayload[key] ?? NSNull()
            }
        }
        callJavaScript(function: "handleNativeState", payload: payload)
    }

    func baseStatePayload() -> [String: Any] {
        [
            "isRepairingImage": isRepairingImage,
            "repairStep": repairStep,
            "repairModelProgress": repairModelProgress.map { $0.payload } as Any? ?? NSNull(),
            "isCancellingRepair": isCancellingRepair,
            "repairRevision": repairRevision,
            "repairCount": repairPatches.count,
            "canUndo": !editUndoStack.isEmpty,
            "canRedo": !editRedoStack.isEmpty,
            "sourceFileName": sourceFileName,
            "photoGeneration": photoGeneration.uuidString,
            "previewRevision": previewRevision,
            "photoDirectory": photoDirectoryPayload(),
            "mcp": ["enabled": mcpEnabled, "running": mcpServer.isRunning, "status": mcpServer.status,
                    "endpoint": mcpServer.endpoint, "connectionFile": mcpServer.connectionFile.path],
            "selectedStyle": selectedStyle.rawValue,
            "selectedCustomFilmID": selectedCustomFilmID as Any? ?? NSNull(),
            "hdrFeatureEnabled": hdrFeatureEnabled,
            "originalResolutionEditing": originalResolutionEditing,
            "styles": PhotoStyle.allCases.map(stylePayload(_:)) + customFilmStore.films.map(customFilmPayload(_:)),
            "adjustments": adjustmentPayloads(),
            "adjustmentDefaults": adjustmentPayload(currentFilmDefaults),
            "cropAspectRatios": CropAspectRatio.allCases.map {
                ["id": $0.rawValue, "title": $0.title(for: previewImage?.size ?? sourceImage?.size)]
            },
            "frameStyles": FrameStyle.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "dateStyles": DateStampStyle.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "filmIlluminants": PhotoFilmEffects.Illuminant.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "hasImage": sourceImage != nil,
            "cropSourceImageSize": sourceImage.map { ["width": $0.size.width, "height": $0.size.height] } ?? [:],
            "sourceImageSize": croppedImageSizePayload(
                sourceImage,
                adjustment: adjustmentStore.adjustment(for: selectedStyle)
            ) ?? NSNull(),
            "previewOutputSize": sourceImage.map { image -> [String: CGFloat] in
                let size = PhotoStyleProcessor.renderedOutputSize(for:image.size, adjustment:adjustmentStore.adjustment(for:selectedStyle))
                return ["width":size.width, "height":size.height]
            } ?? [:],
            "canSave": sourceImage != nil && outputImage != nil && !isRenderingPreview,
            "isRenderingPreview": isRenderingPreview,
            "isLoadingImage": isLoadingImage,
            "isComputing": isComputing,
            "isMCPMutating": isMCPMutating,
            "isCancellingComputation": isCancellingComputation,
            "canCancelComputation": canCancelComputation,
            "computationStep": computationStep,
            "computationItems": isComputing ? Self.aiComputationItems : [],
            "computationCompletedItems": computationCompletedItemCount,
            "isSavingImage": isSavingImage,
            "savingStep": savingStep,
            "expandAdjustments": consumeExpandAdjustmentsAfterComputation(),
            "subjectMask": [
                "available": renderer.canDetectSubjectMask,
                "detecting": isDetectingSubjectMask
            ],
            "ai": aiPayload()
        ]
    }

    func consumeExpandAdjustmentsAfterComputation() -> Bool {
        let shouldExpand = shouldExpandAdjustmentsAfterComputation
        shouldExpandAdjustmentsAfterComputation = false
        return shouldExpand
    }

    var currentFilmDefaults: StyleAdjustment {
        customFilmStore.film(id: selectedCustomFilmID)?.adjustment ?? .default(for: selectedStyle)
    }

    func customFilmPayload(_ film: CustomFilm) -> [String: Any] {
        guard let base = PhotoStyle(rawValue: film.baseStyle) else { return [:] }
        var payload = stylePayload(base)
        payload["id"] = film.id
        payload["title"] = film.name
        payload["subtitle"] = "以「\(base.title)」為基礎儲存的自訂參數。"
        payload["isCustom"] = true
        payload["baseStyle"] = film.baseStyle
        payload["filmFamilyTitle"] = "自訂底片"
        return payload
    }

    func stylePayload(_ style: PhotoStyle) -> [String: Any] {
        [
            "id": style.rawValue,
            "title": style.title,
            "subtitle": style.subtitle,
            "isMonochrome": style.isMonochrome,
            "isOriginal": style == .original,
            "isFilmStock": style.filmStock != nil,
            "filmFamily": style.filmStock?.family ?? "",
            "filmFamilyTitle": style == .original ? "原始影像" : (style.filmStock?.familyTitle ?? ""),
            "filmAlgorithm": style.filmStock?.algorithmDescription ?? "",
            "prompt": stylePromptStore.prompt(for: style, language: promptLanguage),
            "prompts": stylePromptStore.prompts(for: style),
            "defaultPrompt": style.llmDescription(for: promptLanguage),
            "defaultPrompts": style.llmDescriptions,
            "promptCustomized": stylePromptStore.customPrompt(for: style, language: promptLanguage) != nil,
            "promptCustomizedLanguages": stylePromptStore.customizedLanguages(for: style),
            "palette": palette(for: style)
        ]
    }

    func adjustmentPayloads() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: PhotoStyle.allCases.map { style in
            (style.rawValue, adjustmentPayload(adjustmentStore.adjustment(for: style)))
        })
    }

    func adjustmentPayload(_ adjustment: StyleAdjustment) -> [String: Any] {
        [
            "colorCalibrationName": adjustment.colorCalibration?.name ?? "",
            "colorCalibrationStage": adjustment.colorCalibration?.stage.rawValue ?? "",
            "intensity": adjustment.intensity,
            "exposure": adjustment.exposure,
            "whiteBalanceWarmth": adjustment.whiteBalanceWarmth,
            "whiteBalanceTint": adjustment.whiteBalanceTint,
            "brightness": adjustment.brightness,
            "contrast": adjustment.contrast,
            "grain": adjustment.grain,
            "filmColorModel": adjustment.filmEffects.colorModel.rawValue,
            "printIlluminant": adjustment.filmEffects.printIlluminant.rawValue,
            "viewIlluminant": adjustment.filmEffects.viewIlluminant.rawValue,
            "scannerProfile": adjustment.filmEffects.scannerProfile.rawValue,
            "scannerIlluminant": adjustment.filmEffects.scannerIlluminant.rawValue,
            "scanExposure": adjustment.filmEffects.scanExposure,
            "scanContrast": adjustment.filmEffects.scanContrast,
            "scanSaturation": adjustment.filmEffects.scanSaturation,
            "scanDensityCorrection": adjustment.filmEffects.scanDensityCorrection,
            "scanFlare": adjustment.filmEffects.scanFlare,
            "scanMidtoneWarmth": adjustment.filmEffects.scanMidtoneWarmth,
            "scanHighlightWarmth": adjustment.filmEffects.scanHighlightWarmth,
            "printExposure": adjustment.filmEffects.printExposure,
            "printContrast": adjustment.filmEffects.printContrast,
            "developmentAmount": adjustment.filmEffects.developmentAmount,
            "developmentTime": adjustment.filmEffects.developmentTime,
            "developmentDiffusion": adjustment.filmEffects.developmentDiffusion,
            "developmentAgitation": adjustment.filmEffects.developmentAgitation,
            "grainMode": adjustment.filmEffects.grainMode.rawValue,
            "grainSize": adjustment.filmEffects.grainSize,
            "grainClumping": adjustment.filmEffects.grainClumping,
            "grainChroma": adjustment.filmEffects.grainChroma,
            "bloomAmount": adjustment.filmEffects.bloomAmount,
            "bloomRadius": adjustment.filmEffects.bloomRadius,
            "bloomThreshold": adjustment.filmEffects.bloomThreshold,
            "halationAmount": adjustment.filmEffects.halationAmount,
            "halationRadius": adjustment.filmEffects.halationRadius,
            "halationThreshold": adjustment.filmEffects.halationThreshold,
            "monochromeFilter": adjustment.filmEffects.monochromeFilter.rawValue,
            "monochromeFilterStrength": adjustment.filmEffects.monochromeFilterStrength,
            "vignette": adjustment.vignette,
            "denoise": adjustment.denoise,
            "devignette": adjustment.devignette,
            "backgroundBlur": adjustment.backgroundBlur,
            "skinWarmth": adjustment.skinWarmth,
            "skinWhitening": adjustment.skinWhitening,
            "skinSmoothing": adjustment.skinSmoothing,
            "hdrAmount": adjustment.hdrAmount,
            "hdrToneCurve": adjustment.hdrToneCurve.map { curve in
                ["black": curve.black, "shadows": curve.shadows, "midtones": curve.midtones,
                 "highlights": curve.highlights, "white": curve.white, "detail": curve.detail]
            } ?? NSNull(),
            "cropAspectRatio": adjustment.cropAspectRatio.rawValue,
            "cropRotation": adjustment.cropRotation,
            "cropScale": adjustment.cropScale,
            "cropWidth": adjustment.cropWidth,
            "cropHeight": adjustment.cropHeight,
            "cropHorizontalPosition": adjustment.cropHorizontalPosition,
            "cropVerticalPosition": adjustment.cropVerticalPosition,
            "highlightExposure": adjustment.highlightExposure,
            "highlightIntensity": adjustment.highlightIntensity,
            "highlightWarmth": adjustment.highlightWarmth,
            "highlightGrain": adjustment.highlightGrain,
            "midtoneExposure": adjustment.midtoneExposure,
            "midtoneIntensity": adjustment.midtoneIntensity,
            "midtoneWarmth": adjustment.midtoneWarmth,
            "midtoneGrain": adjustment.midtoneGrain,
            "shadowExposure": adjustment.shadowExposure,
            "shadowIntensity": adjustment.shadowIntensity,
            "shadowWarmth": adjustment.shadowWarmth,
            "shadowGrain": adjustment.shadowGrain,
            "sourceToneZones": adjustment.sourceToneZones.map(toneZonesPayload(_:)) ?? NSNull(),
            "frameEnabled": adjustment.frameEnabled,
            "frameStyle": adjustment.frameStyle.rawValue,
            "dateEnabled": adjustment.dateEnabled,
            "dateStyle": adjustment.dateStyle.rawValue
        ]
    }

    func toneZonesPayload(_ toneZones: PhotoStylePlan.ToneZones) -> [String: Any] {
        [
            "shadows": toneAdjustmentPayload(toneZones.shadows),
            "midtones": toneAdjustmentPayload(toneZones.midtones),
            "highlights": toneAdjustmentPayload(toneZones.highlights)
        ]
    }

    func toneAdjustmentPayload(_ adjustment: PhotoStylePlan.ToneAdjustment) -> [String: Any] {
        [
            "baseTone": adjustment.baseTone,
            "contrast": adjustment.contrast,
            "softness": adjustment.softness,
            "highlights": adjustment.highlights,
            "shadows": adjustment.shadows,
            "fade": adjustment.fade,
            "tint": adjustment.tint
        ]
    }

    func aiPayload() -> [String: Any] {
        let status = aiModelStore.status
        let progress = aiModelStore.downloadProgress
        let importing = aiModelStore.importProgress
        let presetFileNames = Set(AIModelStore.presets.map { $0.mainFile.fileName })
        let activeIsCustom = !status.activeModelFileName.isEmpty && (aiModelStore.usingModelDirectory || !presetFileNames.contains(status.activeModelFileName))
        let customModelFileName = activeIsCustom
            ? status.activeModelFileName
            : (status.modelFiles.first { !presetFileNames.contains($0) } ?? "")
        let catalog = aiModelStore.directoryCatalog
        let modelChoices: [[String: Any]] = catalog.models.map { model in
            ["id": "directory:" + model.id, "title": model.title, "ready": model.ready,
             "message": model.message, "source": "directory", "format": model.format]
        } + status.modelFiles.map { fileName in
            ["id": "installed:" + fileName, "title": fileName, "ready": true,
             "message": "", "source": "installed", "format": "gguf"]
        }
        return [
            "modelChoices": modelChoices,
            "format": status.family == "mlx" ? "mlx" : "gguf",
            "mlxAvailable": AIModelRuntimeSupport.isAvailable,
            "mlxMessage": AIModelRuntimeSupport.availabilityMessage,
            "repository": aiModelStore.repositoryBrowser.payload(),
            "downloadDirectory": aiModelStore.repositoryDownloadDirectory.path,
            "selectedModelID": aiModelStore.selectedModelID,
            "modelDirectoryPath": catalog.directoryURL?.path ?? "",
            "modelDirectoryScanning": catalog.isScanning,
            "modelDirectoryMessage": catalog.message,
            "usingModelDirectory": aiModelStore.usingModelDirectory,
            "ready": status.ready && !aiModelStore.isBusy,
            "busy": aiModelStore.isBusy,
            "import": ["active": importing.active, "fileName": importing.fileName,
                       "fraction": importing.fraction, "percent": importing.percent,
                       "completedFiles": importing.completedFiles, "totalFiles": importing.totalFiles,
                       "isCancelling": importing.isCancelling],
            "status": status.status,
            "message": status.message,
            "activeModelFileName": status.activeModelFileName,
            "customModelFileName": customModelFileName,
            "customInstalled": !customModelFileName.isEmpty,
            "customActive": activeIsCustom,
            "modelDirectory": status.modelDirectory.path,
            "modelFiles": status.modelFiles,
            "download": [
                "active": progress.active,
                "fileName": progress.fileName,
                "completedFiles": progress.completedFiles,
                "totalFiles": progress.totalFiles,
                "fraction": progress.fraction,
                "percent": progress.percent
            ],
            "presets": AIModelStore.presets.map { preset in
                [
                    "id": preset.id,
                    "title": preset.title,
                    "subtitle": preset.subtitle,
                    "meta": preset.meta,
                    "pageURL": preset.pageURL.absoluteString,
                    "fileName": preset.mainFile.fileName,
                    "installed": status.modelFiles.contains(preset.mainFile.fileName),
                    "active": !aiModelStore.usingModelDirectory && status.activeModelFileName == preset.mainFile.fileName
                ] as [String: Any]
            }
        ]
    }

    func sendToast(_ message: String) {
        lastMessage = message
        callJavaScript(function: "handleNativeToast", payload: ["message": message])
    }

    func callJavaScript(function: String, payload: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let update = { webView.evaluateJavaScript("window.\(function) && window.\(function)(\(json));") }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
}
