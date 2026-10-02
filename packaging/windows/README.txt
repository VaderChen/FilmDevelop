FilmDevelop @DISPLAY_VERSION@

執行環境
  Windows 10／11 x64（AMD64），不支援 Windows x86 或 ARM64。
  隨附 Microsoft Visual C++ x64 Runtime，直接由 engine 目錄載入，不安裝或覆寫系統 DLL。
  Windows 10／11 內建 UCRT，但不能假設已安裝所需的 Visual C++ Runtime。
  仍需要 Microsoft Edge WebView2 Evergreen Runtime；缺少時會提示下載安裝。
  離線環境請預先安裝官方 Evergreen Standalone Installer（x64）：
  https://developer.microsoft.com/en-us/microsoft-edge/webview2

啟動與移除
  完整解壓 ZIP，進入 FilmDevelop 資料夾，執行 FilmDevelop.exe。
  請勿直接在 ZIP 內執行，也不要只複製 EXE；engine、模型及其他檔案均需保留。
  不需安裝 FilmDevelop、不建立登錄項目或捷徑；可自行將 EXE 建立捷徑。
  使用者資料與 WebView2 快取位於 %APPDATA%\FilmDevelop，移動程式不影響既有設定。
  關閉程式後刪除解壓資料夾即可移除；先確認沒有自己放入的照片或其他檔案。

更新
  「檢查更新」會優先使用 Windows x64 免安裝 ZIP，驗證下載摘要及所有程式檔案，
  保存照片調整、結束舊程式，再替換目前的程式目錄。新版與引擎完成啟動後才確認更新。
  新版無法啟動時還原舊程式。程式目錄內非套件檔案會保留；同名衝突會停止更新。
  程式目錄及上層資料夾需有寫入權限；更新時其他 FilmDevelop 視窗應先關閉。
  舊 setup.exe 版本只認安裝檔，第一次改用 ZIP 請手動下載並解壓至新的資料夾；
  設定與照片編輯資料仍沿用。之後可由免安裝版內更新。

目前測試範圍
  已在 Windows 10 x64 驗證 JPEG／PNG／TIFF／WebP、中文路徑、ICC／EXIF 與 DNG。
  C++ 引擎使用 Windows WIC 解碼照片、校正方向及色彩描述。
  RAW 預設優先使用可用的系統解析器；無法解析時使用內建 LibRaw。
  也可明確選用 LibRaw；RAW 與計算選項會保存，啟動時重新核對可用能力。
  系統計算預設自動選用探測通過的 Vulkan；無可用 GPU 時採 CPU。
  37 個既有配方與 1 個隱藏相容配方、乳劑顆粒、底片光譜、數位色彩、HDR、掃描、裁切、校色、
  膚色、降噪、主體與景深、外框、日期及保存修復貼片均已接入。
  可輸出 sRGB／Adobe RGB／Display P3 的 JPEG、WebP 8 bit、PNG／TIFF 8／16 bit。
  AI 使用 GGUF 主模型及相配的視覺投影模型；模型需自行選取／下載。
  主體、深度及人臉模型隨程式附上；LaMa 修復模型首次使用時下載並驗證，之後離線重用。
  神經運算優先使用可用的 DirectML；不支援時回退 CPU。
  GPU 計算元件需要顯示卡廠商提供的 Vulkan 驅動；本套件不附驅動。

已知差異
  目前仍無法完整顯影 Nikon HE／HE* RAW 與 GoPro GPR。
  LibRaw 尚未提供鏡頭校正與場景線性 HDR；WIC 鏡頭校正取決於系統解析器。
  Windows 主體／深度模型、降噪、景深與日期字形採跨平台實作，與 Apple 框架可能有差異。
  MLX 僅適用於 macOS；AI 配方品質取決於所選模型。
  本版本為 Beta，FilmDevelop 執行檔尚未簽 Authenticode；ZIP 不保證消除 Windows 來源提示。

授權
  專案授權請見 LICENSE.md；完整第三方授權位於 Licenses。
  THIRD_PARTY_NOTICES.md 是全專案索引，實際隨附元件見 Licenses\Windows\README.md。
