FilmDevelop @DISPLAY_VERSION@

執行環境
  Windows 10／11 x64（AMD64）。此安裝檔不支援 Windows x86 或 ARM64。
  Microsoft Edge WebView2 Evergreen Runtime。
  Microsoft Visual C++ x64 Runtime 14.44.35211.0 或更新版本。
  安裝器會先檢查 Runtime；缺少時從 Microsoft 下載經雜湊及簽章驗證的安裝程式，
  此步驟可能要求系統管理員授權。離線／靜默安裝請先由系統管理員安裝 Runtime。
  首次啟動若缺少 WebView2，程式會提示從 Microsoft 下載安裝，需要網路連線。
  離線環境可先由系統管理員安裝官方 Evergreen Standalone Installer（x64）：
  https://developer.microsoft.com/en-us/microsoft-edge/webview2

安裝與移除
  預設安裝在 %LOCALAPPDATA%\Programs\FilmDevelop，只影響目前使用者。
  可從桌面或開始功能表啟動；更新前請關閉 FilmDevelop。
  可從 Windows 的「已安裝的應用程式」或開始功能表解除安裝。
  解除安裝只移除本套件的程式檔案，保留照片、匯出檔及使用者設定。
  使用者資料與 WebView2 快取位於 %APPDATA%\FilmDevelop。

目前測試範圍
  已在 Windows 10 x64 驗證 JPEG／PNG／TIFF／WebP、中文路徑、ICC／EXIF 與 DNG。
  C++ 引擎使用 Windows WIC 解碼照片、校正方向及色彩描述。
  RAW 預設優先使用可用的系統解析器；無法解析時使用內建 LibRaw。
  也可明確選用 LibRaw；RAW 與計算選項會保存，啟動時重新核對可用能力。
  系統計算預設自動選用探測通過的 Vulkan；無可用 GPU 時採 CPU。
  37 個內建配方、乳劑顆粒、底片光譜、數位色彩、HDR、掃描、裁切、校色、
  膚色、降噪、主體與景深、外框、日期及保存修復貼片均已接入。
  可輸出 sRGB／Adobe RGB／Display P3 的 JPEG、WebP 8 bit、PNG／TIFF 8／16 bit。
  AI 使用 GGUF 主模型及相配的視覺投影模型；模型需自行選取／下載。
  主體、深度及人臉模型隨程式附上；LaMa 修復模型首次使用時下載並驗證，之後離線重用。
  神經運算優先使用可用的 DirectML；不支援時回退 CPU。
  GPU 計算元件需要顯示卡廠商提供的 Vulkan 驅動；本套件不附驅動。

已知差異
  目前 Windows 系統解析器與 LibRaw 都無法完整顯影 Nikon HE／HE* RAW。
  LibRaw 尚未提供鏡頭校正與場景線性 HDR；WIC 鏡頭校正取決於系統解析器。
  Windows 主體／深度模型、降噪、景深與日期字形採跨平台實作，與 Apple 框架可能有差異。
  MLX 僅適用於 macOS；AI 配方品質取決於所選模型。
  本版本為 Beta，安裝程式未簽 Authenticode，尚未發布正式 Release。

授權
  專案授權請見 LICENSE.md；完整第三方授權位於 Licenses。
  THIRD_PARTY_NOTICES.md 是全專案索引，實際隨附元件見 Licenses\Windows\README.md。
