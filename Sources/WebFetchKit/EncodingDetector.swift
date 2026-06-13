import Foundation

// MARK: - EncodingDetector

/// レスポンスバイト列を適切な文字エンコーディングでデコードする。
///
/// Content-Type ヘッダーの charset を解析し、適切なエンコーディングで変換する。
/// charset が無い／変換に失敗した場合はフォールバックチェーンを使用する。
///
/// フォールバック順: UTF-8 → ISO-8859-1 → Windows-1252 → Shift_JIS → EUC-JP → ASCII
enum EncodingDetector {

    /// レスポンスデータを文字列にデコードする。失敗時は nil。
    static func decode(_ data: Data, contentType: String?) -> String? {
        // 1. HTTP ヘッダーの charset（最優先・authoritative）
        if let contentType,
           let charset = parseCharset(from: contentType),
           let encoding = stringEncoding(from: charset),
           let result = String(data: data, encoding: encoding) {
            return result
        }

        // 2. HTML <meta> タグの charset。
        //    日系/レガシーサイトは HTTP ヘッダーに charset を入れず meta だけで
        //    宣言することが多い。これを見ないと Shift_JIS/EUC-JP が下の Latin1
        //    フォールバックに食われて文字化けする（ITmedia 等で実際に発生）。
        if let metaCharset = sniffMetaCharset(data),
           let encoding = stringEncoding(from: metaCharset),
           let result = String(data: data, encoding: encoding) {
            return result
        }

        // 3. UTF-8（自己検証あり = 不正な UTF-8 は失敗するので安全なデフォルト）
        if let result = String(data: data, encoding: .utf8) {
            return result
        }

        // 4. 最終フォールバック。Latin1/CP1252 は任意バイトを受理してしまうため、
        //    妥当性検証のある Shift_JIS/EUC-JP を先に試す（CJK 復元を優先）。
        let fallbackEncodings: [String.Encoding] = [
            .shiftJIS,        // Shift_JIS
            .japaneseEUC,     // EUC-JP
            .windowsCP1252,   // Windows-1252
            .isoLatin1,       // ISO-8859-1（最後の砦・全バイト受理）
            .ascii,
        ]
        for encoding in fallbackEncodings {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }
        return nil
    }

    /// HTML 先頭を走査して `<meta charset>` / `<meta http-equiv>` の charset を取得する。
    static func sniffMetaCharset(_ data: Data) -> String? {
        // 先頭 4KB を Latin1（全バイト可逆）で読み、charset 宣言を探す
        let head = data.prefix(4096)
        guard let text = String(data: head, encoding: .isoLatin1)?.lowercased() else { return nil }
        guard text.contains("charset"), let regex = try? NSRegularExpression(
            pattern: "charset\\s*=\\s*[\"']?\\s*([a-z0-9_\\-]+)"
        ) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Content-Type ヘッダーから charset を抽出する。
    static func parseCharset(from contentType: String) -> String? {
        // "text/html; charset=UTF-8" → "UTF-8"
        let components = contentType.lowercased().components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                return trimmed.dropFirst("charset=".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    /// charset 名から String.Encoding に変換する。
    static func stringEncoding(from charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "iso_8859-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis":
            return .shiftJIS
        case "euc-jp", "eucjp", "x-euc-jp":
            return .japaneseEUC
        case "ascii", "us-ascii":
            return .ascii
        case "iso-8859-2", "latin2":
            return .isoLatin2
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            // CFStringEncoding 経由で追加の変換を試みる
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
