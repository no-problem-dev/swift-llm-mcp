import Foundation

// MARK: - HTMLDetector

/// Classifies a response as HTML or as untranslatable binary.
enum HTMLDetector {
    /// Reports HTML when the Content-Type says so, or when the body opens with a doctype or `<html>`.
    ///
    /// The sniff exists because servers that omit or misreport Content-Type are common.
    static func isHTML(contentType: String?, content: String) -> Bool {
        if let ct = contentType?.lowercased() {
            if ct.contains("text/html") || ct.contains("application/xhtml+xml") {
                return true
            }
        }
        // Fall back to sniffing the opening tag.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }
        return false
    }

    /// Reports a Content-Type that cannot become text: PDF, image, audio, video or octet-stream.
    ///
    /// Judged from the header alone, so a binary body served without a Content-Type is missed.
    static func isNonTextBinary(contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.contains("application/pdf")
            || ct.contains("application/octet-stream")
            || ct.contains("image/")
            || ct.contains("audio/")
            || ct.contains("video/")
    }
}
