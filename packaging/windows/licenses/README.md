# Windows 套件第三方元件

本資料夾保留 Windows 計算模組與安裝程式使用的執行環境授權；內容未修改。

| 元件 | 隨附文件 | 來源 |
| --- | --- | --- |
| MinGW-w64 14.0.0 執行環境 | `mingw-w64-runtime.txt` | [上游完整通知](https://github.com/mingw-w64/mingw-w64/blob/v14.0.0/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt) |
| winpthreads | `winpthreads.txt` | [MinGW-w64 14.0.0](https://github.com/mingw-w64/mingw-w64/blob/v14.0.0/mingw-w64-libraries/winpthreads/COPYING) |
| GCC libgcc／libstdc++ | `GCC-GPL-3.0.txt`、`GCC-RUNTIME-EXCEPTION.txt` | [GPLv3](https://github.com/gcc-mirror/gcc/blob/master/COPYING3)、[GCC Runtime Library Exception 3.1](https://github.com/gcc-mirror/gcc/blob/master/COPYING.RUNTIME) |
| NSIS 與壓縮模組 | 建置時加入 `NSIS.txt` | 建置主機 NSIS `COPYING`；[NSIS 專案](https://nsis.sourceforge.io/) |

GCC 執行環境保留 Free Software Foundation 的原有著作權與 Runtime Library Exception；本次 Windows C++ 工具鏈為 GCC 16.2.0，未修改工具鏈來源。工具鏈或授權版本變更時需同步核對本資料夾。

Go 與 Go 模組的完整授權位於同層 `../Go`，`index.json` 記錄實際使用模組及版本。收集器包含實際編入套件祖先目錄的授權，因此也保留 go-webview2 內嵌 Microsoft WebView2 Loader 的獨立授權。nlohmann/json 授權位於 `../nlohmann-json.txt`。LibRaw 0.22.2 依 CDDL 1.0 隨附，完整著作權、授權、來源網址及 SHA-256 位於 `../RAW`，其上游來源未修改。

WebView2 Evergreen Runtime 在需要時由程式提示使用者向 Microsoft 下載；Vulkan Loader 由顯示卡驅動提供，兩者均未另外打包到安裝檔。全專案的 `THIRD_PARTY_NOTICES.md` 另列 macOS 與模型相依項目，不代表 Windows 套件包含其中所有元件。

Windows 本機推論另附 `../LLM`（llama.cpp、stb_image、JSON）、`../Neural`（ONNX Runtime／DirectML 原廠授權及第三方通知）、`../Vision`（U²-Net、Depth Anything V2 Small、UltraFace）及 `../Repair`（首次下載的 LaMa 模型授權）。各 ONNX 權重的固定來源與 SHA-256 列於 `../Vision/NOTICE.txt`，推論不會上傳照片。

Microsoft Visual C++ x64 執行環境由安裝程式先檢查，缺少時下載原廠安裝器並核對 SHA-256 及 Microsoft 簽章；不在此套件重新散布 VC_redist 或抽取的系統 DLL。
