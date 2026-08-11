import Foundation

// MARK: - EncodingDetector

/// Decodes response bytes into a string, working out the character encoding as it goes.
///
/// Order of preference: the Content-Type charset, the charset declared in a `<meta>` tag,
/// UTF-8, then Shift_JIS, EUC-JP, Windows-1252, ISO-8859-1 and ASCII.
///
/// The self-validating encodings come before the permissive ones on purpose. Latin-1 and
/// CP1252 accept any byte sequence, so putting either of them first would turn every
/// undeclared Japanese page into mojibake instead of letting Shift_JIS claim it.
enum EncodingDetector {

    /// Decodes bytes to text, or returns `nil` when no candidate encoding accepts them.
    static func decode(_ data: Data, contentType: String?) -> String? {
        // 1. The HTTP header charset is authoritative.
        if let contentType,
           let charset = parseCharset(from: contentType),
           let encoding = stringEncoding(from: charset),
           let result = String(data: data, encoding: encoding) {
            return result
        }

        // 2. The charset declared in an HTML <meta> tag. Japanese and older sites often
        //    declare it only there. Skipping this step lets the Latin-1 fallback below
        //    swallow Shift_JIS and EUC-JP pages as mojibake (observed on ITmedia).
        if let metaCharset = sniffMetaCharset(data),
           let encoding = stringEncoding(from: metaCharset),
           let result = String(data: data, encoding: encoding) {
            return result
        }

        // 3. UTF-8 is self-validating: invalid input fails rather than decoding to garbage.
        if let result = String(data: data, encoding: .utf8) {
            return result
        }

        // 4. Last resort. Shift_JIS and EUC-JP validate their input, so they get first
        //    refusal; Latin-1 and CP1252 accept anything and would win every time.
        let fallbackEncodings: [String.Encoding] = [
            .shiftJIS,
            .japaneseEUC,
            .windowsCP1252,
            .isoLatin1,       // Accepts every byte, so nothing after it is ever reached.
            .ascii,
        ]
        for encoding in fallbackEncodings {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }
        return nil
    }

    /// Reads the charset out of a `<meta charset>` or `<meta http-equiv>` tag near the top of the document.
    ///
    /// Only the first 4 KB is scanned, so a declaration pushed past that by inline scripts
    /// or a long comment is missed.
    static func sniffMetaCharset(_ data: Data) -> String? {
        // Latin-1 decodes any byte, which is what makes this scan safe before the encoding is known.
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

    /// Pulls the charset parameter out of a Content-Type header, lowercased and unquoted.
    static func parseCharset(from contentType: String) -> String? {
        // "text/html; charset=UTF-8" -> "utf-8"
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

    /// Maps a charset name to a `String.Encoding`, falling back to the IANA registry for names not listed here.
    ///
    /// The registry lookup is Core Foundation's and exists only on Apple platforms. Elsewhere a
    /// name outside the switch below returns `nil` instead of resolving, so a page in an unusual
    /// legacy encoding is reported as undecodable rather than decoded as something else.
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
            #if canImport(Darwin)
            // Ask Core Foundation about names this switch does not list.
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
            #else
            // swift-corelibs-foundation does not surface the IANA charset registry.
            return nil
            #endif
        }
    }
}
