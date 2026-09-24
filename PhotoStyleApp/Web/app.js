(function () {
  "use strict";
  var L = window.PhotoL10n;

  // 發表日期依原始模型公告，來源與格式查核記錄見 docs/AI_MODELS.md。
  var modelRepositorySuggestions = [
    { title: "Qwen3.5 0.8B", released: "2026-03-02", mlx: "mlx-community/Qwen3.5-0.8B-4bit", gguf: "unsloth/Qwen3.5-0.8B-GGUF" },
    { title: "Qwen3.5 2B", released: "2026-03-02", mlx: "mlx-community/Qwen3.5-2B-4bit", gguf: "unsloth/Qwen3.5-2B-GGUF" },
    { title: "Qwen3.5 4B", released: "2026-03-02", mlx: "mlx-community/Qwen3.5-4B-4bit", gguf: "unsloth/Qwen3.5-4B-GGUF" },
    { title: "Qwen3.5 9B", released: "2026-03-02", mlx: "mlx-community/Qwen3.5-9B-4bit", gguf: "unsloth/Qwen3.5-9B-GGUF" },
    { title: "Gemma 4 E2B", released: "2026-04-02", mlx: "mlx-community/gemma-4-e2b-it-4bit", gguf: "unsloth/gemma-4-E2B-it-GGUF" },
    { title: "Gemma 4 E4B", released: "2026-04-02", mlx: "mlx-community/gemma-4-e4b-it-4bit", gguf: "unsloth/gemma-4-E4B-it-GGUF" }
  ];

  var savedAdjustmentPanel = localStorage.getItem("photoStyle.activeAdjustmentPanel") || "film";
  var savedAdjustmentMode = localStorage.getItem("photoStyle.adjustmentMode");
  var state = {
    page: "home",
    repositoryFormat: "mlx",
    repositoryQuery: "",
    sourceFileName: "",
    histogramVisible: false,
    whiteBalancePicking: false,
    repairEditing: false,
    isRepairingImage: false,
    sidebarCollapsed: localStorage.getItem("photoStyle.sidebarCollapsed") === "true",
    showHelp: localStorage.getItem("photoStyle.showHelp") !== "false",
    appearance: localStorage.getItem("photoStyle.appearance") || "comfortable",
    language: L.preference(),
    thumbnailSize: normalizedThumbnailSize(localStorage.getItem("photoStyle.thumbnailSize")),
    hdrFeatureEnabled: true,
    originalResolutionEditing: false,
    mcp: { enabled: true, running: false, status: "啟動中", endpoint: "http://127.0.0.1:8765/mcp", connectionFile: "" },
    selectedCustomFilmID: null,
    selectedStyle: localStorage.getItem("photoStyle.selectedStyle") || "japaneseColor1",
    styles: [],
    adjustments: {},
    cropAspectRatios: [
      { id: "original", title: "關閉" },
      { id: "source", title: "原始比例" },
      { id: "free", title: "自由裁切" },
      { id: "threeTwo", title: "3:2" },
      { id: "oneOne", title: "1:1" },
      { id: "fourThree", title: "4:3" },
      { id: "sixteenNine", title: "16:9" }
    ],
    frameStyles: [],
    dateStyles: [],
    filmIlluminants: [],
    sourceImage: null,
    cropSourceImage: null,
    outputImage: null,
    loadingPreviewImage: null,
    sourceImageSize: null,
    hasImage: false,
    canSave: false,
    isLoadingImage: false,
    isRenderingPreview: false,
    isComputing: false,
    computationStep: "",
    computationItems: [],
    computationCompletedItems: 0,
    isSavingImage: false,
    savingStep: "",
    cropEditing: false,
    promptDialog: {
      open: false,
      styleID: null
    },
    activeAdjustmentPanel: savedAdjustmentPanel,
    adjustmentMode: savedAdjustmentMode === "film" || savedAdjustmentMode === "digital"
      ? savedAdjustmentMode
      : (["global", "highlight", "midtone", "shadow"].indexOf(savedAdjustmentPanel) >= 0 ? "digital" : "film"),
    subjectMask: {
      available: false,
      detecting: false
    },
    ai: {
      ready: false,
      message: "",
      presets: [],
      modelChoices: [],
      selectedModelID: "",
      modelDirectoryPath: "",
      modelDirectoryScanning: false,
      modelDirectoryMessage: "",
      usingModelDirectory: false,
      download: { active: false, fraction: 0, percent: 0 }
    }
  };

  var app = document.getElementById("app");
  var busyDialog = document.getElementById("busyDialog");
  var repairBrush = new window.PhotoRepairBrush({
    root: app, state: function () { return state; }, text: function (s) { return L.text(s); }, escape: escapeHtml,
    busy: function () { return photoIsBusy(state); }, render: render, post: post,
    image: function () { return app.querySelector('.preview-image'); }, cancelGesture: cancelPreviewGesture,
    prepare: function () { flushPhotoEdits(); cancelPreviewGesture(); state.cropEditing = false; state.whiteBalancePicking = false; }
  });
  window.handleRepairResult = function (result) { repairBrush.result(result); };
  var filmHoverPreview = new window.PhotoFilmHoverPreview({
    root: app,
    context: function () { return { photoGeneration: state.photoGeneration, previewRevision: state.previewRevision, selectedLook: currentLookID() }; },
    available: function () {
      return state.page === 'home' && state.hasImage && !!state.outputImage && !photoIsBusy(state)
        && !state.isRenderingPreview && !(state.subjectMask && state.subjectMask.detecting)
        && !state.repairEditing && !state.cropEditing && !state.whiteBalancePicking && !state.promptDialog.open
        && !pendingStyleSelection && !pendingLiveAdjustment && !pendingCropValues && !isDraggingAdjustment
        && !(exportDevelopment && exportDevelopment.isVisible());
    },
    post: post,
    captureView: function () { return Object.assign({}, previewTransform); },
    restoreView: function (view) { previewTransform = Object.assign({}, view); },
    changed: function () {
      setPreviewImageSource(false);
      var status = app.querySelector('.preview-status');
      if (status) status.innerHTML = previewStatusText();
    }
  });
  window.handleFilmHoverPreview = function (payload) { filmHoverPreview.receive(payload); };
  var deferredExportToast = null;
  var exportDevelopment = new window.PhotoExportDevelopment(document.getElementById('exportDevelopment'), function () {
    updateBusyDialog();
    if (!exportDevelopment.isVisible() && deferredExportToast) {
      var message = deferredExportToast;
      deferredExportToast = null;
      window.handleNativeToast(message);
    }
  });
  window.handleExportDevelopment = function (payload) {
    if (payload.phase === 'begin') { deferredExportToast = null; exportDevelopment.start(payload.id, state.outputImage, payload.timing); }
    else if (payload.phase === 'progress') exportDevelopment.update(payload.id, payload.stage);
    else if (payload.phase === 'complete') exportDevelopment.finish(payload.id, payload.image, payload.durationMs);
    else if (payload.phase === 'cancel') exportDevelopment.cancel(payload.id);
  };
  var busyTitle = document.getElementById("busyTitle");
  var busyStep = document.getElementById("busyStep");
  var busyItems = document.getElementById("busyItems");
  var busyTime = document.getElementById("busyTime");
  var busySeconds = document.getElementById("busySeconds");
  var busyCancel = document.getElementById("busyCancel");
  var toast = document.getElementById("toast");
  var toastTimer = null;
  var computeStartedAt = null;
  var computeTimer = null;
  var previewFit = null;
  var previewResizeObserver = null;
  var observedPreviewFrame = null;
  var previewTransform = { scale: 1, x: 0, y: 0 };
  var previewPointers = new Map();
  var previewGesture = null;
  var lastPreviewTap = { time: 0, x: 0, y: 0 };
  var liveAdjustmentTimer = null;
  var pendingLiveAdjustment = null;
  var isDraggingAdjustment = false;
  var adjustmentInteraction = null;
  var adjustmentInteractionSequence = 0;
  var styleDrag = null;
  var cropGesture = null;
  var cropEditSnapshot = null;
  var cropUpdateTimer = null;
  var pendingCropValues = null;
  var pendingCropStyle = null;
  var pendingCropGeneration = 0;
  var photoEditGeneration = 0;
  var isDraggingCrop = false;
  var styleOrderKey = "photoStyle.styleOrder";
  var selectedStyleKey = "photoStyle.selectedStyle";
  var enabledStylesKey = "photoStyle.enabledFilms.v2";
  var adjustmentPanelsByMode = {
    film: [["film", "沖洗"], ["scanner", "掃描"], ["frameWatermark", "外框"]],
    digital: [["global", "整體"], ["highlight", "亮部"], ["midtone", "中調"], ["shadow", "暗部"], ["frameWatermark", "外框"]]
  };
  var filmDisclosureState = {};
  var previewHoldTimer = null;
  var tooltip = null;
  var tooltipAnchor = null;
  var tooltipDismissTimer = null;
  var helpSequence = 0;
  var isComposingRepositoryQuery = false;
  var isComposingFilmQuery = false;
  var pendingStyleSelection = null;
  var thumbnailObserver = null;
  var thumbnailRequestTimer = null;
  var lastThumbnailRequest = "";
  var thumbnailViewport = readThumbnailViewport();

  function readThumbnailViewport() {
    try { return JSON.parse(localStorage.getItem("photoStyle.thumbnailViewport.v1")) || {}; }
    catch (_) { return {}; }
  }

  function rememberThumbnailViewport() {
    var section = app.querySelector(".photo-directory");
    var list = section && section.querySelector(".photo-thumbnail-list");
    if (!list || !list.children.length) return;
    thumbnailViewport = { path: section.dataset.directoryPath, left: list.scrollLeft,
      selectedID: section.dataset.selectedPhoto || "" };
    localStorage.setItem("photoStyle.thumbnailViewport.v1", JSON.stringify(thumbnailViewport));
  }

  function disconnectThumbnailObserver() {
    if (thumbnailObserver) thumbnailObserver.disconnect();
    thumbnailObserver = null;
    if (thumbnailRequestTimer) clearTimeout(thumbnailRequestTimer);
    thumbnailRequestTimer = null;
  }

  function requestVisibleThumbnails() {
    thumbnailRequestTimer = null;
    var list = app.querySelector(".photo-thumbnail-list");
    var ids = [];
    if (list && state.page === "home") {
      var viewport = list.getBoundingClientRect();
      list.querySelectorAll("[data-directory-photo]").forEach(function (node) {
        var rect = node.getBoundingClientRect();
        if (rect.right > viewport.left + 1 && rect.left < viewport.right - 1 && viewport.width > 0) {
          ids.push(node.dataset.directoryPhoto);
        }
      });
    }
    var key = JSON.stringify([(state.photoDirectory || {}).path, ids]);
    if (key !== lastThumbnailRequest) {
      lastThumbnailRequest = key;
      post("requestPhotoThumbnails", { ids: ids });
    }
    updateThumbnailArrows();
  }

  function scheduleThumbnailRequest() {
    if (!thumbnailRequestTimer) thumbnailRequestTimer = setTimeout(requestVisibleThumbnails, 16);
  }

  function updateThumbnailArrows() {
    var list = app.querySelector(".photo-thumbnail-list");
    if (!list) return;
    var previous = app.querySelector('[data-thumbnail-scroll="-1"]');
    var next = app.querySelector('[data-thumbnail-scroll="1"]');
    if (previous) previous.disabled = list.scrollLeft <= 1;
    if (next) next.disabled = list.scrollLeft >= list.scrollWidth - list.clientWidth - 1;
  }

  function observePhotoThumbnails() {
    disconnectThumbnailObserver();
    lastThumbnailRequest = "";
    var section = app.querySelector(".photo-directory");
    var list = section && section.querySelector(".photo-thumbnail-list");
    if (!list) { scheduleThumbnailRequest(); return; }
    var selected = list.querySelector(".selected");
    var selectedID = selected ? selected.dataset.directoryPhoto : "";
    if (thumbnailViewport.path === section.dataset.directoryPath &&
        (!selectedID || selectedID === thumbnailViewport.selectedID)) {
      list.scrollLeft = Math.max(0, Number(thumbnailViewport.left) || 0);
    } else if (selected) {
      list.scrollLeft = Math.max(0, selected.offsetLeft - list.offsetLeft - (list.clientWidth - selected.offsetWidth) / 2);
    }
    if ("IntersectionObserver" in window) {
      thumbnailObserver = new IntersectionObserver(scheduleThumbnailRequest, { root: list, threshold: 0.01 });
      list.querySelectorAll("[data-directory-photo]").forEach(function (node) { thumbnailObserver.observe(node); });
    }
    scheduleThumbnailRequest();
  }


  function post(action, payload) {
    var body = Object.assign({ action: action }, payload || {});
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
      window.webkit.messageHandlers.nativeBridge.postMessage(body);
    }
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(Number(value) || 0, min), max);
  }

  function normalizedThumbnailSize(value) {
    return ["small", "medium", "large"].indexOf(value) >= 0 ? value : "medium";
  }

  var i18n = {
    traditionalChinese: {
      appName: "照片沖洗",
      brandTagline: "專屬 AI 底片暗房",
      edit: "編輯",
      promptDialogTitle: "編輯 Prompt",
      promptDialogHint: "自訂目標會優先於預設風格參數。可指定區域與數值，例如「三區顆粒皆為 0、中間調曝光 -20、強度 35」。儲存後按 AI 分析套用。",
      promptCustomized: "已自訂",
      grainBaselineHint: "底片顆粒量是各區的基準，與亮部、中調、暗部的顆粒量取較強效果；四者皆設為 0 即可完全關閉。",
      monochromeZoneHint: "黑白風格不使用區域色彩調整。",
      restore: "還原",
      cancel: "取消",
      save: "儲存"
    },
    english: {
      appName: "FilmYourPhoto",
      brandTagline: "PRIVATE AI FILM LAB",
      edit: "Edit",
      promptDialogTitle: "Edit Prompt",
      promptDialogHint: "Custom instructions override the default parameter guidance. Specify zones and values, e.g. “all zone grain 0, midtone exposure -20, strength 35”. Save, then run AI analysis.",
      promptCustomized: "Custom",
      grainBaselineHint: "Film grain amount sets the baseline for each zone. The stronger film or zone setting applies. Set it and highlight, midtone and shadow grain to 0 to disable all grain.",
      monochromeZoneHint: "Monochrome styles do not use zone color adjustments.",
      restore: "Restore",
      cancel: "Cancel",
      save: "Save"
    },
    japanese: {
      appName: "写真現像",
      brandTagline: "プライベート AI 暗室",
      edit: "編集",
      promptDialogTitle: "Prompt を編集",
      promptDialogHint: "カスタム指示は既定のパラメータより優先されます。例：「全領域の粒子0、中間調の露出-20、強度35」。保存後にAI解析を実行してください。",
      promptCustomized: "カスタム",
      grainBaselineHint: "フィルムの粒子量は各領域の基準値です。ハイライト・中間調・シャドウの粒子量と比較して強い方が適用されます。4つすべてを0にすると無効になります。",
      monochromeZoneHint: "白黒スタイルでは領域ごとの色調整を使用しません。",
      restore: "復元",
      cancel: "キャンセル",
      save: "保存"
    },
    korean: {
      appName: "사진 현상",
      brandTagline: "나만의 AI 필름 암실",
      edit: "편집",
      promptDialogTitle: "Prompt 편집",
      promptDialogHint: "사용자 지시가 기본 매개변수보다 우선합니다. 예: “모든 영역 입자 0, 중간톤 노출 -20, 강도 35”. 저장 후 AI 분석을 실행하세요.",
      promptCustomized: "사용자 지정",
      grainBaselineHint: "필름 입자량은 각 영역의 기준값입니다. 밝은 영역, 중간톤, 어두운 영역의 입자량과 비교해 더 강한 효과가 적용됩니다. 네 값을 모두 0으로 설정하면 꺼집니다.",
      monochromeZoneHint: "흑백 스타일은 영역별 색상 조정을 사용하지 않습니다.",
      restore: "복원",
      cancel: "취소",
      save: "저장"
    }
  };

  function languageKey() { return L.resolve(state.language); }

  function text(key) {
    var table = i18n[languageKey()] || i18n.traditionalChinese;
    return table[key] || i18n.traditionalChinese[key] || key;
  }

  function localizedStylePrompt(style) {
    var key = languageKey();
    if (style && style.prompts && style.prompts[key]) return style.prompts[key];
    if (style && style.prompt) return style.prompt;
    return localizedStyleDefaultPrompt(style);
  }

  function localizedStyleDefaultPrompt(style) {
    var key = languageKey();
    if (style && style.defaultPrompts && style.defaultPrompts[key]) return style.defaultPrompts[key];
    return (style && style.defaultPrompt) || "";
  }

  function isPromptCustomizedForLanguage(style) {
    var key = languageKey();
    if (style && Array.isArray(style.promptCustomizedLanguages)) {
      return style.promptCustomizedLanguages.indexOf(key) >= 0;
    }
    return Boolean(style && style.promptCustomized);
  }

  function signedLabel(value) {
    var rounded = Math.round(Number(value) || 0);
    return rounded > 0 ? "+" + rounded : String(rounded);
  }

  function vignetteBalance(adjustment) {
    return clamp((adjustment.vignette || 0) - (adjustment.devignette || 0), -100, 100);
  }

  function setAppearance(value) {
    state.appearance = value;
    localStorage.setItem("photoStyle.appearance", value);
    document.body.classList.toggle("dark", value === "dark");
    document.body.classList.toggle("bright", value === "bright");
  }

  function currentAdjustment() {
    return state.adjustments[state.selectedStyle] || {
      intensity: 50,
      exposure: 0,
      whiteBalanceWarmth: 0,
      whiteBalanceTint: 0,
      brightness: 50,
      contrast: 0,
      grain: 0,
      filmColorModel: "spectral",
      printExposure: 0,
      printContrast: 50,
      developmentAmount: 0,
      developmentTime: 50,
      developmentDiffusion: 0.15,
      developmentAgitation: 50,
      grainMode: "emulsion",
      grainSize: 1,
      grainClumping: 0,
      grainChroma: 0,
      bloomAmount: 0,
      bloomRadius: 0.4,
      bloomThreshold: 75,
      halationAmount: 0,
      halationRadius: 0.1,
      halationThreshold: 75,
      monochromeFilter: "none",
      monochromeFilterStrength: 0,
      vignette: 0,
      denoise: 0,
      devignette: 0,
      backgroundBlur: 0,
      skinWarmth: 0,
      skinWhitening: 0,
      skinSmoothing: 0,
      hdrAmount: 25,
      cropAspectRatio: "original",
      cropRotation: 0,
      cropScale: 100,
      cropWidth: 100,
      cropHeight: 100,
      cropHorizontalPosition: 0,
      cropVerticalPosition: 0,
      highlightExposure: 0,
      highlightIntensity: 0,
      highlightWarmth: 0,
      highlightGrain: 0,
      midtoneExposure: 0,
      midtoneIntensity: 0,
      midtoneWarmth: 0,
      midtoneGrain: 0,
      shadowExposure: 0,
      shadowIntensity: 0,
      shadowWarmth: 0,
      shadowGrain: 0,
      sourceToneZones: null,
      frameEnabled: false,
      frameStyle: "whitePaperThin",
      dateEnabled: false,
      dateStyle: "numeric"
    };
  }

  // 收藏偏好合併至代表款式；照片與自訂底片的配方 ID 維持原樣。
  function catalogStyleID(id) {
    var style = (state.styles || []).find(function (item) { return item.id === id; });
    return style && style.mergedInto ? style.mergedInto : id;
  }

  function catalogStyleIDs(ids) {
    return ids.map(catalogStyleID).filter(function (id, index, all) {
      return typeof id === "string" && all.indexOf(id) === index;
    });
  }

  function catalogStyles() {
    return (state.styles || []).filter(function (style) { return !style.mergedInto; });
  }

  function readStyleOrder() {
    try {
      var stored = JSON.parse(localStorage.getItem(styleOrderKey) || "[]");
      return Array.isArray(stored) ? catalogStyleIDs(stored) : [];
    } catch (_) {
      return [];
    }
  }

  function applyStyleOrder(styles, order) {
    var map = {};
    styles.forEach(function (style) { map[style.id] = style; });
    var used = {};
    var ordered = order
      .filter(function (id) { return map[id]; })
      .map(function (id) {
        used[id] = true;
        return map[id];
      });
    styles.forEach(function (style) {
      if (!used[style.id]) ordered.push(style);
    });
    return ordered;
  }

  function persistStyleOrder(ids) {
    ids = catalogStyleIDs(ids);
    localStorage.setItem(styleOrderKey, JSON.stringify(ids));
    state.styles = applyStyleOrder(state.styles, ids);
  }

  function readEnabledStyleIDs() {
    var ordered = applyStyleOrder(catalogStyles(), readStyleOrder()).filter(function (style) { return style.isOriginal || style.isFilmStock || style.isCustom; });
    var allIDs = ordered.map(function (style) { return style.id; });
    if (allIDs.length === 0) return [];
    var defaults = allIDs;

    try {
      var raw = localStorage.getItem(enabledStylesKey);
      if (raw == null) return defaults;
      var stored = JSON.parse(raw);
      var enabled = Array.isArray(stored)
        ? catalogStyleIDs(stored).filter(function (id) { return allIDs.indexOf(id) >= 0; })
        : [];
      return enabled.length > 0 ? enabled : [allIDs[0]];
    } catch (_) {
      return defaults;
    }
  }

  function persistEnabledStyleIDs(ids) {
    var allIDs = applyStyleOrder(catalogStyles(), readStyleOrder()).map(function (style) { return style.id; });
    ids = catalogStyleIDs(ids);
    var filtered = ids.filter(function (id, index) {
      return allIDs.indexOf(id) >= 0 && ids.indexOf(id) === index;
    });
    if (filtered.length === 0 && allIDs.length > 0) filtered = [allIDs[0]];
    localStorage.setItem(enabledStylesKey, JSON.stringify(filtered));
    return filtered;
  }

  function enabledStyles() {
    var enabled = readEnabledStyleIDs();
    return applyStyleOrder(catalogStyles(), readStyleOrder()).filter(function (style) {
      return (style.isOriginal || style.isFilmStock || style.isCustom) && enabled.indexOf(style.id) >= 0;
    }).sort(function (a, b) {
      function group(style) { return style.id === "original" ? 0 : style.isCustom ? 1 : 2; }
      return group(a) - group(b);
    });
  }

  function persistSelectedStyle(styleID) {
    if (!styleID) return;
    localStorage.setItem(selectedStyleKey, styleID);
  }

  function currentLookID() { return state.selectedCustomFilmID || state.selectedStyle; }

  function setCurrentStyle(styleID, notifyNative) {
    filmHoverPreview.cancel();
    if (!styleID) return;
    var style = state.styles.find(function (item) { return item.id === styleID; });
    if (!style) return;
    var enabled = readEnabledStyleIDs();
    if (enabled.indexOf(styleID) < 0) persistEnabledStyleIDs(enabled.concat([styleID]));
    if (currentLookID() === styleID && !notifyNative) return;
    if (notifyNative) pendingStyleSelection = styleID;
    flushPhotoEdits(notifyNative ? "setStyle" : null, { style: styleID });
    discardPendingPhotoEdits();
    state.selectedStyle = style.baseStyle || styleID;
    state.selectedCustomFilmID = style.isCustom ? styleID : null;
    persistSelectedStyle(state.selectedStyle);
  }

  function ensureCurrentStyleEnabled(notifyNative) {
    var enabled = readEnabledStyleIDs();
    if (enabled.length === 0) return;
    if (enabled.indexOf(catalogStyleID(currentLookID())) < 0) {
      setCurrentStyle(enabled[0], notifyNative);
    }
  }

  function toggleStyleEnabled(styleID) {
    var enabled = readEnabledStyleIDs();
    var index = enabled.indexOf(styleID);
    if (index >= 0) {
      if (enabled.length <= 1) return;
      enabled.splice(index, 1);
    } else {
      enabled.push(styleID);
    }

    enabled = persistEnabledStyleIDs(enabled);
    if (enabled.indexOf(catalogStyleID(currentLookID())) < 0) {
      setCurrentStyle(enabled[0], true);
    }
  }

  function render() {
    L.setLanguage(state.language);
    document.title = text("appName");
    filmHoverPreview.sync();
    if (state.page === "styles") state.page = "films";
    // Replacing the input during marked-text composition discards the user's IME draft.
    // Native state is still received; compositionend renders the latest state.
    if (isComposingRepositoryQuery || isComposingFilmQuery) return;
    if (previewResizeObserver) previewResizeObserver.disconnect();
    observedPreviewFrame = null;
    hideTooltip();
    helpSequence = 0;
    rememberThumbnailViewport();
    disconnectThumbnailObserver();
    setAppearance(state.appearance);
    var scrollPositions = {};
    app.querySelectorAll("[data-scroll-region]").forEach(function (node) {
      scrollPositions[node.dataset.scrollRegion] = { top: node.scrollTop, left: node.scrollLeft };
    });
    app.querySelectorAll("[data-film-disclosure]").forEach(function (details) {
      filmDisclosureState[details.dataset.filmDisclosure] = details.open;
    });
    var focused = document.activeElement;
    var focusID = focused && focused.id;
    var promptEditor = app.querySelector("#promptEditorText");
    var draft = promptEditor && state.promptDialog.open && promptEditor.dataset.promptStyle === state.promptDialog.styleID
      ? promptEditor.value : null;
    var selection = focused && (focused.id === "modelRepositoryQuery" || focused.id === "filmSearch")
      ? [focused.selectionStart, focused.selectionEnd]
      : (draft !== null && focused === promptEditor ? [promptEditor.selectionStart, promptEditor.selectionEnd] : null);
    var previousPreview = app.querySelector(".preview-image:not(.crop-source-image)");
    var preservePreview = previousPreview && !state.isLoadingImage && !isCropEditorVisible(currentAdjustment())
      && previousPreview._photoGeneration === state.photoGeneration;
    cancelPreviewGesture();
    app.innerHTML = [
      renderTabs(),
      state.page === "home" ? renderHome() : "",
      state.page !== "home" ? '<div class="desktop-page" data-scroll-region="page">' : "",
      state.page === "films" ? renderFilmPage() : "",
      state.page === "ai" ? renderAI() : "",
      state.page === "settings" ? renderSettings() : "",
      state.page !== "home" ? "</div>" : "",
      state.promptDialog && state.promptDialog.open ? renderPromptDialog() : ""
    ].join("");
    var nextPreview = app.querySelector(".preview-image:not(.crop-source-image)");
    if (nextPreview) {
      var requestedSource = nextPreview.getAttribute("src");
      if (preservePreview) {
        nextPreview.replaceWith(previousPreview);
        updatePreviewImage(previousPreview, requestedSource);
      } else {
        nextPreview._photoGeneration = state.photoGeneration;
        nextPreview._requestedPreviewSource = requestedSource;
      }
    }
    prepareNativeTooltips();
    bindEvents();
    filmHoverPreview.sync();
    app.querySelectorAll("[data-scroll-region]").forEach(function (node) {
      if (node.dataset.scrollRegion === "photo-thumbnails") return;
      var position = scrollPositions[node.dataset.scrollRegion] || {};
      node.scrollTop = position.top || 0;
      node.scrollLeft = position.left || 0;
    });
    var replacementEditor = app.querySelector("#promptEditorText");
    if (draft !== null && replacementEditor) replacementEditor.value = draft;
    if (focusID) {
      var replacement = document.getElementById(focusID);
      if (replacement) {
        replacement.focus({ preventScroll: true });
        if (selection && (replacement === replacementEditor || replacement.id === "modelRepositoryQuery" || replacement.id === "filmSearch")) {
          replacement.setSelectionRange(selection[0], selection[1]);
        }
      }
    }
    hideTooltip();
    fitPreviewImage();
    updateBusyDialog();
  }

  function styleTitle(style) { return style.isCustom ? style.title : L.text(style.title); }

  function renderTabs() {
    var tabs = [
      ["home", L.text("工作台"), "home"],
      ["films", L.text("底片庫"), "film"],
      ["ai", L.text("AI 核心"), "cpu"],
      ["settings", L.text("設定"), "settings"]
    ];
    return [
      '<header class="app-header' + (state.page === 'home' && state.repairEditing ? ' repair-header' : '') + '">',
      '<div class="app-brand" aria-label="' + escapeHtml(text("appName")) + '">',
      '<img class="brand-mark" src="app-icon.png" alt="" width="32" height="32">',
      '<span class="brand-copy"><strong>' + escapeHtml(text("appName")) + '</strong><small>' + escapeHtml(text("brandTagline")) + '</small></span>',
      "</div>",
      state.page === 'home' ? repairBrush.panel() : '',
      L.html('<nav class="tabs" aria-label="主要功能">'),
      tabs.map(function (tab) {
        var active = state.page === tab[0];
        return [
          '<button class="tab ' + (active ? "active" : "") + '" data-page="' + tab[0] + '" type="button"' + (active ? ' aria-current="page"' : "") + ">",
          iconSvg(tab[2]),
          '<span>' + tab[1] + "</span>",
          "</button>"
        ].join("");
      }).join(""),
      "</nav>",
      "</header>"
    ].join("");
  }

  function renderStyleSidebar() {
    return [
      L.html('<aside class="style-sidebar" aria-label="底片收藏">'),
      '<div class="sidebar-heading"><span class="eyebrow">' + escapeHtml(L.text('底片收藏')) + '</span><button class="sidebar-collapse-toggle" type="button" aria-controls="filmSidebarList" aria-expanded="' + !state.sidebarCollapsed + '" aria-label="' + (state.sidebarCollapsed ? L.text('展開底片收藏') : L.text('收合底片收藏')) + '">' + iconSvg('chevronLeft') + '</button></div>',
      '<div id="filmSidebarList" class="sidebar-style-list" data-scroll-region="styles">',
      enabledStyles().map(function (style, index, styles) {
        var active = style.id === currentLookID();
        var colors = style.palette || ["#aaa", "#ddd", "#fff"];
        var kind = style.isFilmStock ? "film" : "style";
        var label = (style.isOriginal ? "" : L.text("底片：")) + styleTitle(style);
        var group = style.isCustom ? 'custom' : style.id === 'original' ? 'original' : 'builtin';
        var previous = index ? (styles[index - 1].isCustom ? 'custom' : styles[index - 1].id === 'original' ? 'original' : 'builtin') : group;
        var divider = index && group !== previous ? '<div class="sidebar-film-divider" role="separator" aria-label="' + (group === 'custom' ? L.text('自訂底片') : L.text('內建底片')) + '"><span>' + (group === 'custom' ? L.text('自訂底片') : L.text('內建底片')) + '</span></div>' : '';
        return divider + '<button class="sidebar-style ' + (active ? "active" : "") + '" data-select-style="' + escapeHtml(style.id) + '" title="' + escapeHtml(styleTitle(style)) + '" data-style-kind="' + kind + '" data-tooltip="' + escapeHtml(styleTitle(style) + "：" + L.text(style.subtitle)) + '" type="button" aria-label="' + escapeHtml(label) + '" aria-pressed="' + active + '">' +
          '<span class="sidebar-swatch" style="background:linear-gradient(140deg,' + colors.map(escapeHtml).join(",") + ')">' + iconSvg(style.isOriginal ? "photos" : style.isFilmStock ? "film" : "styles") + '</span>' +
          '<span><strong>' + escapeHtml(styleTitle(style)) + '</strong></span></button>';
      }).join(""),
      '</div>',
      '</aside>'
    ].join("");
  }

  function renderHome() {
    var adjustment = currentAdjustment();
    var cropEditorVisible = !state.repairEditing && !state.isLoadingImage && !!state.outputImage && isCropEditorVisible(adjustment);
    var previewSource = state.repairEditing ? (state.repairSourceImage || state.cropSourceImage) : (state.isLoadingImage ? state.loadingPreviewImage : (filmHoverPreview.imageSource() || state.outputImage || state.loadingPreviewImage));
    var busy = state.isLoadingImage || state.isComputing || state.isSavingImage;
    return [
      '<div class="home-workspace' + (state.repairEditing ? ' repair-active' : '') + (state.sidebarCollapsed ? ' sidebar-collapsed' : '') + '">',
      renderStyleSidebar(),
      '<div class="preview-pane">',
      '<div class="preview-head"><div class="preview-file"><p class="eyebrow">' + escapeHtml(L.text('照片工作台')) + '</p><h1 class="section-title" title="' + escapeHtml(state.sourceFileName) + '">' + escapeHtml(state.sourceFileName || L.text("照片預覽")) + '</h1></div>',
      '<div class="preview-head-actions">',
      L.html('<button class="photo-directory-button" data-action="browsePhotoDirectory" type="button" title="選取照片目錄（⇧⌘O）"') + (photoIsBusy(state) ? ' disabled' : '') + '>' + iconSvg("folderOpen") + L.html('<span>選取目錄</span></button>'),
      L.html('<div class="edit-history-actions" role="group" aria-label="編輯歷程">') + ['undoEdit', 'redoEdit'].map(function (action, index) {
        var available = index ? state.canRedo : state.canUndo;
        var label = index ? L.text('下一步') : L.text('上一步');
        return '<button class="photo-directory-button edit-history-button" data-action="' + action + '" type="button" aria-label="' + label + '" title="' + label + '"' + (!available || photoIsBusy(state) ? ' disabled' : '') + '>' + iconSvg(index ? 'redo' : 'undo') + '</button>';
      }).join('') + '</div>',
      repairBrush.toolbar() + renderCropQuickControl(adjustment) + L.html('<button type="button" class="photo-directory-button white-balance-picker" data-white-balance-picker aria-label="白平衡滴管" title="白平衡滴管：點選照片中的灰色或白色區域" aria-pressed="') + state.whiteBalancePicking + '"' + (!state.hasImage || photoIsBusy(state) || state.isRenderingPreview || state.cropEditing || state.repairEditing ? ' disabled' : '') + '>' + iconSvg('eyedropper') + '</button></div></div>',
      L.html('<div class="preview-frame" aria-label="照片預覽區">'),
      previewSource
        ? (cropEditorVisible ? renderCropEditor() : [
          state.outputImage && state.loadingPreviewImage && !state.isLoadingImage ? '<img class="preview-loading-image" src="' + state.loadingPreviewImage + '" alt="" aria-hidden="true" draggable="false">' : "",
          '<img class="preview-image" src="' + previewSource + L.html('" alt="照片預覽" draggable="false">'),
          !state.repairEditing && state.sourceImage && !state.isLoadingImage && state.outputImage ? previewCompareButton() : ""
        ].join(""))
        : (!state.hasImage && !state.isLoadingImage && !state.isRenderingPreview ? '<div class="empty-preview">' + iconSvg("photos") + '<strong>' + renderHelp(L.text("選取目錄後，從下方縮圖開啟照片；也可以直接拖入照片。支援 JPEG、PNG、HEIC 與 RAW。"), L.text("給照片一點底片的溫度")) + '</strong>' +
          '<button class="empty-open" data-action="browsePhotoDirectory" type="button" ' + (busy ? "disabled" : "") + L.html('>選取目錄 <kbd>⇧⌘O</kbd></button></div>') : ""),
      repairBrush.overlay(),
      L.html('<aside class="preview-histogram" aria-label="RGB 三原色直方圖"') + (state.histogramVisible && !cropEditorVisible ? '' : ' hidden') + L.html('><div class="histogram-heading"><button type="button" data-close-histogram aria-label="關閉直方圖">×</button></div><canvas width="256" height="100" role="img" aria-label="目前預覽的紅、綠、藍亮度分布"></canvas><div class="histogram-scale"><span>0</span><span>255</span></div></aside>'),
      L.html('<div class="preview-feedback" data-preview-feedback role="status" aria-live="polite" hidden><span class="preview-spinner" aria-hidden="true"></span><strong data-preview-feedback-title></strong><small data-preview-feedback-detail></small><button class="empty-open" data-action="retryPreview" type="button" hidden>重新載入預覽</button></div>'),
      '</div>',
      '<footer class="canvas-footer"><span class="preview-status">' + previewStatusText() + '</span>',
      state.hasImage ? '<span class="canvas-hint">' + renderHelp(L.text("滾輪可放大縮小，放大後按住滑鼠左鍵拖曳移動；按「符合視窗」還原。按住空白鍵或右下角的比較按鈕可看原圖。"), L.text("原圖比較")) + L.html('</span><div class="canvas-actions"><button class="canvas-export" data-action="saveImage" type="button" title="匯出照片（⌘S）"') + (!state.canSave || photoIsBusy(state) ? ' disabled' : '') + '>' + iconSvg("exportImage") + L.html('匯出</button><div class="zoom-controls"><button data-zoom="zoomOut" aria-label="縮小" title="縮小（⌘−）">−</button><button data-zoom="zoomFit" title="符合視窗（⌘0）">符合視窗</button><button data-zoom="zoomIn" aria-label="放大" title="放大（⌘+）">＋</button></div></div>') : '<span class="canvas-hint">' + renderHelp(L.text("影像處理皆在這部 Mac 上完成。"), L.text("本機處理")) + '</span>',
      '</footer>', renderPhotoDirectory(), '</div>',
      L.html('<aside class="adjustment-pane" aria-label="影像調整" data-scroll-region="adjustments"') + (state.repairEditing ? ' inert' : '') + '>',
      L.html('<div class="inspector-heading"><span class="eyebrow">沖洗</span><div class="inspector-heading-row"><h2>影像調整</h2>'),
      L.html('<div class="inspector-actions"><button class="preview-ai-button adjustment-reset-button" data-action="resetAdjustments" type="button" title="將目前風格的影像、裁切、外框與日期調整恢復預設。"') + (!state.hasImage || photoIsBusy(state) ? ' disabled' : '') + L.html('>恢復預設值</button>'),
      L.html('<button id="previewRecompute" class="preview-ai-button" data-action="applyStyle" type="button" title="AI 輔助計算（⌘Return）" aria-keyshortcuts="Meta+Enter" ') +
        (state.selectedStyle === "original" || !state.hasImage || !state.ai.ready || state.ai.busy || photoIsBusy(state) ? "disabled" : "") + '>' + iconSvg("sparkles") + L.html('<span>AI 輔助計算</span></button></div></div></div>'),
      renderAdjustmentPanel(),
      '</aside></div>'
    ].join("");
  }

  function renderPhotoThumbnail(item) {
    if (item.thumbnail) return '<img src="' + escapeHtml(item.thumbnail) + '" alt="" draggable="false">';
    var label = item.isLoading ? L.text('正在載入縮圖') : (item.failed ? L.text('無法產生縮圖') : L.text('捲動至此處載入縮圖'));
    return '<span class="photo-thumbnail-placeholder" role="img" aria-label="' + label + '">' +
      (item.isLoading ? '<span class="photo-directory-spinner" aria-hidden="true"></span>' : iconSvg('photos')) + '</span>';
  }

  function renderPhotoDirectory() {
    var directory = state.photoDirectory || {};
    if (!directory.path && !directory.isScanning && !L.text(directory.message)) return "";
    var items = directory.items || [];
    var selectedIndex = items.findIndex(function (item) { return item.selected; });
    var selected = selectedIndex >= 0 ? items[selectedIndex] : null;
    var countLabel = selectedIndex >= 0
      ? L.text('第 ' + (selectedIndex + 1) + ' 張／共 ' + (directory.totalCount || 0) + ' 張')
      : L.text('共 ' + (directory.totalCount || 0) + ' 張');
    var busy = photoIsBusy(state);
    var loading = !!(directory.isScanning || directory.isLoadingThumbnails);
    var spinner = '<span class="photo-directory-spinner" aria-hidden="true"></span>';
    return '<section class="photo-directory" data-directory-path="' + escapeHtml(directory.path || '') + '" data-selected-photo="' + escapeHtml(selected ? selected.id : '') + '" data-thumbnail-size="' + normalizedThumbnailSize(state.thumbnailSize) + L.html('" aria-label="目錄照片縮圖">') +
      '<div class="photo-directory-heading"><div class="photo-directory-summary"><strong tabindex="0" data-tooltip="' + escapeHtml(directory.path || '') + '">' + escapeHtml(directory.name || L.text('照片目錄')) + '</strong><span class="photo-directory-status" role="status">' + (loading ? spinner : '') +
      (directory.isScanning ? L.text('正在掃描目錄…') : (escapeHtml(countLabel) + (directory.isLoadingThumbnails ? L.text(' · 正在載入縮圖…') : ''))) + '</span></div>' +
      L.html('<div class="photo-directory-controls"><label class="photo-thumbnail-size" for="photoThumbnailSize"><span>縮圖</span><select id="photoThumbnailSize" aria-label="縮圖大小">') +
      option('small', L.text('小'), state.thumbnailSize) + option('medium', L.text('中'), state.thumbnailSize) + option('large', L.text('大'), state.thumbnailSize) + '</select></label></div></div>' +
      (items.length ? L.html('<div class="photo-thumbnail-browser"><button class="photo-thumbnail-arrow" type="button" data-thumbnail-scroll="-1" aria-label="向左移動一張縮圖">‹</button>') +
        '<div class="photo-thumbnail-list" data-scroll-region="photo-thumbnails" aria-busy="' + loading + '">' + items.map(function (item, index) {
        return '<button class="photo-thumbnail' + (item.edited ? ' edited' : '') + (item.selected ? ' selected' : '') + '" id="photo-choice-' + escapeHtml(item.id) + '" data-directory-photo="' + escapeHtml(item.id) + '" type="button" aria-pressed="' + !!item.selected + '" data-tooltip="' + escapeHtml(item.name) + '"' + (busy || directory.isScanning ? ' disabled' : '') + '>' +
          renderPhotoThumbnail(item) + '<span class="photo-thumbnail-caption"><span class="photo-thumbnail-name">' + escapeHtml(item.name) + '</span><span class="photo-thumbnail-index">#' + String(index + 1).padStart(4, '0') + '</span></span></button>';
      }).join('') + L.html('</div><button class="photo-thumbnail-arrow" type="button" data-thumbnail-scroll="1" aria-label="向右移動一張縮圖">›</button></div>') : '<p class="photo-directory-empty">' + escapeHtml(L.text(directory.message) || (directory.isScanning ? L.text('正在尋找照片…') : L.text('這個目錄沒有可開啟的照片。'))) + '</p>') + '</section>';
  }

  // Thumbnail progress must not recreate the main photo, editors or scroll strip.
  window.handlePhotoDirectoryState = function (directory) {
    state.photoDirectory = directory || {};
    if (state.page !== "home") return;
    var oldSection = app.querySelector(".photo-directory");
    var container = document.createElement("div");
    container.innerHTML = renderPhotoDirectory();
    var newSection = container.firstElementChild;
    if (!newSection) {
      if (oldSection) {
        if (tooltipAnchor && oldSection.contains(tooltipAnchor)) hideTooltip();
        oldSection.remove();
      }
      return;
    }
    var oldButtons = oldSection ? oldSection.querySelectorAll("[data-directory-photo]") : [];
    var newButtons = newSection.querySelectorAll("[data-directory-photo]");
    var sameItems = oldSection && oldSection.dataset.directoryPath === newSection.dataset.directoryPath &&
      oldButtons.length === newButtons.length && Array.from(oldButtons).every(function (node, index) {
        return node.dataset.directoryPhoto === newButtons[index].dataset.directoryPhoto;
      });
    if (sameItems) {
      oldSection.dataset.selectedPhoto = newSection.dataset.selectedPhoto;
      var oldStatus = oldSection.querySelector(".photo-directory-status");
      var newStatus = newSection.querySelector(".photo-directory-status");
      if (oldStatus.innerHTML !== newStatus.innerHTML) oldStatus.innerHTML = newStatus.innerHTML;
      var list = oldSection.querySelector(".photo-thumbnail-list");
      if (list) list.setAttribute("aria-busy", String(!!directory.isLoadingThumbnails));
      oldButtons.forEach(function (node, index) {
        var replacement = newButtons[index];
        node.className = replacement.className;
        node.disabled = replacement.disabled;
        node.setAttribute("aria-pressed", replacement.getAttribute("aria-pressed"));
        if (node.firstElementChild.outerHTML !== replacement.firstElementChild.outerHTML) {
          node.firstElementChild.replaceWith(replacement.firstElementChild);
        }
      });
      var empty = oldSection.querySelector(".photo-directory-empty");
      if (empty) empty.textContent = newSection.querySelector(".photo-directory-empty").textContent;
    } else {
      if (tooltipAnchor && oldSection && oldSection.contains(tooltipAnchor)) hideTooltip();
      rememberThumbnailViewport();
      disconnectThumbnailObserver();
      if (oldSection) oldSection.replaceWith(newSection);
      else { var footer = app.querySelector(".canvas-footer"); if (footer) footer.after(newSection); }
      bindPhotoDirectoryEvents();
      fitPreviewImage();
    }
    updateThumbnailArrows();
  };

  function previewStatusText() {
    var reviewedLook = filmHoverPreview.look();
    if (reviewedLook) {
      var reviewedFilm = state.styles.find(function (film) { return film.id === reviewedLook; });
      return L.html('<span class="status-dot"></span>預覽：') + escapeHtml(reviewedFilm ? styleTitle(reviewedFilm) : L.text('底片'));
    }
    if (state.isLoadingImage) return L.text("正在讀取");
    if (state.isComputing) return L.text("AI 分析中");
    if (state.isSavingImage) return L.text("正在輸出");
    if (state.cropEditing && (currentAdjustment().cropAspectRatio || "original") !== "original") return L.text("裁切調整中");
    if (state.isRenderingPreview) return L.text("正在更新預覽");
    return state.hasImage ? L.text("即時預覽") : L.text("等待照片");
  }

  function renderCropQuickControl(adjustment) {
    var value = state.cropEditing ? (adjustment.cropAspectRatio || "original") : "original";
    var editing = state.cropEditing && value !== "original";
    return [
      '<div class="crop-quick-group">',
      L.html('<label class="crop-quick-control" for="previewCropAspectRatio"><span>裁切</span>'),
      '<select id="previewCropAspectRatio" data-select="cropAspectRatio" ' + (!state.hasImage || state.repairEditing ? "disabled" : "") + '>',
      (state.cropAspectRatios || []).map(function (option) {
        return '<option value="' + option.id + '" ' + (option.id === value ? "selected" : "") + '>' + escapeHtml(L.text(option.title)) + "</option>";
      }).join(""),
      "</select></label>",
      editing ? L.html('<button class="crop-edit-toggle" data-crop-cancel type="button">取消</button>') : "",
      (adjustment.cropAspectRatio || "original") !== "original"
        ? '<button class="crop-edit-toggle" data-' + (editing ? "crop-done" : "crop-edit") + ' type="button">' + (editing ? L.text("完成") : L.text("調整")) + "</button>"
        : "",
      "</div>"
    ].join("");
  }

  function isCropEditorVisible(adjustment) {
    return Boolean(
      state.cropEditing
      && state.cropSourceImage
      && (adjustment.cropAspectRatio || "original") !== "original"
    );
  }

  function renderCropEditor() {
    return [
      '<img class="preview-image crop-source-image" src="' + state.cropSourceImage + L.html('" alt="裁切來源照片" draggable="false">'),
      '<div class="crop-frame-box" data-crop-box>',
      '<div class="crop-image-clip"><img class="crop-window-image" src="' + state.cropSourceImage + '" draggable="false" alt=""></div>',
      '<div class="crop-rule-grid" aria-hidden="true"><i></i><i></i><i></i><i></i></div>',
      L.html('<div class="crop-move-surface" data-crop-move role="button" aria-label="拖曳移動裁切範圍"></div>'),
      ["nw", "ne", "sw", "se"].map(function (corner) {
        return '<button class="crop-rotate-zone crop-rotate-' + corner + '" data-crop-rotate="' + corner + L.html('" type="button" aria-label="拖曳旋轉照片"></button>');
      }).join(""),
      ["nw", "ne", "sw", "se"].map(function (corner) {
        return '<button class="crop-handle crop-handle-' + corner + '" data-crop-handle="' + corner + L.html('" type="button" aria-label="調整裁切框"></button>');
      }).join(""),
      "</div>",
      '<div class="crop-editor-hint">' + renderHelp(L.text('框內拖曳移動，角點拉伸裁切；角點外側按住左鍵旋轉。Shift 可對齊 1°，點角度可重設旋轉。'), L.text('裁切操作')) + L.html('<button type="button" data-crop-rotation-reset aria-label="重設旋轉">') + (currentAdjustment().cropRotation || 0).toFixed(1) + '°</button></div>'
    ].join("");
  }

  function iconSvg(icon) {
    var paths = {
      photos: '<rect x="3" y="6" width="15" height="13" rx="2"/><path d="M7 6V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-1"/><path d="m6 16 3-3 2.2 2.2L14 12l3 4"/>',
      sparkles: '<path d="M12 3 9.7 8.7 4 11l5.7 2.3L12 19l2.3-5.7L20 11l-5.7-2.3L12 3Z"/><path d="M5 3v4"/><path d="M3 5h4"/><path d="M19 17v4"/><path d="M17 19h4"/>',
      save: '<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2Z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/>',
      eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
      undo: '<path d="M9 5L4 10l5 5M4 10h10a6 6 0 0 1 6 6v3"/>',
      redo: '<path d="M15 5l5 5-5 5m5-5H10a6 6 0 0 0-6 6v3"/>',
      folderOpen: '<path d="M6 14l1.5-4.5A2 2 0 0 1 9.4 8H21a1 1 0 0 1 1 1.3l-2.1 7.4A2 2 0 0 1 18 18H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4.9a2 2 0 0 1 1.4.6L12 5h5a2 2 0 0 1 2 2v1"/>',
      download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/>',
      exportImage: '<path d="M8 9H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-3"/><path d="M12 15V2m-4 4 4-4 4 4"/>',
      checkCircle: '<path d="M22 11.1V12a10 10 0 1 1-5.9-9.1"/><path d="m9 11 3 3L22 4"/>',
      eyedropper: '<path d="m15 4 5 5M13 6l5 5M14 7 4 17v3h3L17 10M15 6l3-3a2 2 0 0 1 3 3l-3 3"/>',
      saveFilm: '<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h12l4 4v12a2 2 0 0 1-2 2ZM7 3v6h10V3M7 21v-8h10v8"/>',
      trash: '<path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/>',
      externalLink: '<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
      x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
      chevronLeft: '<path d="m15 6-6 6 6 6"/>',
      chevronUp: '<path d="m18 15-6-6-6 6"/>',
      chevronDown: '<path d="m6 9 6 6 6-6"/>',
      home: '<path d="m3 11 9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M9 20v-6h6v6"/>',
      styles: '<circle cx="8" cy="8" r="4"/><circle cx="16" cy="8" r="4"/><circle cx="8" cy="16" r="4"/><circle cx="16" cy="16" r="4"/>',
      film: '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M7 3v18M17 3v18M3 8h4m-4 8h4m10-8h4m-4 8h4M7 12h10"/>',
      cpu: '<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 14h3M1 9h3M1 14h3"/><path d="M10 10h4v4h-4z"/>',
      settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21h-4v-.1A1.7 1.7 0 0 0 8.6 19a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3v-4h.1A1.7 1.7 0 0 0 5 8.6a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.1A1.7 1.7 0 0 0 15.4 5a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.1.4.3.7.6 1 .3.3.7.4 1.1.4h.1v4h-.1a1.7 1.7 0 0 0-1.7.6Z"/>'
    };
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (paths[icon] || "") + "</svg>";
  }

  function previewCompareButton() {
    return [
      L.html('<button class="preview-compare-button" data-preview-original type="button" aria-label="按住顯示原圖" title="按住顯示原圖">'),
      iconSvg("eye"),
      "</button>"
    ].join("");
  }

  function renderAdjustmentCard(cardID, title, controlsHTML, headerControlHTML) {
    return [
      '<section class="adjustment-active-panel" data-adjustment-panel-content="' + cardID + '" role="tabpanel">',
      title ? '<h2 class="section-title adjustment-card-title"><span>' + title + "</span>" + (headerControlHTML || "") + "</h2>" : "",
      '<div class="controls">' + controlsHTML + "</div>",
      "</section>"
    ].join("");
  }

  function renderAdjustmentPanel() {
    var adjustment = currentAdjustment();
    var sourceToneZones = adjustment.sourceToneZones || {};
    var panels = adjustmentPanelsByMode[state.adjustmentMode];
    var activePanel = panels.some(function (panel) { return panel[0] === state.activeAdjustmentPanel; })
      ? state.activeAdjustmentPanel
      : panels[0][0];
    var activeContent = "";
    if (activePanel === "highlight") {
      activeContent = renderToneAdjustmentCard(L.text("亮部調整"), "highlight", adjustment.highlightExposure, adjustment.highlightIntensity, adjustment.highlightWarmth, adjustment.highlightGrain, sourceToneZones.highlights);
    } else if (activePanel === "midtone") {
      activeContent = renderToneAdjustmentCard(L.text("中調調整"), "midtone", adjustment.midtoneExposure, adjustment.midtoneIntensity, adjustment.midtoneWarmth, adjustment.midtoneGrain, sourceToneZones.midtones);
    } else if (activePanel === "shadow") {
      activeContent = renderToneAdjustmentCard(L.text("暗部調整"), "shadow", adjustment.shadowExposure, adjustment.shadowIntensity, adjustment.shadowWarmth, adjustment.shadowGrain, sourceToneZones.shadows);
    } else if (activePanel === "film") {
      activeContent = renderFilmAdjustmentCard(adjustment);
    } else if (activePanel === "scanner") {
      activeContent = renderScannerAdjustmentCard(adjustment);
    } else if (activePanel === "frameWatermark") {
      activeContent = renderFrameWatermarkCard(adjustment);
    } else {
      activeContent = renderGlobalAdjustmentCard(adjustment);
    }
    return [
      renderStyleSelectionCard(),
      renderAdjustmentModeSwitch(),
      '<section class="section card adjustment-workspace">',
      renderAdjustmentTabs(activePanel),
      activeContent,
      "</section>"
    ].join("");
  }

  function selectAdjustmentPanel(panel) {
    if (panel !== "frameWatermark") {
      state.adjustmentMode = adjustmentPanelsByMode.film.some(function (item) { return item[0] === panel; }) ? "film" : "digital";
    }
    state.activeAdjustmentPanel = panel;
    localStorage.setItem("photoStyle.adjustmentMode", state.adjustmentMode);
    localStorage.setItem("photoStyle.activeAdjustmentPanel", panel);
  }

  function renderAdjustmentModeSwitch() {
    return L.html('<div class="adjustment-mode-switch" role="group" aria-label="調整模式">') + [["film", L.text("底片")], ["digital", L.text("數位")]].map(function (mode) {
      return '<button type="button" class="adjustment-mode" id="adjustment-mode-' + mode[0] + '" data-adjustment-mode="' + mode[0] + '" aria-pressed="' + (state.adjustmentMode === mode[0] ? "true" : "false") + '">' + mode[1] + '</button>';
    }).join("") + '</div>';
  }

  function renderAdjustmentTabs(activePanel) {
    var panels = adjustmentPanelsByMode[state.adjustmentMode];
    return L.html('<nav class="adjustment-tabs" role="tablist" aria-label="調整區域">') + panels.map(function (panel) {
      var active = activePanel === panel[0];
      return '<button class="adjustment-tab ' + (active ? "active" : "") + '" data-adjustment-panel="' + panel[0] + '" type="button" role="tab" aria-selected="' + (active ? "true" : "false") + '">' + escapeHtml(L.text(panel[1])) + "</button>";
    }).join("") + "</nav>";
  }

  function renderStyleSelectionCard() {
    var adjustment = currentAdjustment();
    return [
      '<section class="section card adjustment-section style-selection-card">',
      '<div class="style-selection-title">',
      '<span class="style-selection-left"><span class="eyebrow">' + escapeHtml(L.text('目前風格')) + '</span>' + renderAdjustmentStyleSelect() + "</span>",
      L.html('<button type="button" class="save-film-button" data-action="saveCustomFilm" aria-label="儲存自訂底片" title="儲存自訂底片"') + (!state.hasImage || photoIsBusy(state) || state.cropEditing ? ' disabled' : '') + '>' + iconSvg("saveFilm") + '</button>',
      "</div>",
      '<div class="style-selection-controls">',
      renderRange(L.text("風格強度"), "intensity", adjustment.intensity == null ? 50 : adjustment.intensity),
      "</div>",
      "</section>"
    ].join("");
  }

  function renderAdjustmentStyleSelect() {
    var selected = enabledStyles().find(function (style) { return style.id === currentLookID(); });
    return '<strong class="inspector-style-name">' + escapeHtml(selected ? styleTitle(selected) : L.text("選擇風格")) + '</strong>';
  }

  function renderLibraryCurrent(selected, isFilm) {
    return '<section class="film-current card" aria-label="' + escapeHtml(L.text(isFilm ? '目前底片' : '目前風格')) + '">' +
      (state.outputImage ? '<img class="film-current-image" src="' + escapeHtml(state.outputImage) + L.html('" alt="目前照片的處理預覽">') : '<span class="film-current-placeholder">' + iconSvg(isFilm ? "film" : "styles") + '</span>') +
      '<div class="film-current-copy"><span class="eyebrow">' + (isFilm ? L.text('目前底片') : L.text('目前風格')) + '</span><div class="library-card-heading"><h2>' +
      renderHelp(selected ? L.text(selected.subtitle) : L.text('可先加入工作台，再開啟照片套用。'), selected ? styleTitle(selected) : (isFilm ? L.text('選一卷底片') : L.text('選擇風格'))) + '</h2></div></div>' +
      L.html('<button class="button" data-page="home" type="button">回到工作台</button></section>');
  }

  function renderLibraryCard(style, enabled, busy) {
    var isFilm = !!style.isFilmStock || !!style.isOriginal || !!style.isCustom;
    var active = style.id === currentLookID();
    var included = enabled.indexOf(style.id) >= 0;
    var locked = busy || (included && enabled.length <= 1);
    var colors = style.palette || ["#403c35", "#bba87c", "#efe4cd"];
    var details = L.text(style.subtitle) || '';
    if (isFilm && L.text(style.filmAlgorithm)) details += L.text("\n\n感光與顯影特性\n") + L.text(style.filmAlgorithm);
    var id = escapeHtml(style.id);
    return '<article class="film-stock-card library-card' + (included ? ' selected' : '') + (active ? ' active' : '') + '" ' +
      (isFilm ? 'data-film-stock="' + id + '"' : 'data-style="' + id + '" data-style-card="' + id + '"') + '>' +
      '<div class="film-stock-band" style="background:linear-gradient(110deg,' + colors.map(escapeHtml).join(',') + ')"><span>' + escapeHtml(isFilm ? L.text(style.filmFamilyTitle) : (style.isMonochrome ? L.text('黑白風格') : L.text('彩色風格'))) + '</span>' +
      '<label class="film-stock-select"><input id="' + (isFilm ? 'film' : 'style') + '-choice-' + id + '" type="checkbox" data-toggle-' + (isFilm ? 'film' : 'style') + '="' + id + L.html('" aria-label="將 ') + escapeHtml(styleTitle(style)) + L.html(' 加入工作台"') + (included ? ' checked' : '') + (locked ? ' disabled' : '') + '><span>' + (included ? L.text('已選取') : L.text('選取')) + '</span></label></div>' +
      '<div class="film-stock-body"><div class="library-card-heading"><h2>' + renderHelp(details, styleTitle(style)) + (active ? L.html('<span class="film-applied-badge">使用中</span>') : '') +
      (isPromptCustomizedForLanguage(style) ? '<span class="style-prompt-badge">' + escapeHtml(text("promptCustomized")) + '</span>' : '') + '</h2>' +
      ((style.isOriginal || style.isCustom) ? "" : '<button class="film-prompt-edit" data-edit-style-prompt="' + id + L.html('" type="button" aria-label="編輯 ') + escapeHtml(styleTitle(style)) + L.html(' 的 AI 提示詞">AI 描述</button>')) + '</div>' +
      '<div class="film-stock-actions">' +
      (style.isCustom ? '<button class="button custom-film-export" data-action="exportCustomFilm" data-film-id="' + id + '" type="button"' + (busy ? ' disabled' : '') + '>' + iconSvg('exportImage') + '<span>' + L.text('匯出') + '</span></button><button class="button custom-film-delete" data-action="deleteCustomFilm" data-film-id="' + id + '" type="button"' + (busy ? ' disabled' : '') + '>' + iconSvg('trash') + '<span>' + L.text('刪除') + '</span></button>' : '') +
      '</div></div></article>';
  }

  function renderStylePage() {
    var selected = state.styles.find(function (style) { return style.id === state.selectedStyle && !style.isFilmStock; });
    var styles = applyStyleOrder(catalogStyles(), readStyleOrder()).filter(function (style) { return !style.isFilmStock; });
    var enabled = readEnabledStyleIDs();
    var count = styles.filter(function (style) { return enabled.indexOf(style.id) >= 0; }).length;
    return [
      renderPageHeading("風格庫", L.text("風格庫"), L.text("複選喜歡的風格加入工作台，按套用切換效果。拖曳卡片可排序常用項目，AI 描述可編輯提示詞。")),
      renderLibraryCurrent(selected, false),
      '<p class="film-result-count" role="status">' + styles.length + L.text(' 款風格 · 已選 ') + count + L.html(' 款加入工作台</p>'),
      L.html('<section class="film-stock-grid style-grid library-grid" aria-label="風格選擇">'),
      styles.map(function (style) { return renderLibraryCard(style, enabled, photoIsBusy(state)); }).join(''),
      '</section>'
    ].join('');
  }

  function renderFilmPage() {
    var groups = [["custom", L.text("自訂底片")], ["original", L.text("原始影像")],
      ["negative", L.text("彩色負片")], ["cinema", L.text("電影負片")],
      ["reversal", L.text("反轉片")], ["monochrome", L.text("黑白")],
      ["instant", L.text("即影即有")], ["creative", L.text("特殊底片／製程")], ["camera", L.text("模擬相機")]];
    function groupID(film) { return film.isCustom ? "custom" : film.isOriginal ? "original" : film.filmFamily; }
    function groupIndex(film) { return groups.findIndex(function (group) { return group[0] === groupID(film); }); }
    var films = catalogStyles().filter(function (style) { return style.isFilmStock || style.isOriginal || style.isCustom; })
      .sort(function (a, b) {
        return groupIndex(a) - groupIndex(b) || styleTitle(a).localeCompare(styleTitle(b), L.locale(state.language), { numeric: true, sensitivity: "base" }) || a.id.localeCompare(b.id);
      });
    var enabled = readEnabledStyleIDs();
    var enabledFilmCount = films.filter(function (film) { return enabled.indexOf(film.id) >= 0; }).length;
    var categories = [["all", L.text("全部")], ["negative", L.text("彩色負片")], ["cinema", L.text("電影負片")],
      ["reversal", L.text("反轉片")], ["monochrome", L.text("黑白")], ["instant", L.text("即影即有")], ["creative", L.text("特殊底片／製程")], ["camera", L.text("模擬相機")]];
    var family = state.filmFamily || "all";
    var query = (state.filmQuery || "").trim().toLocaleLowerCase();
    var visible = films.filter(function (film) {
      return (family === "all" || film.filmFamily === family) &&
        (styleTitle(film) + " " + L.text(film.subtitle) + " " + L.text(film.filmFamilyTitle) + " " + film.title).toLocaleLowerCase().indexOf(query) >= 0;
    });
    var busy = photoIsBusy(state);
    return [
      renderPageHeading("底片收藏", L.text("底片收藏"), L.text("複選喜歡的底片加入工作台，隨時切換並調整各自的效果。\n\n底片靈感模擬：參數為自行設計，尚未經原廠實測校準。紅外線款使用可見光 RGB 近似，不會還原實際紅外線資訊。"), '<button class="button film-import-button" data-action="importCustomFilm" type="button"' + (busy ? ' disabled' : '') + '>' + iconSvg("folderOpen") + '<span>' + L.text("匯入") + '</span></button>'),
      L.html('<div class="film-library-tools"><div class="film-categories" role="group" aria-label="底片分類">'),
      categories.map(function (category) {
        var count = films.filter(function (film) { return category[0] === "all" || film.filmFamily === category[0]; }).length;
        return '<button type="button" data-film-family="' + category[0] + '" aria-pressed="' + (family === category[0]) + '">' + category[1] + '<span>' + count + '</span></button>';
      }).join(""),
      '</div><label class="film-search">' + iconSvg("search") + L.html('<input id="filmSearch" type="search" aria-label="搜尋底片" placeholder="搜尋底片名稱或特色" value="') + escapeHtml(state.filmQuery || "") + '"></label></div>',
      '<p class="film-result-count" role="status">' + visible.length + L.text(' 款底片與製程 · 已選 ') + enabledFilmCount + L.html(' 款加入工作台</p>'),
      L.html('<section class="film-stock-grid library-grid compact-film-grid" aria-label="底片選擇">'),
      visible.map(function (film, index) {
        var groupStart = index === 0 || groupID(visible[index - 1]) !== groupID(film);
        var group = groups[groupIndex(film)];
        return (groupStart ? '<h3 class="film-group-divider">' + escapeHtml(group ? group[1] : L.text(film.filmFamilyTitle)) + '</h3>' : '') + renderLibraryCard(film, enabled, busy);
      }).join(''),
      visible.length ? '' : L.html('<div class="film-empty">沒有符合的底片。試試其他分類或關鍵字。</div>'),
      '</section>'
    ].join("");
  }

  function renderPromptDialog() {
    var styleID = state.promptDialog && state.promptDialog.styleID;
    var style = (state.styles || []).find(function (candidate) { return candidate.id === styleID; });
    if (!style) return "";
    var prompt = localizedStylePrompt(style);
    var defaultPrompt = localizedStyleDefaultPrompt(style);
    return [
      '<div class="prompt-dialog-backdrop" data-prompt-dialog-close>',
      '<section class="prompt-dialog" role="dialog" aria-modal="true" aria-labelledby="promptDialogTitle">',
      '<div class="prompt-dialog-head">',
      '<div><div class="help-label"><h2 id="promptDialogTitle">' + renderHelp(text("promptDialogHint"), text("promptDialogTitle")) + "</h2></div>",
      '<p>' + escapeHtml(styleTitle(style)) + "</p></div>",
      '<button class="collapse-button" data-prompt-dialog-close type="button" aria-label="' + escapeHtml(text("cancel")) + '" title="' + escapeHtml(text("cancel")) + '">' + iconSvg("x") + "</button>",
      "</div>",
      '<div class="prompt-dialog-body">',
      '<textarea id="promptEditorText" class="prompt-editor-text" data-prompt-style="' + escapeHtml(styleID) + '" data-default-prompt="' + escapeHtml(defaultPrompt) + '">' + escapeHtml(prompt) + "</textarea>",
      "</div>",
      '<div class="prompt-dialog-actions">',
      '<button class="button primary" data-prompt-save="' + escapeHtml(style.id) + '" type="button">' + escapeHtml(text("save")) + "</button>",
      '<button class="button" data-prompt-dialog-close type="button">' + escapeHtml(text("cancel")) + "</button>",
      '<button class="button" data-prompt-reset="' + escapeHtml(style.id) + '" type="button">' + escapeHtml(text("restore")) + "</button>",
      "</div>",
      "</section>",
      "</div>"
    ].join("");
  }

  function renderGlobalAdjustmentCard(adjustment) {
    var controls = [
      renderRange(L.text("曝光"), "exposure", adjustment.exposure == null ? 0 : adjustment.exposure, -100, 100),
      renderRange(L.text("色溫"), "whiteBalanceWarmth", adjustment.whiteBalanceWarmth == null ? 0 : adjustment.whiteBalanceWarmth, -100, 100),
      renderRange(L.text("色偏"), "whiteBalanceTint", adjustment.whiteBalanceTint == null ? 0 : adjustment.whiteBalanceTint, -100, 100),
      renderRange(L.text("對比"), "contrast", adjustment.contrast == null ? 0 : adjustment.contrast, -100, 100),
      renderRange(L.text("降噪"), "denoise", adjustment.denoise || 0),
      renderRange(L.text("模擬鏡頭模糊"), "backgroundBlur", adjustment.backgroundBlur || 0),
      renderRange(L.text("膚色冷暖"), "skinWarmth", adjustment.skinWarmth || 0, -100, 100, 1, "", L.text("只調整膚色區域：負值偏冷、正值偏暖，0 為中性。")),
      renderRange(L.text("美白"), "skinWhitening", adjustment.skinWhitening || 0),
      renderRange(L.text("磨皮"), "skinSmoothing", adjustment.skinSmoothing || 0)
    ];
    if (state.hdrFeatureEnabled !== false) {
      controls.push(renderRange(L.text("HDR 模擬"), "hdrAmount", adjustment.hdrAmount == null ? 25 : adjustment.hdrAmount));
    }
    if (adjustment.sourceToneZones) {
      controls.push('<div class="help-label panel-current">' + renderHelp(L.text("LLM 風格參數採分區套用，詳細數值顯示於亮部、中調與暗部的「LLM 區域語意參數」。"), L.text("區域風格參數")) + '</div>');
    }
    return renderAdjustmentCard("global", "", controls.join(""));
  }

  function renderToneAdjustmentCard(title, prefix, exposure, intensity, warmth, grain, planTone) {
    var selected = state.styles.find(function (style) { return style.id === currentLookID(); });
    var monochrome = !!(selected && selected.isMonochrome);
    var controls = [
      renderRange(L.text("曝光"), prefix + "Exposure", exposure || 0, -100, 100),
      renderRange(L.text("映射"), prefix + "Intensity", intensity || 0, 0, 100, 1, "", L.text("此項目暫時停用。"), true)
    ];
    if (!monochrome) controls.push(renderRange(L.text("色溫"), prefix + "Warmth", warmth || 0, -100, 100));
    controls.push(renderRange(L.text("顆粒"), prefix + "Grain", grain || 0));
    if (planTone) {
      controls.push(L.html('<p class="panel-current">LLM 區域語意參數</p>'));
      if (!monochrome) controls.push(renderRange(L.text("飽和基調"), prefix + "PlanBaseTone", planTone.baseTone || 0, -100, 100));
      controls.push(renderRange(L.text("區域對比"), prefix + "PlanContrast", planTone.contrast || 0, -100, 100));
      if (!monochrome) controls.push(renderRange(L.text("色偏"), prefix + "PlanTint", planTone.tint || 0, -100, 100));
      controls.push(renderRange(L.text("高光回收"), prefix + "PlanHighlights", planTone.highlights || 0, -100, 100));
      controls.push(renderRange(L.text("陰影調整"), prefix + "PlanShadows", planTone.shadows || 0, -100, 100));
      controls.push(renderRange(L.text("淡化"), prefix + "PlanFade", planTone.fade || 0));
      controls.push(renderRange(L.text("柔化"), prefix + "PlanSoftness", planTone.softness || 0));
    }
    return renderAdjustmentCard(prefix, title, controls.join(""));
  }

  function renderFilmDisclosure(id, controls) {
    return '<details class="film-disclosure" data-film-disclosure="' + id + '"' + (filmDisclosureState[id] ? ' open' : '') + L.html('><summary>範圍與亮部門檻</summary><div class="film-detail-controls">') + controls + '</div></details>';
  }

  function renderFilmHeading(title, help) {
    return '<div class="help-label"><h3>' + renderHelp(help, title) + '</h3></div>';
  }

  function renderFilmAdjustmentCard(adjustment) {
    var selected = state.styles.find(function (style) { return style.id === currentLookID(); });
    var monochrome = !!(selected && selected.isMonochrome);
    var value = function (key, fallback) { return adjustment[key] == null ? fallback : adjustment[key]; };
    var grainHelp = L.text("以多層晶體捕光呈現顆粒、細節遮蔽與底片返照。") + text("grainBaselineHint") + L.text("尺寸以長邊 3000 像素為基準，預覽與匯出依原圖比例調整；聚集程度控制晶體聚集，彩色比例控制各色層差異。黑白風格維持中性顆粒。");
    var sections = [
      '<div class="film-section">',
      renderRange(L.text("顆粒量"), "grain", value("grain", 0), 0, 100, 1, "", grainHelp)
    ];
    var filmStock = !!(selected && selected.filmFamily);
    var reversal = filmStock && selected.filmFamily === "reversal";
    var scanning = filmStock && value("scannerProfile", "off") !== "off";
    var printHelp = filmStock
      ? (reversal ? L.text('正片直接觀看，略過印相光源；曝光正值變亮、負值變暗。') : L.text('負片成像、印相與觀看分開計算；曝光正值變亮、負值變暗。'))
      : L.text('在目前風格上調整印相與觀看光源、曝光及反差；原始參考、0 EV 與反差 50 保留原有外觀。黑白風格維持灰階。');
    if (scanning || reversal) printHelp = L.text("掃描或正片模式在成品上套用印相光源色彩補償；曝光正值變亮、負值變暗。原始參考不改變光源色調。");
    var lights = state.filmIlluminants;
    sections.unshift([
      '<div class="film-section">',
      renderSelect(L.text("印相光源"), "printIlluminant", value("printIlluminant", "reference"), lights, false, printHelp),
      renderRange(reversal ? L.text("觀看曝光") : L.text("印相曝光補償"), "printExposure", value("printExposure", 0), -4, 4, 0.05, " EV", printHelp),
      renderRange(reversal ? L.text("觀看反差") : L.text("印相反差"), "printContrast", value("printContrast", 50), 0, 100, 1, "", L.text("50 為目前風格或底片的基準；提高數值增加明暗反差，降低數值讓階調更柔和。")),
      renderRange(L.text("暗角"), "vignetteBalance", vignetteBalance(adjustment), -100, 100),
      '</div>'
    ].join(''));
    sections.push(renderRange(L.text("顆粒尺寸"), "grainSize", value("grainSize", 1), 0.5, 4, 0.05, " px"));
    sections.push(renderRange(L.text("聚集程度"), "grainClumping", value("grainClumping", 0)));
    sections.push(renderRange(L.text("彩色比例"), "grainChroma", value("grainChroma", 0), 0, 100, 1, "", null, monochrome));
    var developmentHelp = L.text('模擬顯影液消耗與補充，調整局部反差。效果設為 0 時關閉，時間、擴散與攪拌不會生效；提高效果後，時間與擴散影響局部反差，提高攪拌補充會減弱顯影液耗竭效果。');
    sections.push('</div><div class="film-section">');
    sections.push(renderRange(L.text("顯影效果"), "developmentAmount", value("developmentAmount", 0), 0, 100, 1, "", developmentHelp));
    sections.push(renderRange(L.text("顯影時間"), "developmentTime", value("developmentTime", 50)));
    sections.push(renderRange(L.text("擴散範圍"), "developmentDiffusion", value("developmentDiffusion", 0.15), 0.02, 1, 0.01, "%"));
    sections.push(renderRange(L.text("攪拌補充"), "developmentAgitation", value("developmentAgitation", 50)));
    var bloomHelp = L.text('讓明亮邊緣泛出中性的柔和光暈。強度設為 0 時關閉，提高強度即可啟用。範圍為原圖長邊的百分比，提高範圍會擴大光暈；降低亮部門檻可涵蓋更多亮部，提高門檻則集中於最亮區域。');
    sections.push('</div><div class="film-section">');
    sections.push(renderRange(L.text("柔光強度"), "bloomAmount", value("bloomAmount", 0), 0, 100, 1, "", bloomHelp));
    sections.push(renderFilmDisclosure("bloom", [
      renderRange(L.text("柔光範圍"), "bloomRadius", value("bloomRadius", 0.4), 0.05, 2, 0.01, "%"),
      renderRange(L.text("亮部門檻"), "bloomThreshold", value("bloomThreshold", 75))
    ].join('')));
    var halationHelp = (monochrome ? L.text('黑白風格呈現灰階返照光暈，維持純黑白。') : L.text('在明暗交界呈現紅橙色的底片返照。')) + L.text('強度設為 0 時關閉，提高強度即可啟用。範圍為原圖長邊的百分比，提高範圍會擴大返照光暈；降低亮部門檻可讓更多亮部產生返照。');
    sections.push('</div><div class="film-section">');
    sections.push(renderRange(L.text("紅暈強度"), "halationAmount", value("halationAmount", 0), 0, 100, 1, "", halationHelp));
    sections.push(renderFilmDisclosure("halation", [
      renderRange(L.text("紅暈範圍"), "halationRadius", value("halationRadius", 0.1), 0.01, 0.3, 0.01, "%"),
      renderRange(L.text("亮部門檻"), "halationThreshold", value("halationThreshold", 75))
    ].join('')));
    sections.push('</div>');
    var filterHelp = L.text('調整原圖各色轉為灰階的明暗關係，選用黑白風格或黑白底片時生效。先選擇濾鏡色彩，再調整濃度；無濾鏡或濃度 0 時不套用。');
    sections.push('<div class="film-section">');
    sections.push(renderSelect(L.text("濾鏡色彩"), "monochromeFilter", value("monochromeFilter", "none"), [
      { id: "none", title: L.text("無濾鏡") }, { id: "yellow", title: L.text("黃色 · 柔和對比") },
      { id: "orange", title: L.text("橙色 · 加深天空") }, { id: "red", title: L.text("紅色 · 強烈對比") },
      { id: "green", title: L.text("綠色 · 提亮綠葉") }
    ], !monochrome, filterHelp));
    sections.push(renderRange(L.text("濾鏡濃度"), "monochromeFilterStrength", value("monochromeFilterStrength", 0), 0, 100, 1, "", null, !monochrome || value("monochromeFilter", "none") === "none"));
    sections.push('</div>');
    return renderAdjustmentCard("film", null, sections.join(''));
  }

  function renderScannerAdjustmentCard(adjustment) {
    var selected = state.styles.find(function (style) { return style.id === currentLookID(); });
    var film = !!(selected && (selected.isFilmStock || selected.isOriginal));
    var monochrome = !!(selected && selected.isMonochrome);
    var reversal = selected && selected.filmFamily === "reversal";
    var value = function (key, fallback) { return adjustment[key] == null ? fallback : adjustment[key]; };
    var enabled = film && value("scannerProfile", "off") !== "off";
    return renderAdjustmentCard("scanner", L.text("底片掃描"), [
      renderSelect(L.text("掃描風格"), "scannerProfile", value("scannerProfile", "off"), [
        {id:"off",title:L.text("關閉")}, {id:"neutral",title:L.text("中性掃描")}, {id:"warmCool",title:L.text("暖調掃描")}
      ], !film, film ? L.text("中性掃描保留底片色彩；暖調掃描加上暖中調與冷亮部。關閉時保留原有影像效果。") : L.text("選擇一款底片後即可使用掃描。")),
      renderRange(L.text("色彩濃度"), "scanSaturation", value("scanSaturation", 50), 0, 100, 1, "", L.text("50 保留原色彩，0 轉為灰階。"), !enabled || monochrome),
      renderRange(L.text("色層分離"), "scanDensityCorrection", value("scanDensityCorrection", 100), 0, 100, 1, "", L.text("校正負片染料在掃描時互相混入的色彩；降低可保留較多混色。"), !enabled || monochrome || reversal || !!(selected && selected.isOriginal)),
      renderRange(L.text("掃描雜散光"), "scanFlare", value("scanFlare", 0), 0, 100, 1, "", L.text("模擬掃描器內部漏入的光，改變高密度區的層次與反差；0 關閉。"), !enabled),
      renderRange(L.text("中調冷暖"), "scanMidtoneWarmth", value("scanMidtoneWarmth", 0), -100, 100, 1, "", L.text("正值偏暖黃，負值偏冷藍；在目前掃描風格上微調。"), !enabled || monochrome),
      renderRange(L.text("亮部冷暖"), "scanHighlightWarmth", value("scanHighlightWarmth", 0), -100, 100, 1, "", L.text("正值偏暖黃，負值偏冷藍；接近純白時逐漸減弱染色。"), !enabled || monochrome)
    ].join(""));
  }

  function renderFrameWatermarkCard(adjustment) {
    return renderAdjustmentCard("frameWatermark", L.text("外框與浮水印"), [
      renderToggle(L.text("外框"), "frameEnabled", adjustment.frameEnabled),
      renderSelect(L.text("外框樣式"), "frameStyle", adjustment.frameStyle, state.frameStyles, !adjustment.frameEnabled),
      renderToggle(L.text("日期"), "dateEnabled", adjustment.dateEnabled),
      renderSelect(L.text("日期格式"), "dateStyle", adjustment.dateStyle, state.dateStyles, !adjustment.dateEnabled, L.text("以復古相機的橘紅色數位印字與柔和光暈，印上目前日期。"))
    ].join(""));
  }

  function rangeValueText(value, low, high, step, unit) {
    var decimals = step < 1 ? String(step).split(".")[1].length : 0;
    // Keep native/MCP decimals rather than rounding them to a slider step.
    var numeric = Number(clamp(value, low, high).toFixed(Math.max(decimals, 6)));
    var label = low < 0 && high > 0 && numeric > 0 ? "+" + numeric : String(numeric);
    return label + (unit || "");
  }

  function renderRange(label, key, value, min, max, step, unit, help, disabled) {
    var low = min == null ? 0 : min;
    var high = max == null ? 100 : max;
    var increment = step == null ? 1 : step;
    var numeric = clamp(value, low, high);
    var signed = low < 0 && high > 0;
    return [
      '<div class="control-row" data-reset-adjustment="' + key + '">',
      '<div class="control-label"><label class="help-label" for="adjustment-' + key + '">' + renderHelp(help, label) + '</label><span data-value-label="' + key + '">' + rangeValueText(numeric, low, high, increment, unit) + "</span></div>",
      '<input class="range-slider ' + (signed ? "signed-range" : "positive-range") + '" type="range" id="adjustment-' + key + '" aria-label="' + label + '" min="' + low + '" max="' + high + '" step="any" value="' + numeric + '" data-range-step="' + increment + '" data-range-unit="' + (unit || '') + '" data-range-min="' + low + '" data-range-max="' + high + '" data-adjustment="' + key + '"' + (disabled ? ' disabled' : '') + '>',
      "</div>"
    ].join("");
  }

  function renderToggle(label, key, value) {
    return [
      '<div class="toggle-row">',
      "<span>" + label + "</span>",
      '<button class="switch ' + (value ? "on" : "") + '" data-toggle="' + key + '" type="button" aria-label="' + label + '" aria-pressed="' + (value ? "true" : "false") + '"></button>',
      "</div>"
    ].join("");
  }

  function renderSelect(label, key, value, options, disabled, help) {
    return [
      '<div class="select-row">',
      '<label class="help-label" for="' + key + '">' + renderHelp(help, label) + '</label>',
      '<select id="' + key + '" data-select="' + key + '" ' + (disabled ? "disabled" : "") + ">",
      options.map(function (option) {
        return '<option value="' + option.id + '" ' + (option.id === value ? "selected" : "") + ">" + escapeHtml(L.text(option.title)) + "</option>";
      }).join(""),
      "</select>",
      "</div>"
    ].join("");
  }

  function renderAI() {
    return [
      renderPageHeading("本機智慧分析", L.text("AI 核心"), L.text("所有影像分析都在裝置端執行，模型與照片不離開你的裝置。")),
      '<section class="section">',
      '<div class="card model-group-card">',
      renderCustomModel(),
      state.ai.import && state.ai.import.active ? renderModelImport(state.ai.import) : "",
      "</div>",
      "</section>",
      renderRepositoryDownload()
    ].join("");
  }

  function modelFileSize(bytes) {
    if (!bytes) return L.text("大小待下載時確認");
    return bytes >= 1000000000 ? (bytes / 1000000000).toFixed(2) + " GB" : (bytes / 1000000).toFixed(1) + " MB";
  }

  function renderRepositoryDownload() {
    var format = state.repositoryFormat || "mlx";
    var repository = state.ai.repository || {};
    var matches = repository.format === format;
    var loading = !!repository.loading;
    var busy = modelOperationIsBusy();
    var disabled = busy || loading ? " disabled" : "";
    var results = matches ? repository.results || [] : [];
    var id = matches ? repository.id || "" : "";
    var mainFiles = repository.mainFiles || [];
    var projectors = repository.projectorFiles || [];
    var mainPath = mainFiles.some(function (f) { return f.path === state.repositoryMainPath; }) ? state.repositoryMainPath : "";
    var projectorPath = projectors.some(function (f) { return f.path === state.repositoryProjectorPath; }) ? state.repositoryProjectorPath : "";
    if (!mainPath && mainFiles.length === 1) mainPath = mainFiles[0].path;
    if (!projectorPath && projectors.length === 1) projectorPath = projectors[0].path;
    function fileOptions(files, selected) {
      return L.html('<option value="">請選擇檔案</option>') + files.map(function (file) {
        return '<option value="' + escapeHtml(file.path) + '"' + (file.path === selected ? ' selected' : '') + '>' +
          escapeHtml(file.path + (file.size ? ' · ' + modelFileSize(file.size) : '')) + '</option>';
      }).join("");
    }
    return [
      '<section class="section"><div class="help-label"><h2 class="section-title">' + renderHelp(L.text("從 Hugging Face 搜尋或輸入模型網址。MLX 會下載完整資料夾；GGUF 請搭配對應的視覺編碼器。"), L.text("模型下載")) + "</h2></div>",
      '<div class="card repository-card">',
      '<form id="modelRepositoryForm" class="repository-search">',
      L.html('<label class="repository-field"><span>格式</span><select id="repositoryFormat"') + (busy ? ' disabled' : '') + '>',
      option('mlx', 'MLX · Apple Silicon', format), option('gguf', 'GGUF · llama.cpp', format), '</select></label>',
      L.html('<label class="repository-field"><span>模型名稱或 Repository</span><input id="modelRepositoryQuery" type="search" placeholder="例如 Qwen3.5 或 mlx-community/Qwen3.5-4B-4bit" value="') + escapeHtml(state.repositoryQuery || '') + '"' + (busy ? ' disabled' : '') + '></label>',
      '<button class="button" type="submit"' + disabled + L.html('>查詢模型</button></form>'),
      '<div class="repository-suggestions">',
      renderHelp(L.text('僅列出 2026 年起發表、支援照片分析的模型。選項隨上方格式切換，點選可查看檔案與下載大小。'), L.text('快速查看')),
      modelRepositorySuggestions.map(function (model) {
        return '<button type="button" data-repository="' + escapeHtml(model[format]) + '" data-repository-format="' + escapeHtml(format) +
          '" data-tooltip="' + escapeHtml(model.title + L.text(' · 發表於 ') + model.released + (format === 'mlx' ? L.text(' · 4-bit 量化') : L.text(' · 含視覺 mmproj'))) + '"' + disabled + '>' +
          escapeHtml(model.title + ' · ' + format.toUpperCase()) + '</button>';
      }).join(''),
      '</div>',
      format === 'mlx' && state.ai.mlxAvailable === false ? '<p class="status-line">' + escapeHtml(L.text(state.ai.mlxMessage) || '') + '</p>' : '',
      '<p class="status-line" role="status">' + escapeHtml(matches ? L.text(repository.message) || L.text('搜尋名稱或貼上 Hugging Face repository。') : L.text('按查詢模型以取得此格式的模型。')) + '</p>',
      loading ? L.html('<button class="button" type="button" data-action="cancelModelRepositoryQuery">取消查詢</button>') : '',
      results.length ? L.html('<label class="repository-field"><span>搜尋結果</span><select id="repositoryResult"') + disabled + L.html('><option value="">選擇模型以查看檔案</option>') + results.map(function (result) {
        return '<option value="' + escapeHtml(result.id) + '">' + escapeHtml(result.id) + '</option>';
      }).join('') + '</select></label>' : '',
      id ? '<div class="repository-detail"><strong>' + escapeHtml(id) + L.html('</strong><span class="model-meta">固定版本 ') + escapeHtml((repository.revision || '').slice(0, 10)) + '</span>' +
        (format === 'mlx' ? '<p class="status-line">' + (repository.files || []).length + L.text(' 個檔案 · ') + modelFileSize(repository.totalBytes) + '</p>' :
          L.html('<div class="repository-files"><label class="repository-field"><span>GGUF 主模型</span><select id="repositoryMainFile"') + disabled + '>' + fileOptions(mainFiles, mainPath) + '</select></label>' +
          L.html('<label class="repository-field"><span>對應的 mmproj</span><select id="repositoryProjectorFile"') + disabled + '>' + fileOptions(projectors, projectorPath) + '</select></label></div>') + '</div>' : '',
      id ? '<button id="downloadRepository" class="button primary" type="button"' + (busy || loading || (format === 'gguf' && (!mainPath || !projectorPath)) ? ' disabled' : '') + L.html('>下載並使用模型</button>') : '',
      state.ai.download && state.ai.download.active ? renderDownload(state.ai.download) : '',
      '</div></section>'
    ].join('');
  }

  function bindRepositoryEvents() {
    var query = app.querySelector('#modelRepositoryQuery');
    if (query) {
      query.addEventListener('input', function () { state.repositoryQuery = query.value; });
      query.addEventListener('compositionstart', function () { isComposingRepositoryQuery = true; });
      query.addEventListener('compositionend', function () {
        state.repositoryQuery = query.value;
        isComposingRepositoryQuery = false;
        render();
      });
    }
    var format = app.querySelector('#repositoryFormat');
    if (format) format.addEventListener('change', function () {
      state.repositoryFormat = format.value;
      state.repositoryMainPath = state.repositoryProjectorPath = '';
      post('cancelModelRepositoryQuery');
      render();
    });
    var form = app.querySelector('#modelRepositoryForm');
    if (form) form.addEventListener('submit', function (event) {
      event.preventDefault();
      var value = (state.repositoryQuery || '').trim();
      if (!value || modelOperationIsBusy() || (state.ai.repository && state.ai.repository.loading)) return;
      state.repositoryMainPath = state.repositoryProjectorPath = '';
      post(value.indexOf('/') >= 0 ? 'inspectModelRepository' : 'searchModelRepositories', { query: value, format: state.repositoryFormat || 'mlx' });
    });
    var result = app.querySelector('#repositoryResult');
    if (result) result.addEventListener('change', function () {
      if (!result.value) return;
      state.repositoryQuery = result.value;
      state.repositoryMainPath = state.repositoryProjectorPath = '';
      post('inspectModelRepository', { query: result.value, format: state.repositoryFormat || 'mlx' });
    });
    app.querySelectorAll('[data-repository]').forEach(function (button) {
      button.addEventListener('click', function () {
        state.repositoryQuery = button.dataset.repository;
        state.repositoryFormat = button.dataset.repositoryFormat;
        state.repositoryMainPath = state.repositoryProjectorPath = '';
        post('inspectModelRepository', { query: state.repositoryQuery, format: state.repositoryFormat });
      });
    });
    [['repositoryMainFile', 'repositoryMainPath'], ['repositoryProjectorFile', 'repositoryProjectorPath']].forEach(function (pair) {
      var select = app.querySelector('#' + pair[0]);
      if (select) select.addEventListener('change', function () { state[pair[1]] = select.value; render(); });
    });
    var download = app.querySelector('#downloadRepository');
    if (download) download.addEventListener('click', function () {
      var main = app.querySelector('#repositoryMainFile'), projector = app.querySelector('#repositoryProjectorFile');
      post('downloadModelRepository', { mainPath: main ? main.value : '', projectorPath: projector ? projector.value : '' });
    });
  }

  function renderCustomModel() {
    var choices = state.ai.modelChoices || [];
    var selected = choices.find(function (choice) { return choice.id === state.ai.selectedModelID; });
    var unavailable = choices.filter(function (choice) { return !choice.ready; });
    var disabled = modelOperationIsBusy() ? " disabled" : "";
    var scanning = !!state.ai.modelDirectoryScanning;
    var options = choices.map(function (choice) {
      return '<option value="' + escapeHtml(choice.id) + '"' + (choice.id === state.ai.selectedModelID ? " selected" : "") +
        (choice.ready ? "" : " disabled") + '>' + escapeHtml((choice.format === "mlx" ? "MLX · " : "GGUF · ") + choice.title + (choice.ready ? "" : L.text("（無法使用）"))) + '</option>';
    });
    return [
      '<div class="model-card custom-model-card">',
      '<div class="help-label"><p class="model-title">' + renderHelp(L.text("支援 GGUF（主模型＋mmproj）與 MLX 視覺模型。選取上層目錄後，可直接切換其中的模型。"), L.text("本機模型")) + "</p></div>",
      '<div class="model-actions">',
      '<button class="button primary" type="button" data-action="openModelDirectory"' + disabled + L.html('>選取模型目錄</button>'),
      '<button class="button" type="button" data-action="openCustomModel"' + disabled + L.html('>匯入模型檔案</button>'),
      '</div>',
      '<p class="model-directory-path" data-model-directory-path>' + escapeHtml(state.ai.modelDirectoryPath || L.text("尚未選取目錄；也可以從下方切換已匯入或下載的模型。")) + '</p>',
      '<p class="status-line" data-model-directory-status role="status">' + escapeHtml(scanning ? L.text("正在掃描模型目錄…") : (L.text(state.ai.modelDirectoryMessage) || L.text("目錄中的模型會直接使用原始檔案，不會複製。"))) + '</p>',
      scanning ? L.html('<div class="model-actions"><button class="button" type="button" data-action="cancelModelDirectoryScan">取消掃描</button></div>') : '',
      '<div class="model-picker-field">',
      L.html('<label for="localModelPicker">使用的模型</label>'),
      '<select id="localModelPicker" data-model-picker aria-describedby="modelSelectionStatus"' + (disabled || (!choices.length ? " disabled" : "")) + '>' + options.join("") + '</select>',
      '</div>',
      selected ? '<p class="model-selected-title">' + escapeHtml(selected.title) + '</p>' : '',
      '<p class="status-line" id="modelSelectionStatus" data-model-selection-status role="status">' + escapeHtml(L.text(state.ai.message) || (state.ai.ready ? L.text("模型已就緒。") : L.text("請選擇可用的 GGUF 或 MLX 視覺模型。"))) + '</p>',
      unavailable.length ? '<ul class="model-unavailable-list">' + unavailable.map(function (choice) {
        return '<li>' + escapeHtml(choice.title) + '：' + escapeHtml(L.text(choice.message) || L.text("模型或 mmproj 不完整，無法使用。")) + '</li>';
      }).join("") + '</ul>' : '',
      state.ai.modelDirectoryPath && !scanning && !choices.some(function (choice) { return choice.source === "directory"; })
        ? L.html('<p class="status-line">此目錄沒有可列出的 GGUF 或 MLX 視覺模型。請確認檔案位置與格式。</p>') : '',
      "</div>"
    ].join("");
  }

  function modelOperationIsBusy() {
    return !!(state.ai.busy || state.ai.modelDirectoryScanning || photoIsBusy(state));
  }

  function renderModelImport(progress) {
    return '<div class="card status-card" data-model-import-progress>' +
      '<p class="status-line"><strong>' + (progress.isCancelling ? L.text("正在取消匯入") : L.text("正在匯入模型")) + '</strong></p>' +
      '<p class="status-line">' + escapeHtml(progress.fileName || "") + '</p>' +
      '<progress max="1" value="' + clamp(progress.fraction, 0, 1) + '"></progress>' +
      '<p class="status-line">' + (progress.completedFiles || 0) + '/' + (progress.totalFiles || 0) + L.text(' 個檔案 · ') + (progress.percent || 0) + '%</p>' +
      '<button class="button" data-action="cancelImport" ' + (progress.isCancelling ? 'disabled' : '') + L.html('>取消匯入</button></div>');
  }

  function renderDownload(download) {
    return [
      '<div class="card status-card download-status">',
      L.html('<p class="status-line"><strong>正在下載 ') + escapeHtml(download.fileName || "") + "</strong></p>",
      '<div class="download-progress-row">',
      L.html('<progress aria-label="模型下載進度" max="1" value="') + clamp(download.fraction, 0, 1) + '"></progress>',
      L.html('<button class="button" type="button" data-action="cancelDownload">取消下載</button>'),
      '</div>',
      '<p class="status-line">' + (download.completedFiles || 0) + "/" + (download.totalFiles || 0) + L.text(" 個檔案 · ") + (download.percent || 0) + "%</p>",
      "</div>"
    ].join("");
  }

  function renderSettings() {
    var originalResolutionHelp = L.text("預設關閉，使用最長邊 2048 px 的處理縮圖；開啟後使用原檔。若設備效能不足，建議關閉以加快操作。");
    var version = window.__appInfo ? window.__appInfo.version + " build " + window.__appInfo.build : "—";
    return [
      renderPageHeading("偏好設定", L.text("設定"), L.text("依照你的工作方式調整語言、外觀與影像功能。"), L.html('<button class="button settings-update-button" type="button" data-action="checkAppUpdate">檢查更新</button>')),
      '<section class="section">',
      '<div class="card settings-card">',
      L.html('<div class="settings-row"><span>語言</span><select id="languageSelect">'),
      option("automatic", L.text("自動偵測"), state.language),
      option("traditionalChinese", L.text("繁體中文"), state.language),
      option("english", L.text("英文"), state.language),
      option("japanese", L.text("日文"), state.language),
      option("korean", L.text("韓語"), state.language),
      "</select></div>",
      L.html('<div class="settings-row"><span>外觀</span><select id="appearanceSelect">'),
      option("comfortable", L.text("舒適"), state.appearance),
      option("bright", L.text("明亮"), state.appearance),
      option("dark", L.text("暗色"), state.appearance),
      "</select></div>",
      L.html('<div class="settings-row"><span>顯示功能說明</span><button id="showHelpToggle" class="switch ') + (state.showHelp ? 'on' : '') + L.html('" type="button" role="switch" aria-label="顯示功能說明" aria-checked="') + state.showHelp + '"></button></div>',
      '<div class="settings-row"><span>' + renderHelp(originalResolutionHelp, L.text("使用原檔編輯")) + '</span><span id="originalResolutionHelp" hidden>' + escapeHtml(originalResolutionHelp) + '</span>',
      '<button id="originalResolutionToggle" class="switch ' + (state.originalResolutionEditing !== false ? "on" : "") + L.html('" type="button" role="switch" aria-label="使用原檔編輯" aria-describedby="originalResolutionHelp" aria-checked="') + (state.originalResolutionEditing !== false ? "true" : "false") + '" ' + (photoIsBusy(state) ? "disabled" : "") + '></button></div>',
      L.html('<div class="settings-row"><span>啟用 HDR 模擬</span>'),
      '<button id="hdrFeatureToggle" class="switch ' + (state.hdrFeatureEnabled !== false ? "on" : "") + L.html('" type="button" aria-label="啟用 HDR 模擬" aria-pressed="') + (state.hdrFeatureEnabled !== false ? "true" : "false") + '"></button></div>',
      L.html('<div class="settings-row"><span>本機 MCP 伺服器</span><button id="mcpEnabledToggle" class="switch ') + (state.mcp.enabled ? "on" : "") + L.html('" type="button" aria-label="本機 MCP 伺服器" aria-pressed="') + Boolean(state.mcp.enabled) + '"></button></div>',
      L.html('<div class="settings-row"><span>MCP 狀態</span><span>') + escapeHtml(L.text(state.mcp.status)) + '</span></div>',
      L.html('<div class="settings-row"><span>MCP 位址</span><code class="selectable">') + escapeHtml(state.mcp.endpoint) + '</code></div>',
      L.html('<div class="settings-row"><span>用戶端連線設定</span><button class="button" data-action="copyMCPConfiguration" ') + (!state.mcp.running ? "disabled" : "") + L.html('>複製 MCP 設定</button></div>'),
      L.html('<div class="settings-row"><span>設定檔</span><code class="selectable mcp-path">') + escapeHtml(state.mcp.connectionFile) + '</code></div>',
      L.html('<div class="settings-row"><span>版本</span><span class="mono">') + escapeHtml(version) + "</span></div>",
      "</div>",
      "</section>"
    ].join("");
  }

  function renderPageHeading(eyebrow, title, description, actions) {
    return [
      '<div class="page-heading">',
      '<p class="eyebrow">' + escapeHtml(L.text(eyebrow)) + "</p>",
      '<div class="page-title-row"><h1>' + renderHelp(description, title) + "</h1>" + (actions || "") + "</div>",
      "</div>"
    ].join("");
  }

  function renderHelp(description, label) {
    if (!description) return escapeHtml(label);
    return '<span id="help-' + (++helpSequence) + '" class="help-title" tabindex="0" data-tooltip="' + escapeHtml(description) + '">' + escapeHtml(label) + '</span>';
  }

  function prepareNativeTooltips() {
    // Replace browser title delays with the same immediate, accessible bubble.
    app.querySelectorAll('[title]').forEach(function (node) {
      if (node.title) node.dataset.tooltip = node.title;
      node.removeAttribute('title');
      if (!node.matches('button,input,select,textarea,a[href],[tabindex]')) node.tabIndex = 0;
    });
  }

  function hideTooltip() {
    clearTimeout(tooltipDismissTimer);
    if (tooltipAnchor) {
      var ids = (tooltipAnchor.getAttribute('aria-describedby') || '').split(/\s+/).filter(function (id) { return id && id !== 'instantTooltip'; });
      if (ids.length) tooltipAnchor.setAttribute('aria-describedby', ids.join(' '));
      else tooltipAnchor.removeAttribute('aria-describedby');
    }
    tooltipAnchor = null;
    if (tooltip) tooltip.hidden = true;
  }

  function showTooltip(anchor, explicit) {
    if ((!state.showHelp && !explicit) || !tooltip || !anchor || !anchor.isConnected || !anchor.dataset.tooltip) return;
    clearTimeout(tooltipDismissTimer);
    if (tooltipAnchor !== anchor) hideTooltip();
    tooltipAnchor = anchor;
    tooltip.textContent = anchor.dataset.tooltip;
    tooltip.hidden = false;
    var ids = (anchor.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean);
    if (ids.indexOf(tooltip.id) < 0) ids.push(tooltip.id);
    anchor.setAttribute('aria-describedby', ids.join(' '));
    var bounds = anchor.getBoundingClientRect();
    var width = tooltip.offsetWidth, height = tooltip.offsetHeight;
    var left = Math.max(12, Math.min(innerWidth - width - 12, bounds.left + bounds.width / 2 - width / 2));
    var above = bounds.top - height - 8, below = bounds.bottom + 8;
    // Title help should leave the slider/action directly below it available.
    var top = anchor.classList.contains('help-title') ? above : below;
    if (top < 12) top = below;
    if (top + height > innerHeight - 12) top = above;
    top = Math.max(12, Math.min(innerHeight - height - 12, top));
    tooltip.style.left = left + 'px';
    tooltip.style.top = top + 'px';
  }

  function initializeAutoHideScrollbars() {
    var timers = new WeakMap();
    var active = new Set();
    function hide(node) {
      clearTimeout(timers.get(node));
      node.classList.remove('scroll-active');
      timers.delete(node);
      active.delete(node);
    }
    function reveal(node) {
      if (!(node instanceof Element)) return;
      var css = getComputedStyle(node);
      var vertical = node.scrollHeight > node.clientHeight && /^(auto|scroll)$/.test(css.overflowY);
      var horizontal = node.scrollWidth > node.clientWidth && /^(auto|scroll)$/.test(css.overflowX);
      if (!vertical && !horizontal) return;
      node.classList.add('scroll-active');
      active.add(node);
      clearTimeout(timers.get(node));
      timers.set(node, setTimeout(function () { hide(node); }, 1000));
    }
    function ancestors(target, visit) {
      var node = target instanceof Element ? target : null;
      while (node) { visit(node); node = node.parentElement; }
    }
    // 只有使用者操作才喚醒；重繪後還原 scrollTop 不應重新顯示捲軸。
    document.addEventListener('wheel', function (event) {
      ancestors(event.target, reveal);
    }, { passive: true });
    document.addEventListener('keydown', function (event) {
      if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Home', 'End', ' '].indexOf(event.key) < 0) return;
      if (event.target instanceof Element && event.target.closest('input, textarea, select, [contenteditable=true]')) return;
      ancestors(event.target, reveal);
    });
    document.addEventListener('touchmove', function (event) {
      ancestors(event.target, reveal);
    }, { passive: true });
    document.addEventListener('scroll', function (event) {
      if (active.has(event.target)) reveal(event.target);
    }, true);
    // 接近固定寬度的捲軸軌道時顯示，保留滑鼠拖曳操作。
    document.addEventListener('pointermove', function (event) {
      ancestors(event.target, function (node) {
        var rect = node.getBoundingClientRect();
        if ((event.clientX >= rect.right - 10 && event.clientX <= rect.right) ||
            (event.clientY >= rect.bottom - 10 && event.clientY <= rect.bottom)) reveal(node);
      });
    }, { passive: true });
    window.addEventListener('blur', function () { active.forEach(hide); });
  }

  function initializeTooltips() {
    tooltip = document.createElement('div');
    tooltip.id = 'instantTooltip';
    tooltip.className = 'instant-tooltip';
    tooltip.setAttribute('role', 'tooltip');
    tooltip.hidden = true;
    document.body.appendChild(tooltip);
    function trigger(target) { return target instanceof Element ? target.closest('[data-tooltip]') : null; }
    function containsTooltip(target) { return target instanceof Node && (tooltip.contains(target) || (tooltipAnchor && tooltipAnchor.contains(target))); }
    function dismissLater() {
      clearTimeout(tooltipDismissTimer);
      // Only dismissal waits briefly, so the pointer can cross the bubble gap.
      tooltipDismissTimer = setTimeout(function () {
        if (tooltipAnchor && (tooltipAnchor.contains(document.activeElement) ||
            tooltipAnchor.matches(':hover') || tooltip.matches(':hover'))) return;
        hideTooltip();
      }, 120);
    }
    document.addEventListener('pointerover', function (event) {
      if (tooltip.contains(event.target)) { clearTimeout(tooltipDismissTimer); return; }
      var anchor = trigger(event.target);
      if (anchor) showTooltip(anchor);
    });
    document.addEventListener('pointerout', function (event) {
      if (containsTooltip(event.target) && !containsTooltip(event.relatedTarget)) dismissLater();
    });
    document.addEventListener('focusin', function (event) {
      var anchor = trigger(event.target);
      if (anchor) showTooltip(anchor); else hideTooltip();
    });
    document.addEventListener('focusout', function (event) {
      if (tooltipAnchor && tooltipAnchor.contains(event.target) && !containsTooltip(event.relatedTarget)) dismissLater();
    });
    document.addEventListener('click', function (event) {
      var anchor = trigger(event.target);
      if (anchor && anchor.classList.contains('help-title')) {
        showTooltip(anchor, true);
        return;
      }
      if (!containsTooltip(event.target)) hideTooltip();
    });
    document.addEventListener('keydown', function (event) {
      var anchor = trigger(event.target);
      if ((event.key === 'Enter' || event.key === ' ') && anchor && anchor.classList.contains('help-title')) {
        event.preventDefault();
        showTooltip(anchor, true);
        return;
      }
      if (event.key === 'Escape' && !tooltip.hidden) {
        hideTooltip();
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
    document.addEventListener('scroll', function (event) {
      if (!tooltip.contains(event.target)) hideTooltip();
    }, true);
    window.addEventListener('resize', hideTooltip);
    window.addEventListener('blur', hideTooltip);
  }

  function option(value, label, selected) {
    return '<option value="' + value + '" ' + (value === selected ? "selected" : "") + ">" + label + "</option>";
  }

  function bindPhotoDirectoryEvents() {
    var thumbnailSizeSelect = app.querySelector("#photoThumbnailSize");
    if (thumbnailSizeSelect) thumbnailSizeSelect.addEventListener("change", function () {
      state.thumbnailSize = normalizedThumbnailSize(thumbnailSizeSelect.value);
      localStorage.setItem("photoStyle.thumbnailSize", state.thumbnailSize);
      // Resize the existing strip without reloading thumbnails or the source photo.
      var directory = app.querySelector(".photo-directory");
      if (directory) directory.dataset.thumbnailSize = state.thumbnailSize;
      fitPreviewImage();
      rememberThumbnailViewport();
      scheduleThumbnailRequest();
    });
    app.querySelectorAll("[data-directory-photo]").forEach(function (button) {
      button.addEventListener("click", function () {
        if (photoIsBusy(state) || (state.photoDirectory && state.photoDirectory.isScanning)) return;
        flushPhotoEdits("selectDirectoryPhoto", { id: button.dataset.directoryPhoto });
        discardPendingPhotoEdits();
      });
    });
    function scrollThumbnails(steps) {
        var list = app.querySelector(".photo-thumbnail-list");
        var card = list && list.querySelector(".photo-thumbnail");
        if (!card) return;
        var pitch = card.getBoundingClientRect().width + (parseFloat(getComputedStyle(list).columnGap) || 0);
        list.scrollBy({ left: steps * pitch,
          behavior: document.hidden || window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
        rememberThumbnailViewport();
        scheduleThumbnailRequest();
    }
    app.querySelectorAll("[data-thumbnail-scroll]").forEach(function (button) {
      button.addEventListener("click", function () { scrollThumbnails(Number(button.dataset.thumbnailScroll)); });
    });
    var browser = app.querySelector(".photo-thumbnail-browser");
    if (browser) {
      var lastWheelStep = -Infinity;
      var lastWheelDirection = 0;
      browser.addEventListener("wheel", function (event) {
        if (event.ctrlKey) return;
        var delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
        if (!delta) return;
        event.preventDefault();
        event.stopPropagation();
        var direction = delta > 0 ? 1 : -1;
        var now = performance.now();
        // Trackpads send many events per gesture; step at a readable pace.
        if (direction === lastWheelDirection && now - lastWheelStep < 160) return;
        lastWheelStep = now;
        lastWheelDirection = direction;
        scrollThumbnails(direction * 3);
      }, { passive: false });
    }
    var list = app.querySelector(".photo-thumbnail-list");
    if (list) list.addEventListener("scroll", function () {
      rememberThumbnailViewport();
      scheduleThumbnailRequest();
    }, { passive: true });
    observePhotoThumbnails();
  }

  function bindEvents() {
    var sidebarToggle = app.querySelector('.sidebar-collapse-toggle');
    if (sidebarToggle) sidebarToggle.addEventListener('click', function () {
      state.sidebarCollapsed = !state.sidebarCollapsed;
      localStorage.setItem('photoStyle.sidebarCollapsed', String(state.sidebarCollapsed));
      app.querySelector('.home-workspace').classList.toggle('sidebar-collapsed', state.sidebarCollapsed);
      sidebarToggle.setAttribute('aria-expanded', String(!state.sidebarCollapsed));
      sidebarToggle.setAttribute('aria-label', state.sidebarCollapsed ? L.text('展開底片收藏') : L.text('收合底片收藏'));
      fitPreviewImage();
      scheduleThumbnailRequest();
    });
    bindRepositoryEvents();
    bindPhotoDirectoryEvents();
    app.querySelectorAll("[data-toggle-film]").forEach(function (input) {
      input.addEventListener("change", function () {
        if (!photoIsBusy(state)) toggleStyleEnabled(input.dataset.toggleFilm);
        render();
      });
    });
    app.querySelectorAll("[data-film-family]").forEach(function (button) {
      button.addEventListener("click", function () { state.filmFamily = button.dataset.filmFamily; render(); });
    });
    var filmSearch = app.querySelector("#filmSearch");
    if (filmSearch) {
      filmSearch.addEventListener("compositionstart", function () { isComposingFilmQuery = true; });
      filmSearch.addEventListener("input", function (event) {
        state.filmQuery = filmSearch.value;
        if (!event.isComposing) render();
      });
      filmSearch.addEventListener("compositionend", function () {
        isComposingFilmQuery = false; state.filmQuery = filmSearch.value; render();
      });
    }
    var generation = photoEditGeneration;
    app.querySelectorAll("[data-page]").forEach(function (button) {
      button.addEventListener("click", function () {
        flushPhotoEdits();
        discardPendingPhotoEdits();
        state.page = button.dataset.page;
        render();
      });
    });

    app.querySelectorAll("[data-action]").forEach(function (button) {
      button.addEventListener("click", function () {
        if (button.dataset.action === "retryPreview") {
          // 使用者要求重試時，相同的資料 URL 也要重新解碼。
          var failedPreview = app.querySelector(".preview-image");
          if (failedPreview) failedPreview._requestedPreviewSource = null;
        }
        if (button.dataset.action === "exportCustomFilm") {
          if (!photoIsBusy(state)) post("exportCustomFilm", { id: button.dataset.filmId });
          return;
        }
        if (button.dataset.action === "deleteCustomFilm") {
          if (photoIsBusy(state)) return;
          flushPhotoEdits("deleteCustomFilm", { id: button.dataset.filmId });
          discardPendingPhotoEdits();
          return;
        }
        if (button.dataset.action === "resetAdjustments") {
          if (!state.hasImage || photoIsBusy(state)) return;
          discardPendingPhotoEdits();
          state.cropEditing = false;
          post("resetAdjustments", { style: state.selectedStyle });
          render();
          return;
        }
        if (["saveCustomFilm", "undoEdit", "redoEdit", "applyStyle", "saveImage", "browseFiles", "browsePhotoDirectory", "importColorCalibration", "clearColorCalibration"].indexOf(button.dataset.action) >= 0) {
          flushPhotoEdits(button.dataset.action);
          discardPendingPhotoEdits();
          render();
          return;
        }
        post(button.dataset.action);
      });
    });

    app.querySelectorAll("[data-zoom]").forEach(function (button) {
      button.addEventListener("click", function () { window.handleDesktopCommand(button.dataset.zoom); });
    });
    bindCropEditor();
    bindPreviewGestures();
    bindWhiteBalancePicker();
    repairBrush.bind();
    var previewMenuFrame = app.querySelector(".preview-frame");
    if (previewMenuFrame) previewMenuFrame.addEventListener("contextmenu", function (event) {
      event.preventDefault();
      cancelPreviewGesture();
      post("showPreviewMenu");
    });
    var closeHistogram = app.querySelector('[data-close-histogram]');
    if (closeHistogram) closeHistogram.addEventListener('click', function () {
      state.histogramVisible = false;
      app.querySelector('.preview-histogram').hidden = true;
    });
    bindPreviewFeedback();

    app.querySelectorAll("[data-style]").forEach(function (button) {
      button.addEventListener("pointerdown", function (event) {
        if (photoIsBusy(state) || event.button !== 0 || event.target.closest("button,input,label,a,select,textarea")) return;
        hideTooltip();
        var grid = button.closest(".style-grid");
        styleDrag = {
          button: button,
          grid: grid,
          pointerId: event.pointerId,
          startX: event.clientX,
          startY: event.clientY,
          moved: false
        };
        if (button.setPointerCapture && event.pointerId != null) {
          button.setPointerCapture(event.pointerId);
        }
      });
      button.addEventListener("pointermove", function (event) {
        if (!styleDrag || styleDrag.button !== button) return;
        var dx = event.clientX - styleDrag.startX;
        var dy = event.clientY - styleDrag.startY;
        if (!styleDrag.moved && Math.hypot(dx, dy) < 10) return;

        var grid = styleDrag.grid || button.closest(".style-grid");
        if (!grid) return;
        styleDrag.moved = true;
        event.preventDefault();
        button.classList.add("dragging");
        grid.classList.add("drag-active");

        var nextSibling = null;
        Array.prototype.some.call(grid.querySelectorAll("[data-style-card]"), function (card) {
          if (card === button) return false;
          var rect = card.getBoundingClientRect();
          if (event.clientY < rect.top || (event.clientY <= rect.bottom && event.clientX < rect.left + rect.width / 2)) {
            nextSibling = card;
            return true;
          }
          return false;
        });

        if (nextSibling) {
          grid.insertBefore(button, nextSibling);
        } else {
          grid.appendChild(button);
        }
      });
      button.addEventListener("pointerup", function () {
        if (!styleDrag || styleDrag.button !== button) return;
        var didMove = styleDrag.moved;
        var grid = styleDrag.grid || button.closest(".style-grid");
        button.classList.remove("dragging");
        if (grid) grid.classList.remove("drag-active");
        styleDrag = null;
        if (didMove) {
          button.dataset.dragCompleted = "true";
          if (grid) {
            persistStyleOrder(Array.prototype.map.call(grid.querySelectorAll("[data-style-card]"), function (card) {
              return card.dataset.styleCard;
            }));
          }
        }
      });
      button.addEventListener("pointercancel", function () {
        if (styleDrag && styleDrag.button === button) {
          var grid = styleDrag.grid || button.closest(".style-grid");
          button.classList.remove("dragging");
          if (grid) grid.classList.remove("drag-active");
          styleDrag = null;
        }
      });
    });

    app.querySelectorAll("[data-toggle-style]").forEach(function (input) {
      input.addEventListener("change", function () {
        if (photoIsBusy(state)) return;
        toggleStyleEnabled(input.dataset.toggleStyle);
        render();
      });
    });

    app.querySelectorAll("[data-edit-style-prompt]").forEach(function (button) {
      button.addEventListener("pointerdown", function (event) {
        event.stopPropagation();
      });
      button.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
        state.promptDialog = { open: true, styleID: button.dataset.editStylePrompt };
        render();
      });
    });

    app.querySelectorAll("[data-prompt-dialog-close]").forEach(function (element) {
      element.addEventListener("click", function (event) {
        if (event.target !== element && element.classList.contains("prompt-dialog-backdrop")) return;
        state.promptDialog = { open: false, styleID: null };
        render();
      });
    });

    app.querySelectorAll("[data-prompt-save]").forEach(function (button) {
      button.addEventListener("click", function () {
        var editor = app.querySelector("#promptEditorText");
        post("updateStylePrompt", { style: button.dataset.promptSave, language: languageKey(), prompt: editor ? editor.value : "" });
        state.promptDialog = { open: false, styleID: null };
        render();
      });
    });

    app.querySelectorAll("[data-prompt-reset]").forEach(function (button) {
      button.addEventListener("click", function () {
        var editor = app.querySelector("#promptEditorText");
        if (editor) editor.value = editor.dataset.defaultPrompt || "";
        post("resetStylePrompt", { style: button.dataset.promptReset, language: languageKey() });
        state.promptDialog = { open: false, styleID: null };
        render();
      });
    });

    app.querySelectorAll("[data-select-style]").forEach(function (button) {
      button.addEventListener("click", function () {
        if (photoIsBusy(state)) return;
        setCurrentStyle(button.dataset.selectStyle, true);
        render();
      });
    });

    app.querySelectorAll("[data-adjustment-mode]").forEach(function (button) {
      button.addEventListener("click", function () {
        if (state.adjustmentMode === button.dataset.adjustmentMode) return;
        flushPhotoEdits();
        state.adjustmentMode = button.dataset.adjustmentMode;
        var panels = adjustmentPanelsByMode[state.adjustmentMode];
        var activePanel = panels.some(function (panel) { return panel[0] === state.activeAdjustmentPanel; })
          ? state.activeAdjustmentPanel : panels[0][0];
        selectAdjustmentPanel(activePanel);
        render();
      });
    });

    app.querySelectorAll("[data-adjustment-panel]").forEach(function (button) {
      button.addEventListener("click", function () {
        flushPhotoEdits();
        selectAdjustmentPanel(button.dataset.adjustmentPanel);
        render();
      });
    });

    app.querySelectorAll("[data-film-disclosure]").forEach(function (details) {
      details.addEventListener("toggle", function () {
        if (details.isConnected) filmDisclosureState[details.dataset.filmDisclosure] = details.open;
      });
    });

    app.querySelectorAll('[data-reset-adjustment]').forEach(function (row) {
      row.addEventListener('dblclick', function (event) {
        var input = row.querySelector('[data-adjustment]');
        var defaults = state.adjustmentDefaults || {};
        var key = row.dataset.resetAdjustment;
        var value = defaults[key];
        if (key === 'vignetteBalance') value = vignetteBalance(defaults);
        var plan = /^(highlight|midtone|shadow)Plan(.+)$/.exec(key);
        if (plan) {
          var zone = { highlight: 'highlights', midtone: 'midtones', shadow: 'shadows' }[plan[1]];
          var field = plan[2].charAt(0).toLowerCase() + plan[2].slice(1);
          value = ((defaults.sourceToneZones || {})[zone] || {})[field] || 0;
        }
        if (!input || input.disabled || !row.isConnected || generation !== photoEditGeneration || photoIsBusy(state) || !state.hasImage || typeof value !== 'number') return;
        event.preventDefault();
        event.stopPropagation();
        hideTooltip();
        flushLiveAdjustment();
        endLiveAdjustment();
        input.value = value;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      });
    });

    app.querySelectorAll("[data-adjustment]").forEach(function (input) {
      updateRangeVisual(input);
      input.addEventListener("keydown", function (event) {
        if (input.disabled || !input.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
        var direction = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[event.key];
        if (!direction) return;
        event.preventDefault();
        input.value = Number(input.value) + direction * Number(input.dataset.rangeStep || 1);
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      input.addEventListener("pointerdown", function () {
        if (input.disabled || !input.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
        beginLiveAdjustment();
      });
      input.addEventListener("input", function () {
        if (input.disabled || !input.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
        var key = input.dataset.adjustment;
        var label = app.querySelector('[data-value-label="' + key + '"]');
        var value = normalizeRangeInput(input);
        beginLiveAdjustment();
        updateRangeVisual(input);
        if (label) label.textContent = formatRangeValue(input, value);
        updateLocalAdjustment(key, value);
        scheduleLiveAdjustment(key, value);
      });
      input.addEventListener("change", function () {
        if (input.disabled || !input.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
        var key = input.dataset.adjustment;
        var value = normalizeRangeInput(input);
        beginLiveAdjustment();
        var label = app.querySelector('[data-value-label="' + key + '"]');
        if (label) label.textContent = formatRangeValue(input, value);
        updateRangeVisual(input);
        updateLocalAdjustment(key, value);
        pendingLiveAdjustment = { style: state.selectedStyle, key: key, value: value, generation: photoEditGeneration };
        flushLiveAdjustment();
        endLiveAdjustment();
      });
    });

    app.querySelectorAll("[data-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        var adjustment = currentAdjustment();
        var key = button.dataset.toggle;
        var next = !adjustment[key];
        adjustment[key] = next;
        updateLocalAdjustment(key, next);
        post("updateAdjustment", { style: state.selectedStyle, key: key, value: next });
        render();
      });
    });

    app.querySelectorAll("[data-select]").forEach(function (select) {
      select.addEventListener("change", function () {
        if (select.disabled || !select.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
        var key = select.dataset.select;
        if (key === "cropAspectRatio" && select.value === "original") {
          cancelCropEditing();
          return;
        }
        if (key === "cropAspectRatio") beginCropEditing();
        updateLocalAdjustment(key, select.value);
        if (key === "cropAspectRatio") {
          state.cropEditing = select.value !== "original";
          var cropValues = { cropAspectRatio: select.value, cropScale: 100,
            cropWidth: 100, cropHeight: 100, cropHorizontalPosition: 0, cropVerticalPosition: 0 };
          updateLocalCropValues(cropValues);
          scheduleCropAdjustment(cropValues);
          if (!state.cropEditing) flushCropAdjustment();
          resetPreviewZoom();
        } else {
          post("updateAdjustment", { style: state.selectedStyle, key: key, value: select.value });
        }
        render();
      });
    });

    app.querySelectorAll("[data-crop-edit]").forEach(function (button) {
      button.addEventListener("click", function () {
        beginCropEditing();
        state.cropEditing = true;
        resetPreviewZoom();
        render();
      });
    });

    app.querySelectorAll("[data-crop-cancel]").forEach(function (button) {
      button.addEventListener("click", cancelCropEditing);
    });
    app.querySelectorAll("[data-crop-done]").forEach(function (button) {
      button.addEventListener("click", function () {
        state.cropEditing = false;
        flushCropAdjustment();
        resetPreviewZoom();
        render();
      });
    });

    app.querySelectorAll("[data-preview-original]").forEach(function (button) {
      var showOriginal = function (event) {
        event.preventDefault();
        setPreviewImageSource(true);
        if (button.setPointerCapture && event.pointerId != null) {
          button.setPointerCapture(event.pointerId);
        }
      };
      var showStyled = function (event) {
        if (event) event.preventDefault();
        setPreviewImageSource(false);
      };

      button.addEventListener("pointerdown", showOriginal);
      button.addEventListener("pointerup", showStyled);
      button.addEventListener("pointercancel", showStyled);
      button.addEventListener("pointerleave", showStyled);
      button.addEventListener("lostpointercapture", showStyled);
      button.addEventListener("contextmenu", function (event) { event.preventDefault(); });
      button.addEventListener("keydown", function (event) {
        if (event.key === " " || event.key === "Enter") {
          showOriginal(event);
        }
      });
      button.addEventListener("keyup", function (event) {
        if (event.key === " " || event.key === "Enter") {
          showStyled(event);
        }
      });
    });

    var modelPicker = app.querySelector("[data-model-picker]");
    if (modelPicker) {
      // With no placeholder option, leave an unset native selection empty instead
      // of allowing the browser to claim the first model is already selected.
      modelPicker.value = state.ai.selectedModelID || "";
      modelPicker.addEventListener("change", function () {
        var choice = (state.ai.modelChoices || []).find(function (model) { return model.id === modelPicker.value; });
        modelPicker.value = state.ai.selectedModelID || "";
        if (!modelPicker.isConnected || modelOperationIsBusy() || !choice || !choice.ready) return;
        post("selectModel", { id: choice.id });
      });
    }

    var mcpToggle = app.querySelector("#mcpEnabledToggle");
    if (mcpToggle) mcpToggle.addEventListener("click", function () {
      post("setMCPEnabled", { enabled: !state.mcp.enabled });
    });

    var appearanceSelect = document.getElementById("appearanceSelect");
    if (appearanceSelect) {
      appearanceSelect.addEventListener("change", function () {
        setAppearance(appearanceSelect.value);
        render();
      });
    }

    var languageSelect = document.getElementById("languageSelect");
    if (languageSelect) {
      languageSelect.addEventListener("change", function () {
        state.language = languageSelect.value;
        localStorage.setItem("photoStyle.language", state.language);
        post("setLanguage", { language: languageKey(), preference: state.language });
        render();
      });
    }

    var showHelpToggle = document.getElementById("showHelpToggle");
    if (showHelpToggle) showHelpToggle.addEventListener("click", function () {
      state.showHelp = !state.showHelp;
      localStorage.setItem("photoStyle.showHelp", String(state.showHelp));
      hideTooltip();
      render();
    });

    var originalResolutionToggle = document.getElementById("originalResolutionToggle");
    if (originalResolutionToggle) {
      originalResolutionToggle.addEventListener("click", function () {
        if (photoIsBusy(state)) return;
        state.originalResolutionEditing = state.originalResolutionEditing === false;
        post("setOriginalResolutionEditing", { enabled: state.originalResolutionEditing });
        render();
      });
    }

    var hdrFeatureToggle = document.getElementById("hdrFeatureToggle");
    if (hdrFeatureToggle) {
      hdrFeatureToggle.addEventListener("click", function () {
        state.hdrFeatureEnabled = state.hdrFeatureEnabled === false;
        post("setHDRFeatureEnabled", { enabled: state.hdrFeatureEnabled });
        render();
      });
    }
  }

  function beginCropEditing() {
    if (cropEditSnapshot) return;
    var adjustment = currentAdjustment();
    cropEditSnapshot = {};
    ["cropAspectRatio", "cropRotation", "cropScale", "cropWidth", "cropHeight", "cropHorizontalPosition", "cropVerticalPosition"].forEach(function (key) {
      cropEditSnapshot[key] = adjustment[key] == null ? (key === "cropRotation" ? 0 : adjustment[key]) : adjustment[key];
    });
  }

  function cancelCropEditing() {
    if (cropEditSnapshot) updateLocalCropValues(cropEditSnapshot);
    cropEditSnapshot = null;
    pendingCropValues = pendingCropStyle = null;
    cropGesture = null;
    isDraggingCrop = false;
    state.cropEditing = false;
    resetPreviewZoom();
    render();
  }

  function bindCropEditor() {
    var box = app.querySelector("[data-crop-box]");
    if (!box || !isCropEditorVisible(currentAdjustment())) return;
    var generation = photoEditGeneration;

    box.addEventListener("pointerdown", function (event) {
      if (event.button !== 0 || !previewFit || !box.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
      var rotationHandle = event.target.closest("[data-crop-rotate]");
      var handle = event.target && event.target.closest
        ? event.target.closest("[data-crop-handle]")
        : null;
      var moveSurface = event.target && event.target.closest
        ? event.target.closest("[data-crop-move]")
        : null;
      if (!handle && !moveSurface && !rotationHandle) return;

      event.preventDefault();
      event.stopPropagation();
      isDraggingCrop = true;
      document.body.classList.add("preview-gesture-active");
      var geometry = cropGeometry(currentAdjustment());
      cropGesture = {
        mode: rotationHandle ? "rotate" : (handle ? "resize" : "move"),
        startRotation: currentAdjustment().cropRotation || 0,
        centerX: box.getBoundingClientRect().left + box.clientWidth / 2,
        centerY: box.getBoundingClientRect().top + box.clientHeight / 2,
        handle: handle ? handle.dataset.cropHandle : null,
        pointerId: event.pointerId,
        startClientX: event.clientX,
        startClientY: event.clientY,
        geometry: geometry
      };
      box.classList.toggle("is-rotating", !!rotationHandle);
      if (box.setPointerCapture && event.pointerId != null) {
        box.setPointerCapture(event.pointerId);
      }
    });

    box.addEventListener("pointermove", function (event) {
      if (!box.isConnected || generation !== photoEditGeneration || photoIsBusy(state)) return;
      if (!cropGesture || cropGesture.pointerId !== event.pointerId) return;
      event.preventDefault();
      var values = cropGesture.mode === "rotate" ? cropRotateValues(event, cropGesture)
        : cropGesture.mode === "move" ? cropMoveValues(event, cropGesture) : cropResizeValues(event, cropGesture);
      updateLocalCropValues(values);
      updateCropEditorLayout();
      scheduleCropAdjustment(values);
    });

    var finishCropGesture = function (event) {
      if (!box.isConnected || generation !== photoEditGeneration) return;
      if (!cropGesture || cropGesture.pointerId !== event.pointerId) return;
      event.preventDefault();
      cropGesture = null;
      box.classList.remove("is-rotating");
      isDraggingCrop = false;
      document.body.classList.remove("preview-gesture-active");
      // Commit once when the crop editor is completed, not after every drag.
    };

    box.querySelectorAll("[data-crop-rotate]").forEach(function (zone) {
      zone.addEventListener("keydown", function (event) {
        var direction = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1 }[event.key];
        if (!direction || photoIsBusy(state)) return;
        event.preventDefault();
        var values = { cropRotation: roundedCropValue(clamp((currentAdjustment().cropRotation || 0) + direction * (event.shiftKey ? 1 : 0.1), -45, 45)) };
        updateLocalCropValues(values);
        scheduleCropAdjustment(values);
        updateCropEditorLayout();
      });
    });
    var rotationReset = app.querySelector("[data-crop-rotation-reset]");
    if (rotationReset) rotationReset.addEventListener("click", function () {
      if (photoIsBusy(state)) return;
      updateLocalCropValues({ cropRotation: 0 });
      scheduleCropAdjustment({ cropRotation: 0 });
      updateCropEditorLayout();
    });
    box.addEventListener("pointerup", finishCropGesture);
    box.addEventListener("pointercancel", finishCropGesture);
    box.addEventListener("lostpointercapture", finishCropGesture);
    box.addEventListener("contextmenu", function (event) { event.preventDefault(); });
  }

  function cropRotateValues(event, gesture) {
    var start = Math.atan2(gesture.startClientY - gesture.centerY, gesture.startClientX - gesture.centerX);
    var now = Math.atan2(event.clientY - gesture.centerY, event.clientX - gesture.centerX);
    var delta = Math.atan2(Math.sin(now - start), Math.cos(now - start)) * 180 / Math.PI;
    var value = clamp(gesture.startRotation + delta, -45, 45);
    return { cropRotation: event.shiftKey ? Math.round(value) : roundedCropValue(value) };
  }

  function cropMoveValues(event, gesture) {
    var geometry = gesture.geometry;
    var dx = (event.clientX - gesture.startClientX) / Math.max(previewFit.baseWidth, 1);
    var dy = (event.clientY - gesture.startClientY) / Math.max(previewFit.baseHeight, 1);
    var x = clamp(geometry.x + dx, 0, 1 - geometry.width);
    var y = clamp(geometry.y + dy, 0, 1 - geometry.height);
    return cropPositionValues(x, y, geometry.width, geometry.height);
  }

  function cropResizeValues(event, gesture) {
    var geometry = gesture.geometry;
    var point = cropPointerUnit(event);
    var handle = gesture.handle || "se";
    var usesWest = handle.indexOf("w") >= 0;
    var usesNorth = handle.indexOf("n") >= 0;
    var adjustment = currentAdjustment();

    if ((adjustment.cropAspectRatio || "original") === "free") {
      var left = geometry.x;
      var top = geometry.y;
      var right = geometry.x + geometry.width;
      var bottom = geometry.y + geometry.height;
      if (usesWest) left = clamp(point.x, 0, right - 0.2);
      else right = clamp(point.x, left + 0.2, 1);
      if (usesNorth) top = clamp(point.y, 0, bottom - 0.2);
      else bottom = clamp(point.y, top + 0.2, 1);
      var width = right - left;
      var height = bottom - top;
      return Object.assign({
        cropWidth: roundedCropValue(width * 100),
        cropHeight: roundedCropValue(height * 100)
      }, cropPositionValues(left, top, width, height));
    }

    var oppositeX = usesWest ? geometry.x + geometry.width : geometry.x;
    var oppositeY = usesNorth ? geometry.y + geometry.height : geometry.y;
    var widthScale = Math.abs(point.x - oppositeX) / Math.max(geometry.baseWidth, 0.0001);
    var heightScale = Math.abs(point.y - oppositeY) / Math.max(geometry.baseHeight, 0.0001);
    var scale = clamp(Math.min(widthScale, heightScale), 0.2, 1);
    var nextWidth = geometry.baseWidth * scale;
    var nextHeight = geometry.baseHeight * scale;
    var nextX = usesWest ? oppositeX - nextWidth : oppositeX;
    var nextY = usesNorth ? oppositeY - nextHeight : oppositeY;
    nextX = clamp(nextX, 0, 1 - nextWidth);
    nextY = clamp(nextY, 0, 1 - nextHeight);
    return Object.assign({ cropScale: roundedCropValue(scale * 100) }, cropPositionValues(
      nextX,
      nextY,
      nextWidth,
      nextHeight
    ));
  }

  function cropPointerUnit(event) {
    var frame = app.querySelector(".preview-frame");
    if (!frame || !previewFit) return { x: 0.5, y: 0.5 };
    var frameRect = frame.getBoundingClientRect();
    var imageLeft = (previewFit.frameWidth - previewFit.baseWidth) / 2;
    var imageTop = (previewFit.frameHeight - previewFit.baseHeight) / 2;
    return {
      x: clamp((event.clientX - frameRect.left - imageLeft) / Math.max(previewFit.baseWidth, 1), 0, 1),
      y: clamp((event.clientY - frameRect.top - imageTop) / Math.max(previewFit.baseHeight, 1), 0, 1)
    };
  }

  function cropPositionValues(x, y, width, height) {
    var availableX = Math.max(0, 1 - width);
    var availableY = Math.max(0, 1 - height);
    return {
      cropHorizontalPosition: roundedCropValue(availableX > 0.0001 ? (x / availableX * 2 - 1) * 100 : 0),
      cropVerticalPosition: roundedCropValue(availableY > 0.0001 ? (y / availableY * 2 - 1) * 100 : 0)
    };
  }

  function roundedCropValue(value) {
    return Math.round(value * 10) / 10;
  }

  function updateLocalCropValues(values) {
    var nextAdjustments = Object.assign({}, state.adjustments || {});
    var current = Object.assign({}, nextAdjustments[state.selectedStyle] || currentAdjustment(), values || {});
    nextAdjustments[state.selectedStyle] = current;
    state.adjustments = nextAdjustments;
  }

  function scheduleCropAdjustment(values) {
    if (pendingCropStyle !== state.selectedStyle) pendingCropValues = null;
    pendingCropStyle = state.selectedStyle;
    pendingCropGeneration = photoEditGeneration;
    pendingCropValues = Object.assign({}, pendingCropValues || {}, values || {});
    // Crop gestures are local until Done or another action commits the photo.
  }

  function flushCropAdjustment() {
    cropEditSnapshot = null;
    if (cropUpdateTimer) {
      clearTimeout(cropUpdateTimer);
      cropUpdateTimer = null;
    }
    if (!pendingCropValues) return;
    var payload = { style: pendingCropStyle, cropValues: pendingCropValues };
    var generation = pendingCropGeneration;
    pendingCropValues = null;
    pendingCropStyle = null;
    if (generation === photoEditGeneration && !photoIsBusy(state)) post("updateAdjustment", payload);
  }

  function bindPreviewFeedback() {
    var image = app.querySelector(".preview-image");
    if (image && !image._feedbackBound) {
      image._feedbackBound = true;
      ["load", "error"].forEach(function (event) {
        image.addEventListener(event, function () {
          if (!image.isConnected) return;
          image._previewError = event === "error";
          updatePreviewFeedback();
        });
      });
    }
    updatePreviewFeedback();
  }

  function updatePreviewFeedback() {
    var frame = app.querySelector(".preview-frame");
    var feedback = app.querySelector("[data-preview-feedback]");
    if (!frame || !feedback) return;
    var image = frame.querySelector(".preview-image");
    var processing = state.isLoadingImage || state.isRenderingPreview;
    var decoding = !!image && (!image.complete || !!image._pendingPreviewDecode);
    var ready = !!image && image.complete && image.naturalWidth > 0;
    if (ready) image._hasDisplayedPreview = true;
    if (ready && isCropEditorVisible(currentAdjustment())) {
      feedback.hidden = true;
      frame.setAttribute("aria-busy", "false");
      image.style.visibility = "";
      return;
    }
    var retainedPreview = !!image && !!image._hasDisplayedPreview;
    var placeholder = frame.querySelector(".preview-loading-image");
    if (placeholder) placeholder.hidden = ready || retainedPreview;
    var previewVisible = ready || retainedPreview || (!!placeholder && placeholder.complete && placeholder.naturalWidth > 0);
    var failed = !processing && !decoding && ((!!image && (!ready || image._previewError)) || (state.hasImage && !state.outputImage));
    var active = processing || decoding;
    frame.setAttribute("aria-busy", active ? "true" : "false");
    feedback.hidden = !active && !failed;
    feedback.classList.toggle("is-compact", previewVisible && !failed);
    feedback.classList.toggle("is-error", failed);
    feedback.querySelector(".preview-spinner").hidden = failed;
    feedback.querySelector("[data-action=retryPreview]").hidden = !failed;
    var title = failed ? L.text("無法顯示照片預覽") : state.isLoadingImage ? L.text("正在載入照片") :
      state.isRenderingPreview ? (state.originalResolutionEditing !== false ? L.text("正在處理原始照片") : L.text("正在更新預覽")) : L.text("正在顯示照片");
    feedback.querySelector("[data-preview-feedback-title]").textContent = title;
    feedback.querySelector("[data-preview-feedback-detail]").textContent = failed ? L.text("請重新載入預覽。") :
      state.isRenderingPreview && state.originalResolutionEditing !== false ? L.text("原始解析度處理需要一些時間，請稍候。") : L.text("請稍候…");
    if (image) image.style.visibility = ready || retainedPreview ? "" : "hidden";
    var status = app.querySelector(".preview-status");
    if (status) status.textContent = failed ? L.text("預覽顯示失敗") : decoding && !processing ? L.text("正在顯示照片") : previewStatusText();
  }

  window.handlePreviewMenu = function (payload) {
    var command = payload.command;
    if (!state.hasImage || photoIsBusy(state)) return;
    if (command === 'histogram') {
      state.histogramVisible = true;
      updatePreviewHistogram();
    } else if (command === 'source' || command === 'free') {
      var select = app.querySelector('#previewCropAspectRatio');
      if (select) { select.value = command; select.dispatchEvent(new Event('change', { bubbles: true })); }
    } else {
      var button = app.querySelector('[data-action="' + command + '"]');
      if (button && !button.disabled) button.click();
    }
  };

  function bindWhiteBalancePicker() {
    var button = app.querySelector('[data-white-balance-picker]');
    var frame = app.querySelector('.preview-frame');
    if (!button || !frame) return;
    if (button.disabled) state.whiteBalancePicking = false;
    function refresh() {
      button.setAttribute('aria-pressed', String(state.whiteBalancePicking));
      frame.classList.toggle('white-balance-picking', state.whiteBalancePicking);
    }
    refresh();
    button.addEventListener('click', function () {
      cancelPreviewGesture();
      state.whiteBalancePicking = !state.whiteBalancePicking;
      refresh();
    });
    frame.addEventListener('pointerdown', function (event) {
      if (!state.whiteBalancePicking || event.button !== 0 || event.target.closest('.preview-histogram,[data-preview-original]')) return;
      event.preventDefault(); event.stopImmediatePropagation();
      var image = frame.querySelector('.preview-image');
      if (!image || !image.complete || !image.naturalWidth || image._pendingPreviewDecode ||
          state.isRenderingPreview || photoIsBusy(state) || pendingLiveAdjustment || adjustmentInteraction ||
          pendingStyleSelection || (image.currentSrc || image.src) !== state.outputImage) return;
      var rect = image.getBoundingClientRect();
      var x = (event.clientX - rect.left) / rect.width;
      var y = (event.clientY - rect.top) / rect.height;
      if (x < 0 || x >= 1 || y < 0 || y >= 1) return;
      var sample = document.createElement('canvas'); sample.width = sample.height = 5;
      var context = sample.getContext('2d', { colorSpace: 'srgb', willReadFrequently: true });
      var sx = Math.max(0, Math.min(image.naturalWidth - 1, Math.floor(x * image.naturalWidth) - 2));
      var sy = Math.max(0, Math.min(image.naturalHeight - 1, Math.floor(y * image.naturalHeight) - 2));
      var width = Math.min(5, image.naturalWidth - sx), height = Math.min(5, image.naturalHeight - sy);
      context.drawImage(image, sx, sy, width, height, 0, 0, width, height);
      var pixels = context.getImageData(0, 0, width, height).data;
      var rgb = [0, 0, 0];
      for (var i = 0; i < pixels.length; i += 4) for (var c = 0; c < 3; c++) rgb[c] += pixels[i + c] / (255 * width * height);
      state.whiteBalancePicking = false; refresh();
      flushPhotoEdits();
      post('sampleWhiteBalance', { rgb: rgb, photoGeneration: state.photoGeneration,
        previewRevision: state.previewRevision, style: state.selectedStyle, customFilmID: state.selectedCustomFilmID });
    }, true);
  }

  function rgbHistogramBins(pixels) {
    var channels = [new Uint32Array(256), new Uint32Array(256), new Uint32Array(256)];
    for (var i = 0; i < pixels.length; i += 4) {
      if (!pixels[i + 3]) continue;
      for (var c = 0; c < 3; c++) channels[c][pixels[i + c]]++;
    }
    return channels;
  }

  function updatePreviewHistogram() {
    var panel = app.querySelector('.preview-histogram');
    if (!panel) return;
    panel.hidden = !state.histogramVisible || isCropEditorVisible(currentAdjustment());
    if (panel.hidden) return;
    var image = app.querySelector('.preview-image');
    var canvas = panel.querySelector('canvas');
    if (!image || !image.complete || !image.naturalWidth) return;
    var source = image.currentSrc || image.src;
    if (canvas._histogramSource === source) return;
    var sample = document.createElement('canvas');
    // Count actual preview pixels; resizing first blends distinct 8-bit levels.
    sample.width = image.naturalWidth;
    sample.height = image.naturalHeight;
    try {
      var context = sample.getContext('2d', { willReadFrequently: true, colorSpace: 'srgb', colorType: 'unorm8' });
      context.drawImage(image, 0, 0, sample.width, sample.height);
      // The preview is already display-mapped sRGB. Read unsigned 8-bit values
      // explicitly, without a second gamma conversion or per-photo stretching.
      var pixels = context.getImageData(0, 0, sample.width, sample.height, {
        colorSpace: 'srgb', pixelFormat: 'rgba-unorm8'
      }).data;
      var channels = rgbHistogramBins(pixels);
      var peak = Math.max(1, ...channels.map(function (bins) { return Math.max(...bins); }));
      var graph = canvas.getContext('2d');
      graph.clearRect(0, 0, 256, 100);
      graph.globalCompositeOperation = 'source-over';
      graph.strokeStyle = 'rgba(255,255,255,.12)';
      [64, 128, 192].forEach(function (x) { graph.beginPath(); graph.moveTo(x, 0); graph.lineTo(x, 100); graph.stroke(); });
      graph.globalCompositeOperation = 'screen';
      ['#ff5252', '#53dc77', '#559cff'].forEach(function (color, c) {
        graph.beginPath(); graph.moveTo(0, 100);
        for (var x = 0; x < 256; x++) graph.lineTo(x, 99 - channels[c][x] / peak * 94);
        graph.lineTo(255, 100); graph.closePath();
        graph.fillStyle = color; graph.globalAlpha = 0.25; graph.fill();
        graph.globalAlpha = 1; graph.strokeStyle = color; graph.lineWidth = 1; graph.stroke();
      });
      graph.globalCompositeOperation = 'source-over';
      canvas._histogramSource = source;
    } catch (_) {
      canvas._histogramSource = null;
      panel.hidden = true;
    }
  }

  function bindPreviewGestures() {
    if (isCropEditorVisible(currentAdjustment())) return;
    var frame = app.querySelector(".preview-frame");
    var image = app.querySelector(".preview-image");
    if (!frame || !image) return;

    var isPreviewControl = function (event) {
      return event.target && event.target.closest && event.target.closest("[data-preview-original], .preview-histogram");
    };
    var lockPreviewScroll = function () {
      document.body.classList.add("preview-gesture-active");
    };
    var unlockPreviewScroll = function () {
      if (previewPointers.size === 0) {
        document.body.classList.remove("preview-gesture-active");
      }
    };
    var rememberPointer = function (event) {
      previewPointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    };

    frame.addEventListener("wheel", function (event) {
      event.preventDefault();
      if (previewPointers.size || !event.deltaY) return;
      // Normalize mouse wheels and trackpads to pixels; zoom around the cursor.
      var unit = event.deltaMode === 1 ? 16 : (event.deltaMode === 2 ? frame.clientHeight : 1);
      var delta = clamp(event.deltaY * unit, -240, 240);
      setPreviewScaleAt(previewTransform.scale * Math.exp(-delta * 0.003), event.clientX, event.clientY);
    }, { passive: false });
    var gestureScale = 1;
    frame.addEventListener("gesturestart", function (event) {
      event.preventDefault();
      gestureScale = previewTransform.scale;
    }, { passive: false });
    frame.addEventListener("gesturechange", function (event) {
      event.preventDefault();
      var rect = frame.getBoundingClientRect();
      setPreviewScaleAt(gestureScale * event.scale, event.clientX || rect.left + rect.width / 2, event.clientY || rect.top + rect.height / 2);
    }, { passive: false });

    frame.addEventListener("pointerdown", function (event) {
      if (state.repairEditing || isPreviewControl(event) || event.button !== 0) return;
      event.preventDefault();
      lockPreviewScroll();
      rememberPointer(event);
      clearTimeout(previewHoldTimer);
      if (previewPointers.size === 1 && !state.isLoadingImage) {
        previewHoldTimer = setTimeout(function () {
          previewHoldTimer = null;
          if (!frame.isConnected || !previewGesture || previewGesture.moved || previewPointers.size !== 1) return;
          previewGesture.moved = true; // A long press must not also become a double-click zoom.
          state.histogramVisible = true;
          updatePreviewHistogram();
        }, 800);
      }
      frame.classList.toggle("is-panning", previewTransform.scale > 1);
      if (frame.setPointerCapture && event.pointerId != null) {
        frame.setPointerCapture(event.pointerId);
      }

      if (previewPointers.size === 2) {
        var points = Array.from(previewPointers.values());
        previewGesture = {
          mode: "pinch",
          distance: distanceBetween(points[0], points[1]),
          midpoint: midpointBetween(points[0], points[1]),
          scale: previewTransform.scale,
          x: previewTransform.x,
          y: previewTransform.y,
          moved: false
        };
      } else {
        previewGesture = {
          mode: "pan",
          pointerId: event.pointerId,
          startX: event.clientX,
          startY: event.clientY,
          x: previewTransform.x,
          y: previewTransform.y,
          moved: false
        };
      }
    });

    frame.addEventListener("pointermove", function (event) {
      if (!previewPointers.has(event.pointerId) || !previewGesture) return;
      event.preventDefault();
      rememberPointer(event);

      if (previewPointers.size >= 2 && previewGesture.mode === "pinch") {
        var points = Array.from(previewPointers.values()).slice(0, 2);
        var distance = distanceBetween(points[0], points[1]);
        var midpoint = midpointBetween(points[0], points[1]);
        if (previewGesture.distance <= 0) return;
        var nextScale = previewGesture.scale * (distance / previewGesture.distance);
        previewGesture.moved = true;
        setPreviewScaleAt(nextScale, midpoint.clientX, midpoint.clientY, previewGesture.scale, previewGesture.x, previewGesture.y);
        return;
      }

      if (previewGesture.mode === "pan" && previewGesture.pointerId === event.pointerId) {
        var dx = event.clientX - previewGesture.startX;
        var dy = event.clientY - previewGesture.startY;
        if (Math.hypot(dx, dy) > 4) { previewGesture.moved = true; clearTimeout(previewHoldTimer); }
        previewTransform.x = previewGesture.x + dx;
        previewTransform.y = previewGesture.y + dy;
        applyPreviewTransform();
      }
    });

    var endPointer = function (event) {
      clearTimeout(previewHoldTimer);
      if (!previewPointers.has(event.pointerId)) return;
      previewPointers.delete(event.pointerId);
      if (event.type === "pointerup" && previewGesture && previewGesture.mode === "pan" && !previewGesture.moved) {
        handlePreviewTap(event.clientX, event.clientY);
      }
      if (previewPointers.size === 1) {
        var entry = Array.from(previewPointers.entries())[0];
        var point = entry[1];
        previewGesture = {
          mode: "pan",
          pointerId: entry[0],
          startX: point.x,
          startY: point.y,
          x: previewTransform.x,
          y: previewTransform.y,
          moved: false
        };
      } else if (previewPointers.size === 0) {
        previewGesture = null;
      }
      frame.classList.toggle("is-panning", previewPointers.size > 0 && previewTransform.scale > 1);
      unlockPreviewScroll();
    };

    frame.addEventListener("pointerup", endPointer);
    frame.addEventListener("pointercancel", endPointer);
    frame.addEventListener("lostpointercapture", endPointer);
    frame.addEventListener("contextmenu", function (event) { event.preventDefault(); });
  }

  function distanceBetween(a, b) {
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  function midpointBetween(a, b) {
    return {
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      clientX: (a.x + b.x) / 2,
      clientY: (a.y + b.y) / 2
    };
  }

  function handlePreviewTap(clientX, clientY) {
    var now = Date.now();
    var close = Math.hypot(clientX - lastPreviewTap.x, clientY - lastPreviewTap.y) < 28;
    if (now - lastPreviewTap.time < 300 && close) {
      togglePreviewOneToOne(clientX, clientY);
      lastPreviewTap = { time: 0, x: 0, y: 0 };
    } else {
      lastPreviewTap = { time: now, x: clientX, y: clientY };
    }
  }

  function cancelPreviewGesture() {
    clearTimeout(previewHoldTimer);
    previewHoldTimer = null;
    var frame = app.querySelector(".preview-frame");
    var pointerIDs = Array.from(previewPointers.keys());
    previewPointers.clear();
    previewGesture = null;
    document.body.classList.remove("preview-gesture-active");
    if (!frame) return;
    frame.classList.remove("is-panning");
    pointerIDs.forEach(function (id) {
      if (frame.hasPointerCapture && frame.hasPointerCapture(id)) frame.releasePointerCapture(id);
    });
  }

  function resetPreviewZoom() {
    cancelPreviewGesture();
    previewTransform = { scale: 1, x: 0, y: 0 };
    applyPreviewTransform();
  }

  function previewScaleLimits() {
    if (!previewFit || !previewFit.baseScale) return { min: 1, max: 4, oneToOne: 1 };
    var oneToOne = Math.max(1, (previewFit.originalWidth || previewFit.naturalWidth) / previewFit.baseWidth / (window.devicePixelRatio || 1));
    return {
      min: 1,
      max: Math.max(4, oneToOne * 3),
      oneToOne: oneToOne
    };
  }

  function applyPreviewTransform() {
    var image = app.querySelector(".preview-image");
    if (!image || !previewFit) return;

    if (isCropEditorVisible(currentAdjustment())) {
      previewTransform = { scale: 1, x: 0, y: 0 };
      image.style.width = Math.round(previewFit.baseWidth) + "px";
      image.style.height = Math.round(previewFit.baseHeight) + "px";
      image.style.left = Math.round((previewFit.frameWidth - previewFit.baseWidth) / 2) + "px";
      image.style.top = Math.round((previewFit.frameHeight - previewFit.baseHeight) / 2) + "px";
      updateCropEditorLayout();
      return;
    }

    var limits = previewScaleLimits();
    previewTransform.scale = clamp(previewTransform.scale, limits.min, limits.max);
    var frame = app.querySelector(".preview-frame");
    if (frame) {
      frame.classList.toggle("is-zoomed", previewTransform.scale > limits.min);
      frame.classList.toggle("is-panning", previewPointers.size > 0 && previewTransform.scale > limits.min);
    }

    var displayWidth = previewFit.baseWidth * previewTransform.scale;
    var displayHeight = previewFit.baseHeight * previewTransform.scale;
    var maxX = Math.max(0, (displayWidth - previewFit.frameWidth) / 2);
    var maxY = Math.max(0, (displayHeight - previewFit.frameHeight) / 2);
    previewTransform.x = clamp(previewTransform.x, -maxX, maxX);
    previewTransform.y = clamp(previewTransform.y, -maxY, maxY);

    image.style.width = Math.round(displayWidth) + "px";
    image.style.height = Math.round(displayHeight) + "px";
    image.style.left = Math.round((previewFit.frameWidth - displayWidth) / 2 + previewTransform.x) + "px";
    image.style.top = Math.round((previewFit.frameHeight - displayHeight) / 2 + previewTransform.y) + "px";
  }

  function setPreviewScaleAt(nextScale, clientX, clientY, fromScale, fromX, fromY) {
    if (!previewFit) return;
    var frame = app.querySelector(".preview-frame");
    if (!frame) return;

    var limits = previewScaleLimits();
    var oldScale = fromScale || previewTransform.scale || 1;
    var oldX = fromX == null ? previewTransform.x : fromX;
    var oldY = fromY == null ? previewTransform.y : fromY;
    nextScale = clamp(nextScale, limits.min, limits.max);

    var rect = frame.getBoundingClientRect();
    var pointX = clientX - rect.left;
    var pointY = clientY - rect.top;
    var oldWidth = previewFit.baseWidth * oldScale;
    var oldHeight = previewFit.baseHeight * oldScale;
    var oldLeft = (previewFit.frameWidth - oldWidth) / 2 + oldX;
    var oldTop = (previewFit.frameHeight - oldHeight) / 2 + oldY;
    var unitX = oldWidth > 0 ? (pointX - oldLeft) / oldWidth : 0.5;
    var unitY = oldHeight > 0 ? (pointY - oldTop) / oldHeight : 0.5;
    var nextWidth = previewFit.baseWidth * nextScale;
    var nextHeight = previewFit.baseHeight * nextScale;

    previewTransform.scale = nextScale;
    previewTransform.x = pointX - unitX * nextWidth - (previewFit.frameWidth - nextWidth) / 2;
    previewTransform.y = pointY - unitY * nextHeight - (previewFit.frameHeight - nextHeight) / 2;
    applyPreviewTransform();
    repairBrush.redraw();
  }

  function togglePreviewOneToOne(clientX, clientY) {
    if (!previewFit) return;
    var limits = previewScaleLimits();
    var target = Math.abs(previewTransform.scale - limits.oneToOne) < 0.04 ? 1 : limits.oneToOne;
    setPreviewScaleAt(target, clientX, clientY);
  }

  function fitPreviewImage() {
    var frame = app.querySelector(".preview-frame");
    var image = app.querySelector(".preview-image");
    if (!frame || !image) return;
    // Partial thumbnail updates and pane reflow can resize the canvas without a
    // window resize. Keep its absolute-positioned image aligned immediately.
    if (observedPreviewFrame !== frame && window.ResizeObserver) {
      if (!previewResizeObserver) previewResizeObserver = new ResizeObserver(function () {
        fitPreviewImage();
      });
      previewResizeObserver.disconnect();
      observedPreviewFrame = frame;
      previewResizeObserver.observe(frame);
    }

    function applyFit() {
      if (!image.isConnected) return;
      var naturalWidth = image.naturalWidth || 0;
      var naturalHeight = image.naturalHeight || 0;
      if (!naturalWidth || !naturalHeight) return;

      var frameWidth = frame.clientWidth;
      var frameHeight = frame.clientHeight;
      var cropMode = isCropEditorVisible(currentAdjustment());
      var padding = 0;
      var comparingOriginal = image._requestedPreviewSource === state.sourceImage && state.sourceImage !== state.outputImage;
      var outputSize = (cropMode || state.repairEditing) ? (state.cropSourceImageSize || {}) : ((comparingOriginal ? state.sourceImageSize : state.previewOutputSize) || {});
      if (!cropMode && !state.repairEditing) outputSize = filmHoverPreview.displaySize(image.currentSrc || image.src) || outputSize;
      var geometryWidth = Number(outputSize.width) || naturalWidth;
      var geometryHeight = Number(outputSize.height) || naturalHeight;
      var scale = Math.min(
        Math.max(frameWidth - padding, 1) / geometryWidth,
        Math.max(frameHeight - padding, 1) / geometryHeight
      );
      var sourceSize = state.sourceImageSize || {};
      var originalWidth = Number(sourceSize.width) || naturalWidth;
      var originalHeight = Number(sourceSize.height) || naturalHeight;

      previewFit = {
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        naturalWidth: naturalWidth,
        naturalHeight: naturalHeight,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        baseScale: geometryWidth * scale / naturalWidth,
        baseWidth: geometryWidth * scale,
        baseHeight: geometryHeight * scale
      };
      applyPreviewTransform();
      updatePreviewHistogram();
      repairBrush.redraw();
    }

    if (image.complete) {
      applyFit();
    } else {
      image.addEventListener("load", applyFit, { once: true });
    }
  }

  // MCP replies only after the current preview has decoded and its geometry is applied.
  window.flushPhotoUI = async function () {
    var image;
    do {
      image = app.querySelector(".preview-image");
      if (image && image._pendingPreviewDecode) await image._pendingPreviewDecode;
      if (image) await image.decode().catch(function () {});
    } while (image !== app.querySelector(".preview-image") || (image && image._pendingPreviewDecode));
    fitPreviewImage();
    updatePreviewFeedback();
  };

  function cropGeometry(adjustment) {
    var image = app.querySelector(".crop-source-image");
    var sourceWidth = Number((state.cropSourceImageSize || {}).width) || (image ? (image.naturalWidth || 1) : 1);
    var sourceHeight = Number((state.cropSourceImageSize || {}).height) || (image ? (image.naturalHeight || 1) : 1);
    var sourceAspect = sourceWidth / Math.max(sourceHeight, 1);
    var cropAspect = adjustment.cropAspectRatio || "original";
    var isPortrait = sourceHeight > sourceWidth;
    var targetAspect = null;
    if (cropAspect === "threeTwo") targetAspect = isPortrait ? 2 / 3 : 3 / 2;
    else if (cropAspect === "oneOne") targetAspect = 1;
    else if (cropAspect === "fourThree") targetAspect = isPortrait ? 3 / 4 : 4 / 3;
    else if (cropAspect === "sixteenNine") targetAspect = isPortrait ? 9 / 16 : 16 / 9;

    var baseWidth = 1;
    var baseHeight = 1;
    if (targetAspect && Math.abs(sourceAspect - targetAspect) > 0.000001) {
      if (sourceAspect > targetAspect) baseWidth = targetAspect / sourceAspect;
      else baseHeight = sourceAspect / targetAspect;
    }

    var isFree = cropAspect === "free";
    var widthScale = clamp(isFree ? adjustment.cropWidth : adjustment.cropScale, 20, 100) / 100;
    var heightScale = clamp(isFree ? adjustment.cropHeight : adjustment.cropScale, 20, 100) / 100;
    var width = baseWidth * widthScale;
    var height = baseHeight * heightScale;
    var horizontalUnit = (clamp(adjustment.cropHorizontalPosition, -100, 100) / 100 + 1) / 2;
    var verticalUnit = (clamp(adjustment.cropVerticalPosition, -100, 100) / 100 + 1) / 2;
    return {
      x: (1 - width) * horizontalUnit,
      y: (1 - height) * verticalUnit,
      width: width,
      height: height,
      baseWidth: baseWidth,
      baseHeight: baseHeight
    };
  }

  function updateCropEditorLayout() {
    if (!previewFit || !isCropEditorVisible(currentAdjustment())) return;
    var box = app.querySelector("[data-crop-box]");
    var sourceImage = app.querySelector(".crop-source-image");
    if (!box || !sourceImage) return;

    var geometry = cropGeometry(currentAdjustment());
    var sourceLeft = (previewFit.frameWidth - previewFit.baseWidth) / 2;
    var sourceTop = (previewFit.frameHeight - previewFit.baseHeight) / 2;
    var cropLeft = geometry.x * previewFit.baseWidth;
    var cropTop = geometry.y * previewFit.baseHeight;
    var cropWidth = geometry.width * previewFit.baseWidth;
    var cropHeight = geometry.height * previewFit.baseHeight;

    box.style.left = Math.round(sourceLeft + cropLeft) + "px";
    box.style.top = Math.round(sourceTop + cropTop) + "px";
    box.style.width = Math.max(28, Math.round(cropWidth)) + "px";
    box.style.height = Math.max(28, Math.round(cropHeight)) + "px";
    var rotation = currentAdjustment().cropRotation || 0;
    var radians = rotation * Math.PI / 180;
    var c = Math.abs(Math.cos(radians)), s = Math.abs(Math.sin(radians));
    var scale = Math.max(c + s * previewFit.baseHeight / previewFit.baseWidth, c + s * previewFit.baseWidth / previewFit.baseHeight);
    var transform = "rotate(" + rotation + "deg) scale(" + scale + ")";
    sourceImage.style.transform = transform;
    var windowImage = box.querySelector(".crop-window-image");
    windowImage.style.width = previewFit.baseWidth + "px";
    windowImage.style.height = previewFit.baseHeight + "px";
    windowImage.style.left = -cropLeft + "px";
    windowImage.style.top = -cropTop + "px";
    windowImage.style.transform = transform;
    var angle = app.querySelector("[data-crop-rotation-reset]");
    if (angle) angle.textContent = rotation.toFixed(1) + "°";
  }

  function updatePreviewImage(image, nextSource) {
    if (!nextSource || image._requestedPreviewSource === nextSource) return;
    image._requestedPreviewSource = nextSource;
    image._previewError = false;
    // 保留已顯示的像素，新結果解碼完成後才交換，過期結果不進入畫面。
    var decoded = new Image();
    decoded.src = nextSource;
    var pending = decoded.decode().then(function () {
      if (!image.isConnected || image._requestedPreviewSource !== nextSource) return;
      image.src = nextSource;
      image._hasDisplayedPreview = true;
      fitPreviewImage();
    }).catch(function () {
      if (image.isConnected && image._requestedPreviewSource === nextSource) image._previewError = true;
    }).then(function () {
      if (image._pendingPreviewDecode === pending) image._pendingPreviewDecode = null;
      if (image.isConnected) updatePreviewFeedback();
    });
    image._pendingPreviewDecode = pending;
  }

  function setPreviewImageSource(showOriginal) {
    var image = app.querySelector(".preview-image:not(.crop-source-image)");
    if (!image) return;

    var nextSource = state.repairEditing ? (state.repairSourceImage || state.cropSourceImage) : (showOriginal ? state.sourceImage : (filmHoverPreview.imageSource() || state.outputImage));
    if (!nextSource) return;

    updatePreviewImage(image, nextSource);
    updatePreviewFeedback();
    fitPreviewImage();
  }

  function updateLocalAdjustment(key, value) {
    var nextAdjustments = Object.assign({}, state.adjustments || {});
    var current = Object.assign({}, nextAdjustments[state.selectedStyle] || currentAdjustment());
    if (key === "vignetteBalance") {
      var balanced = clamp(value, -100, 100);
      current.vignette = balanced > 0 ? balanced : 0;
      current.devignette = balanced < 0 ? -balanced : 0;
    } else if (!updateLocalPlanTone(current, key, value)) {
      current[key] = value;
    }
    nextAdjustments[state.selectedStyle] = current;
    state.adjustments = nextAdjustments;
  }

  function updateLocalPlanTone(adjustment, key, value) {
    var match = /^(highlight|midtone|shadow)Plan(BaseTone|Contrast|Tint|Highlights|Shadows|Fade|Softness)$/.exec(key);
    if (!match) return false;

    var zoneKey = match[1] === "highlight" ? "highlights" : (match[1] === "midtone" ? "midtones" : "shadows");
    var fieldMap = {
      BaseTone: "baseTone",
      Contrast: "contrast",
      Tint: "tint",
      Highlights: "highlights",
      Shadows: "shadows",
      Fade: "fade",
      Softness: "softness"
    };
    var toneZones = Object.assign({}, adjustment.sourceToneZones || {});
    var tone = Object.assign({}, toneZones[zoneKey] || {});
    tone[fieldMap[match[2]]] = value;
    toneZones[zoneKey] = tone;
    adjustment.sourceToneZones = toneZones;
    return true;
  }

  function normalizeRangeInput(input) {
    var low = Number(input.dataset.rangeMin || input.min || 0);
    var high = Number(input.dataset.rangeMax || input.max || 100);
    var step = Number(input.dataset.rangeStep || 1);
    var value = Number(clamp(Math.round((Number(input.value) - low) / step) * step + low, low, high).toFixed(6));
    input.value = value;
    return value;
  }

  function formatRangeValue(input, value) {
    var low = Number(input.dataset.rangeMin || input.min || 0);
    var high = Number(input.dataset.rangeMax || input.max || 100);
    return rangeValueText(value, low, high, Number(input.dataset.rangeStep || 1), input.dataset.rangeUnit || "");
  }

  function updateRangeVisual(input) {
    var low = Number(input.dataset.rangeMin || input.min || 0);
    var high = Number(input.dataset.rangeMax || input.max || 100);
    var value = clamp(input.value, low, high);
    var span = high - low || 1;
    var thumb = ((value - low) / span) * 100;
    var zero = low < 0 && high > 0 ? ((0 - low) / span) * 100 : 0;
    var fillStart = Math.min(thumb, zero);
    var fillEnd = Math.max(thumb, zero);
    input.style.setProperty("--range-fill-start", fillStart + "%");
    input.style.setProperty("--range-fill-end", fillEnd + "%");
  }

  function beginLiveAdjustment() {
    isDraggingAdjustment = true;
    if (adjustmentInteraction) return;
    adjustmentInteraction = {
      style: state.selectedStyle,
      photoGeneration: state.photoGeneration,
      interactionID: String(Date.now()) + ":" + (++adjustmentInteractionSequence)
    };
    post("beginAdjustmentPreview", adjustmentInteraction);
  }

  function endLiveAdjustment() {
    isDraggingAdjustment = false;
    if (!adjustmentInteraction) return;
    var interaction = adjustmentInteraction;
    adjustmentInteraction = null;
    post("endAdjustmentPreview", interaction);
  }

  function scheduleLiveAdjustment(key, value) {
    pendingLiveAdjustment = { style: state.selectedStyle, key: key, value: value, generation: photoEditGeneration };
    if (liveAdjustmentTimer) return;

    liveAdjustmentTimer = setTimeout(function () {
      liveAdjustmentTimer = null;
      flushLiveAdjustment();
    }, 80);
  }

  function flushLiveAdjustment() {
    if (liveAdjustmentTimer) {
      clearTimeout(liveAdjustmentTimer);
      liveAdjustmentTimer = null;
    }
    if (!pendingLiveAdjustment) return;
    var pending = pendingLiveAdjustment;
    pendingLiveAdjustment = null;
    if (pending.generation === photoEditGeneration && !photoIsBusy(state)) {
      post("updateAdjustment", Object.assign({}, adjustmentInteraction || {}, { style: pending.style, key: pending.key, value: pending.value }));
    }
  }

  function photoIsBusy(value) {
    return !!(value.isRepairingImage || value.isLoadingImage || value.isComputing || value.isSavingImage || value.isMCPMutating ||
      (value.subjectMask && value.subjectMask.detecting));
  }

  function flushPhotoEdits(action, payload) {
    clearTimeout(liveAdjustmentTimer);
    clearTimeout(cropUpdateTimer);
    liveAdjustmentTimer = cropUpdateTimer = null;
    var adjustments = [];
    if (pendingLiveAdjustment && pendingLiveAdjustment.generation === photoEditGeneration) {
      adjustments.push({ style: pendingLiveAdjustment.style, key: pendingLiveAdjustment.key, value: pendingLiveAdjustment.value });
    }
    if (pendingCropValues && pendingCropGeneration === photoEditGeneration) {
      adjustments.push({ style: pendingCropStyle, cropValues: pendingCropValues });
    }
    if (pendingCropValues) { state.cropEditing = false; cropEditSnapshot = null; }
    pendingLiveAdjustment = pendingCropValues = pendingCropStyle = null;
    endLiveAdjustment();
    if (photoIsBusy(state)) return;
    if (action) {
      var command = Object.assign({}, payload || {});
      if (adjustments.length) command.adjustments = adjustments;
      post(action, command);
    } else if (adjustments.length) {
      post("updateAdjustment", { adjustments: adjustments });
    }
  }

  function discardPendingPhotoEdits() {
    cropEditSnapshot = null;
    endLiveAdjustment();
    photoEditGeneration += 1;
    clearTimeout(liveAdjustmentTimer);
    clearTimeout(cropUpdateTimer);
    liveAdjustmentTimer = cropUpdateTimer = null;
    pendingLiveAdjustment = pendingCropValues = pendingCropStyle = null;
    isDraggingAdjustment = isDraggingCrop = false;
    cropGesture = null;
    document.body.classList.remove("preview-gesture-active");
  }

  function finishAdjustmentGesture() {
    // A click without a value change does not emit `change` on a range control.
    // Defer until any final change event has run before replacing its DOM node.
    var interaction = adjustmentInteraction;
    if (!interaction) return;
    setTimeout(function () {
      if (!isDraggingAdjustment || adjustmentInteraction !== interaction) return;
      flushLiveAdjustment();
      endLiveAdjustment();
      render();
    }, 0);
  }

  function updateBusyDialog() {
    var isDetectingSubjectMask = !!(state.subjectMask && state.subjectMask.detecting);
    var modelDownload = state.isRepairingImage && state.repairModelProgress;
    var downloadBar = document.getElementById('repairDownloadProgress');
    var downloadBytes = document.getElementById('repairDownloadBytes');
    downloadBar.hidden = downloadBytes.hidden = !modelDownload;
    app.inert = !!modelDownload || exportDevelopment.isVisible() || !!(state.isLoadingImage || state.isComputing || state.isSavingImage || state.isMCPMutating || isDetectingSubjectMask);
    if (modelDownload) {
      computeStartedAt = null;
      if (computeTimer) { clearInterval(computeTimer); computeTimer = null; }
      busyTitle.textContent = L.text(modelDownload.preparing ? '正在準備本機修復工具…' : '正在下載修復模型');
      setBusyStep(state.isCancellingRepair ? L.text('正在取消…') : L.text(modelDownload.preparing ? '下載完成，正在準備模型。' : '首次使用需下載模型，之後可離線修復。'));
      setBusyItems([]);
      var total = Math.max(0, Number(modelDownload.total) || 0);
      var received = Math.min(total, Math.max(0, Number(modelDownload.received) || 0));
      if (modelDownload.preparing || !total) downloadBar.removeAttribute('value');
      else downloadBar.value = received / total;
      downloadBar.setAttribute('aria-label', busyTitle.textContent);
      downloadBytes.textContent = (total ? Math.floor(received / total * 100) + '% · ' : '') + (received / 1000000).toFixed(1) + ' / ' + (total / 1000000).toFixed(1) + ' MB';
      busyTime.hidden = true;
      busyCancel.hidden = false;
      busyCancel.disabled = !!state.isCancellingRepair;
      busyCancel.textContent = L.text(state.isCancellingRepair ? '正在取消…' : '取消下載');
      if (busyDialog.hidden) { busyDialog.hidden = false; busyCancel.focus({preventScroll:true}); }
    } else if (state.isLoadingImage) {
      computeStartedAt = null;
      busyTitle.textContent = L.text("正在讀取圖片");
      setBusyStep("");
      setBusyItems([]);
      busyTime.hidden = true;
      busySeconds.textContent = "0";
      busyCancel.hidden = true;
      busyDialog.hidden = true;
      if (computeTimer) {
        clearInterval(computeTimer);
        computeTimer = null;
      }
    } else if (state.isComputing) {
      if (!computeStartedAt) computeStartedAt = Date.now();
      busyTitle.textContent = state.isCancellingComputation ? L.text("正在取消 AI 分析") : L.text("AI 正在重新計算中");
      setBusyStep(state.computationStep || L.text("分析照片並規劃調整參數"));
      setBusyItems(state.computationItems || [], state.computationCompletedItems || 0);
      busyTime.hidden = false;
      busyCancel.hidden = !(state.canCancelComputation || state.isCancellingComputation);
      busyCancel.disabled = !!state.isCancellingComputation;
      busyCancel.textContent = state.isCancellingComputation ? L.text("正在取消…") : L.text("取消分析");
      busyDialog.hidden = false;
      updateBusySeconds();
      if (!computeTimer) computeTimer = setInterval(updateBusySeconds, 250);
    } else if (state.isSavingImage) {
      computeStartedAt = null;
      busyTitle.textContent = L.text("正在輸出照片");
      setBusyStep(state.savingStep || L.text("準備輸出"));
      setBusyItems([]);
      busyTime.hidden = true;
      busySeconds.textContent = "0";
      busyCancel.hidden = true;
      busyDialog.hidden = true;
      if (computeTimer) {
        clearInterval(computeTimer);
        computeTimer = null;
      }
    } else if (isDetectingSubjectMask) {
      computeStartedAt = null;
      busyTitle.textContent = L.text("正在偵測主體遮罩");
      setBusyStep("");
      setBusyItems([]);
      busyTime.hidden = true;
      busySeconds.textContent = "0";
      busyCancel.hidden = false;
      busyCancel.disabled = false;
      busyCancel.textContent = L.text("取消偵測");
      busyDialog.hidden = false;
      if (computeTimer) {
        clearInterval(computeTimer);
        computeTimer = null;
      }
    } else {
      computeStartedAt = null;
      busyDialog.hidden = true;
      setBusyStep("");
      setBusyItems([]);
      busyTime.hidden = false;
      busyCancel.hidden = true;
      busySeconds.textContent = "0";
      if (computeTimer) {
        clearInterval(computeTimer);
        computeTimer = null;
      }
    }
  }

  function setBusyStep(step) {
    if (!busyStep) return;
    busyStep.textContent = L.text(step || "");
    busyStep.hidden = !step;
  }

  function setBusyItems(items, completedCount) {
    if (!busyItems) return;
    busyItems.replaceChildren();
    var rows = Array.isArray(items) ? items : [];
    var completed = Math.round(clamp(Number(completedCount) || 0, 0, rows.length));
    rows.forEach(function (item, index) {
      var row = document.createElement("li");
      row.className = index < completed ? "completed" : (index === completed ? "active" : "pending");
      row.textContent = L.text(item);
      if (index === completed) row.setAttribute("aria-current", "step");
      busyItems.appendChild(row);
    });
    busyItems.hidden = !busyItems.children.length;
  }

  function updateBusySeconds() {
    if (!computeStartedAt) return;
    busySeconds.textContent = String(Math.floor((Date.now() - computeStartedAt) / 1000));
  }

  window.handleNativeState = function (payload) {
    if (pendingStyleSelection && payload) {
      if ((payload.selectedCustomFilmID || payload.selectedStyle) === pendingStyleSelection || payload.externalEdit || photoIsBusy(payload)) {
        pendingStyleSelection = null;
      } else if (payload.selectedStyle) {
        // A queued preview acknowledgement must not re-enable the film just removed.
        var pendingFilm = state.styles.find(function (film) { return film.id === pendingStyleSelection; });
        payload = Object.assign({}, payload, { selectedStyle: pendingFilm && pendingFilm.baseStyle || pendingStyleSelection, selectedCustomFilmID: pendingFilm && pendingFilm.isCustom ? pendingStyleSelection : null });
      }
    }
    var nextState = Object.assign({}, state, payload || {});
    // A new operation, AI result, or native style switch invalidates local edits.
    // Ordinary preview/progress refreshes must keep an active gesture intact.
    var enteredBusy = !photoIsBusy(state) && photoIsBusy(nextState);
    var changedStyle = nextState.selectedStyle !== state.selectedStyle || nextState.selectedCustomFilmID !== state.selectedCustomFilmID;
    var changedPhoto = nextState.photoGeneration !== state.photoGeneration;
    if (payload && (payload.externalEdit || payload.expandAdjustments || enteredBusy || changedStyle || changedPhoto)) {
      discardPendingPhotoEdits();
    }
    if (payload && payload.externalEdit) {
      state.cropEditing = false;
      state.promptDialog.open = false;
    }
    var hadImages = !!state.outputImage;
    var previousSourceImage = state.sourceImage;
    repairBrush.receive(nextState);
    state = Object.assign({}, state, payload || {});
    if (pendingCropValues && pendingCropGeneration === photoEditGeneration && pendingCropStyle === state.selectedStyle) {
      updateLocalCropValues(pendingCropValues);
    }
    if (changedPhoto || changedStyle || enteredBusy) state.whiteBalancePicking = false;
    if (changedPhoto || (!state.photoGeneration && payload && Object.prototype.hasOwnProperty.call(payload, "sourceImage") && payload.sourceImage !== previousSourceImage)) {
      resetPreviewZoom();
    }
    state.styles = applyStyleOrder(state.styles || [], readStyleOrder());
    persistSelectedStyle(state.selectedStyle);
    if (payload && payload.expandAdjustments) {
      selectAdjustmentPanel("film");
    }
    if (!Object.prototype.hasOwnProperty.call(payload || {}, "sourceImage") && hadImages) {
      state.sourceImage = state.sourceImage || null;
    }
    // Native and MCP selection is authoritative, including styles hidden in the library.
    var enabled = readEnabledStyleIDs();
    if (enabled.indexOf(catalogStyleID(currentLookID())) < 0 && state.styles.some(function (style) { return style.id === currentLookID(); })) {
      persistEnabledStyleIDs(enabled.concat([currentLookID()]));
    }
    if ((currentAdjustment().cropAspectRatio || "original") === "original") {
      state.cropEditing = false;
    }
    if (isDraggingCrop) {
      updateCropEditorLayout();
      updatePreviewFeedback();
      updateBusyDialog();
      return;
    }
    if (isDraggingAdjustment) {
      setPreviewImageSource(false);
      updatePreviewFeedback();
      updateBusyDialog();
      return;
    }
    render();
  };

  window.handleNativeToast = function (payload) {
    var message = payload && payload.message ? payload.message : "";
    if (!message) return;
    if (exportDevelopment.isVisible() && message.indexOf('已匯出：') === 0) {
      deferredExportToast = payload;
      return;
    }
    toast.textContent = L.text(message);
    toast.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      toast.hidden = true;
    }, 2600);
  };

  window.handleDesktopCommand = function (command) {
    filmHoverPreview.cancel();
    if (exportDevelopment.isVisible()) return;
    if (command === "styles") command = "films";
    if (command === "runAI" || command === "exportImage") {
      if (photoIsBusy(state)) return;
      flushPhotoEdits(command === "runAI" ? "applyStyle" : "saveImage");
      discardPendingPhotoEdits();
      render();
      return;
    }
    if (["home", "films", "ai", "settings"].indexOf(command) >= 0) {
      flushPhotoEdits();
      discardPendingPhotoEdits();
      state.page = command;
      render();
      return;
    }
    if (state.page !== "home" || !state.hasImage || isCropEditorVisible(currentAdjustment())) return;
    if (command === "zoomFit") { resetPreviewZoom(); return; }
    var frame = app.querySelector(".preview-frame");
    if (!frame) return;
    var rect = frame.getBoundingClientRect();
    setPreviewScaleAt(previewTransform.scale * (command === "zoomIn" ? 1.25 : 0.8), rect.left + rect.width / 2, rect.top + rect.height / 2);
  };

  document.addEventListener("DOMContentLoaded", function () {
    initializeTooltips();
    initializeAutoHideScrollbars();
    if (busyCancel) {
      busyCancel.addEventListener("click", function () {
        post(state.isRepairingImage && state.repairModelProgress ? "cancelRepairBrush" : (state.isComputing ? "cancelComputation" : "cancelSubjectMaskDetection"));
      });
    }
    document.addEventListener("keydown", function (event) {
      if (exportDevelopment.isVisible()) { event.preventDefault(); return; }
      var editing = event.target.closest("input, textarea, select, button, [contenteditable=true]");
      if (!editing && event.code === "Space" && state.page === "home" && state.sourceImage && !state.cropEditing) {
        event.preventDefault();
        setPreviewImageSource(true);
      }
      if (event.key === "Escape" && repairBrush.escape()) { event.preventDefault(); return; }
      if (event.key === "Escape" && state.whiteBalancePicking) {
        state.whiteBalancePicking = false; render();
      }
      if (event.key === "Escape" && state.cropEditing) {
        event.preventDefault();
        cancelCropEditing();
      }
      if (event.key === "Escape" && state.promptDialog && state.promptDialog.open) {
        state.promptDialog = { open: false, styleID: null };
        render();
      }
    });
    document.addEventListener("keyup", function (event) {
      if (event.code === "Space") setPreviewImageSource(false);
    });
    document.addEventListener("pointerup", finishAdjustmentGesture);
    document.addEventListener("pointercancel", finishAdjustmentGesture);
    window.addEventListener("resize", scheduleThumbnailRequest);
    window.addEventListener("beforeunload", rememberThumbnailViewport);
    window.addEventListener("blur", function () {
      cropGesture = null;
      isDraggingCrop = false;
      var cropBox = app.querySelector("[data-crop-box]");
      if (cropBox) cropBox.classList.remove("is-rotating");
      cancelPreviewGesture();
      setPreviewImageSource(false);
      finishAdjustmentGesture();
    });
    setAppearance(state.appearance);
    render();
    post("setLanguage", { language: languageKey(), preference: state.language });
    post("getState");
  });

  window.addEventListener("resize", fitPreviewImage);
})();
