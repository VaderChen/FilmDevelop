# CIEDE2000 參考資料

`ciede2000.txt` 取自 Sharma、Wu、Dalal 的公開補充測試資料，共 34 組 Lab 配對及四位小數的預期 ΔE00。

- [作者說明與論文](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/)
- [原始測試資料](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/dataNprograms/ciede2000testdata.txt)
- G. Sharma, W. Wu, E. N. Dalal, *The CIEDE2000 Color-Difference Formula: Implementation Notes, Supplementary Test Data, and Mathematical Observations*, Color Research & Application 30(1), 21–30, 2005.

本專案自行以 C++ 實作公式，沒有複製參考 MATLAB 程式。採 kL = kC = kH = 1，與公開四位小數結果比較的容差是 0.00005。這組資料用來驗證量測工具，不能代替影像完整流程的 ΔE00 < 2 驗收。
