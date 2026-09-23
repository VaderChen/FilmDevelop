import Foundation

enum PhotoStyleWebSaveError: LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? { "無法編碼輸出圖片。" }
}
