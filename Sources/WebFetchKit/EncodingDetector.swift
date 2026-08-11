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

    /// Maps a charset name to a `String.Encoding`.
    ///
    /// The names come from the WHATWG Encoding Standard's label index, which is the list browsers
    /// use to read declared charsets, so a page that renders in a browser resolves here too.
    /// Unknown names return `nil`.
    ///
    /// - Note: Resolving a name is not the same as being able to read it. The values handed back
    ///   are only as good as the platform's codecs — see `encodingsByLabel`.
    static func stringEncoding(from charset: String) -> String.Encoding? {
        encodingsByLabel[charset.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    /// Charset label to encoding, following the WHATWG Encoding Standard's label index.
    ///
    /// This is a table rather than a call into the IANA charset database because that database is
    /// reachable only through CoreFoundation (`CFStringConvertIANACharSetNameToEncoding`), which
    /// Linux Foundation does not export — the encodings themselves decode on both platforms, it is
    /// only the name lookup that is missing. A table keeps one answer on every platform, instead of
    /// resolving legacy encodings on Apple platforms and reporting them undecodable elsewhere.
    ///
    /// Three labels keep the mapping this type used before the table, rather than the WHATWG one:
    /// `iso-8859-1` and `us-ascii` stay on their own encodings instead of collapsing into
    /// windows-1252, and `utf-16` stays on `.utf16`, which honours a byte-order mark.
    ///
    /// - Note: EUC-JP resolves here but has no codec in Linux Foundation. Every other entry decodes
    ///   on both platforms, which `EncodingDetectorTests` asserts against the table itself.
    static let encodingsByLabel: [String: String.Encoding] = {
        var table: [String: String.Encoding] = [:]
        for (encoding, labels) in labelIndex {
            for label in labels { table[label] = encoding }
        }
        return table
    }()

    private static let labelIndex: [(String.Encoding, [String])] = [
        (.utf8, ["unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8"]),
        (.ascii, ["ascii", "us-ascii"]),
        (.isoLatin1, ["iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "iso-ir-100", "latin1", "l1", "cp819", "ibm819", "csisolatin1", "ansi_x3.4-1968"]),
        (.isoLatin2, ["iso-8859-2", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "iso-ir-101", "latin2", "l2", "csisolatin2"]),
        (.iso8859_3, ["iso-8859-3", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "iso-ir-109", "latin3", "l3", "csisolatin3"]),
        (.iso8859_4, ["iso-8859-4", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "iso-ir-110", "latin4", "l4", "csisolatin4"]),
        (.iso8859_5, ["iso-8859-5", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988", "iso-ir-144", "cyrillic", "csisolatincyrillic"]),
        (.iso8859_6, ["iso-8859-6", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "arabic", "asmo-708", "ecma-114", "csiso88596e", "csiso88596i", "csisolatinarabic"]),
        (.iso8859_7, ["iso-8859-7", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "iso-ir-126", "greek", "greek8", "ecma-118", "elot_928", "sun_eu_greek", "csisolatingreek"]),
        (.iso8859_8, ["iso-8859-8", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "iso-8859-8-e", "iso-8859-8-i", "iso-ir-138", "hebrew", "logical", "visual", "csiso88598e", "csiso88598i", "csisolatinhebrew"]),
        (.iso8859_10, ["iso-8859-10", "iso8859-10", "iso885910", "iso-ir-157", "latin6", "l6", "csisolatin6"]),
        (.iso8859_13, ["iso-8859-13", "iso8859-13", "iso885913"]),
        (.iso8859_14, ["iso-8859-14", "iso8859-14", "iso885914"]),
        (.iso8859_15, ["iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "latin9", "l9", "csisolatin9"]),
        (.iso8859_16, ["iso-8859-16"]),
        (.ibm866, ["866", "cp866", "ibm866", "csibm866"]),
        (.koi8R, ["koi", "koi8", "koi8-r", "koi8_r", "cskoi8r"]),
        (.koi8U, ["koi8-u", "koi8-ru"]),
        (.macOSRoman, ["macintosh", "mac", "x-mac-roman", "csmacintosh"]),
        (.macCyrillic, ["x-mac-cyrillic", "x-mac-ukrainian"]),
        (.windows874, ["windows-874", "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620"]),
        (.windowsCP1250, ["windows-1250", "cp1250", "x-cp1250"]),
        (.windowsCP1251, ["windows-1251", "cp1251", "x-cp1251"]),
        (.windowsCP1252, ["windows-1252", "cp1252", "x-cp1252"]),
        (.windowsCP1253, ["windows-1253", "cp1253", "x-cp1253"]),
        (.windowsCP1254, ["windows-1254", "cp1254", "x-cp1254", "iso-8859-9", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "iso-ir-148", "latin5", "l5", "csisolatin5"]),
        (.windows1255, ["windows-1255", "cp1255", "x-cp1255"]),
        (.windows1256, ["windows-1256", "cp1256", "x-cp1256"]),
        (.windows1257, ["windows-1257", "cp1257", "x-cp1257"]),
        (.windows1258, ["windows-1258", "cp1258", "x-cp1258"]),
        // The WHATWG index decodes every GBK label with the gb18030 decoder, which is a superset
        (.gb18030, ["gb18030", "gbk", "gb2312", "gb_2312", "gb_2312-80", "chinese", "iso-ir-58", "x-gbk", "csgb2312", "csiso58gb231280"]),
        (.big5, ["big5", "big5-hkscs", "cn-big5", "x-x-big5", "csbig5"]),
        (.shiftJIS, ["shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "ms932", "windows-31j", "csshiftjis"]),
        (.japaneseEUC, ["euc-jp", "eucjp", "x-euc-jp", "cseucpkdfmtjapanese"]),
        (.iso2022JP, ["iso-2022-jp", "csiso2022jp"]),
        (.eucKR, ["euc-kr", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "iso-ir-149", "windows-949", "cseuckr", "csksc56011987"]),
        (.utf16, ["utf-16", "utf16"]),
        (.utf16BigEndian, ["utf-16be", "unicodefffe"]),
        (.utf16LittleEndian, ["utf-16le", "ucs-2", "iso-10646-ucs-2", "unicode", "unicodefeff", "csunicode"]),
    ]
}

/// Encodings Foundation can decode but exposes no named constant for.
///
/// The raw values are `NSStringEncoding`s, the same numbers
/// `CFStringConvertEncodingToNSStringEncoding` returns on Darwin. They are named here because that
/// conversion function is Darwin-only while the values work on Linux Foundation too — which
/// `EncodingDetectorTests` checks by decoding through every one of them.
extension String.Encoding {
    static let iso8859_3 = String.Encoding(rawValue: 0x8000_0203)
    static let iso8859_4 = String.Encoding(rawValue: 0x8000_0204)
    static let iso8859_5 = String.Encoding(rawValue: 0x8000_0205)
    static let iso8859_6 = String.Encoding(rawValue: 0x8000_0206)
    static let iso8859_7 = String.Encoding(rawValue: 0x8000_0207)
    static let iso8859_8 = String.Encoding(rawValue: 0x8000_0208)
    static let iso8859_10 = String.Encoding(rawValue: 0x8000_020A)
    static let iso8859_13 = String.Encoding(rawValue: 0x8000_020D)
    static let iso8859_14 = String.Encoding(rawValue: 0x8000_020E)
    static let iso8859_15 = String.Encoding(rawValue: 0x8000_020F)
    static let iso8859_16 = String.Encoding(rawValue: 0x8000_0210)
    static let ibm866 = String.Encoding(rawValue: 0x8000_041B)
    static let koi8R = String.Encoding(rawValue: 0x8000_0A02)
    static let koi8U = String.Encoding(rawValue: 0x8000_0A08)
    static let macCyrillic = String.Encoding(rawValue: 0x8000_0007)
    static let windows874 = String.Encoding(rawValue: 0x8000_041D)
    static let windows1255 = String.Encoding(rawValue: 0x8000_0505)
    static let windows1256 = String.Encoding(rawValue: 0x8000_0506)
    static let windows1257 = String.Encoding(rawValue: 0x8000_0507)
    static let windows1258 = String.Encoding(rawValue: 0x8000_0508)
    static let gb18030 = String.Encoding(rawValue: 0x8000_0632)
    static let big5 = String.Encoding(rawValue: 0x8000_0A03)
    static let eucKR = String.Encoding(rawValue: 0x8000_0940)
}
