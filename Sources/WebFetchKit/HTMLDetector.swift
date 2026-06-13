import Foundation

// MARK: - HTMLDetector

/// レスポンスが HTML かどうかを判定する。
enum HTMLDetector {
    /// Content-Type ヘッダーと先頭の HTML タグの両方で判定する。
    static func isHTML(contentType: String?, content: String) -> Bool {
        // Content-Type ベースの判定
        if let ct = contentType?.lowercased() {
            if ct.contains("text/html") || ct.contains("application/xhtml+xml") {
                return true
            }
        }
        // 先頭タグベースの判定
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }
        return false
    }

    /// テキストとして処理できない（PDF/画像/音声/動画/バイナリ）Content-Type か。
    static func isNonTextBinary(contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.contains("application/pdf")
            || ct.contains("application/octet-stream")
            || ct.contains("image/")
            || ct.contains("audio/")
            || ct.contains("video/")
    }
}
