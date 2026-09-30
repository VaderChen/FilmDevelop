# 底片 CPU 資料

- `film-profiles.json`：由現有 Swift 原始碼匯出的 23 片種、藥水預設、掃描器、光源、光譜與色彩矩陣。
- `spectral-table.f32`：原有 LHTSS 重建表，little-endian Float32；5 平面，每平面 33×33×3 面、RGBA。
- `provenance.json`：Swift 來源 SHA256、Swift 版本與上述兩個資料檔 SHA256。

資料代表本專案的藝術底片模型，不宣稱是外部廠商量測資料。以 `tools/build_film_reference.sh` 重建，並重新產生 Swift 參考與執行最終成品色差驗收。執行時不需 Swift；CMake 將資料複製至執行檔旁的 `film-data`。
