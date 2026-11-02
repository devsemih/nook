import AppKit

/// HTML gövdeyi önizleme ve arama için düz metne çevirir.
nonisolated enum HTMLText {
    static func plain(from html: String) -> String {
        var text = html
        // Yorumlar ve görünmeyen bölümler; yarım inen gövdede kapanış etiketi olmayabilir
        text = text.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<!--.*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<(style|script|head|title)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<(style|script|head|title)\b[^>]*>.*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|li|tr|h[1-6]|blockquote|table)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Sonda yarım kalmış etiket
        text = text.replacingOccurrences(of: #"<[^>]*$"#, with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'",
            "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
            "&rarr;": "→", "&middot;": "·", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
            "&bull;": "•", "&laquo;": "«", "&raquo;": "»", "&euro;": "€", "&copy;": "©", "&reg;": "®", "&trade;": "™",
            "&zwnj;": "", "&zwj;": "", "&shy;": "",
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = decodeNumericEntities(text)
        // Bültenlerin önizleme dolgusu olarak kullandığı görünmez karakterler
        text = text.replacingOccurrences(of: #"[\x{200B}-\x{200F}\x{2060}-\x{206F}\x{FEFF}\x{00AD}\x{034F}\x{180E}\x{3164}]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// &#304; ve &#x130; gibi sayısal karakter referansları
    static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var remainder = Substring(text)
        while let match = remainder.firstMatch(of: #/&#([xX]?)([0-9a-fA-F]{1,6});/#) {
            result += remainder[..<match.range.lowerBound]
            let radix = match.1.isEmpty ? 10 : 16
            if let value = UInt32(match.2, radix: radix), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                result += remainder[match.range]
            }
            remainder = remainder[match.range.upperBound...]
        }
        return result + remainder
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension NSAttributedString {
    /// Yazma alanındaki basit biçimi (kalın, italik, altı çizili, link) HTML'e çevirir.
    var mailHTML: String {
        var html = ""
        let fontManager = NSFontManager.shared
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
            var chunk = HTMLText.escape((string as NSString).substring(with: range))
                .replacingOccurrences(of: "\n", with: "<br>")
            if let font = attributes[.font] as? NSFont {
                let traits = fontManager.traits(of: font)
                if traits.contains(.boldFontMask) { chunk = "<b>\(chunk)</b>" }
                if traits.contains(.italicFontMask) { chunk = "<i>\(chunk)</i>" }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                chunk = "<u>\(chunk)</u>"
            }
            if let color = attributes[.foregroundColor] as? NSColor, color == .secondaryLabelColor {
                chunk = "<span style=\"color:GrayText\">\(chunk)</span>"
            }
            if let link = attributes[.link] {
                let href = (link as? URL)?.absoluteString ?? "\(link)"
                chunk = "<a href=\"\(HTMLText.escape(href))\">\(chunk)</a>"
            }
            html += chunk
        }
        return html
    }
}
