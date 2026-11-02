import Foundation

/// Ham RFC 822 / MIME mesajını ayrıştırır. Hem IMAP hem Gmail (format=raw) aynı yolu kullanır.
nonisolated enum MIME {
    struct Part: Sendable {
        var headers: [(name: String, value: String)]
        var contentType: String
        var parameters: [String: String]
        var body: Data
        var children: [Part]

        func header(_ name: String) -> String? {
            headers.first { $0.name == name.lowercased() }?.value
        }

        var dispositionParameters: [String: String] {
            guard let value = header("content-disposition") else { return [:] }
            return MIME.parameters(of: value).1
        }

        var isAttachmentDisposition: Bool {
            header("content-disposition")?.lowercased().hasPrefix("attachment") == true
        }

        var filename: String? {
            let name = dispositionParameters["filename"] ?? parameters["name"]
            return name.map(MIME.decodeEncodedWords)
        }

        var contentID: String? {
            header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
    }

    struct ParsedAttachment: Sendable {
        var filename: String
        var mimeType: String
        var data: Data
        var contentID: String?
        var isInline: Bool
    }

    struct ParsedMessage: Sendable {
        var messageID: String?
        var inReplyTo: String?
        var references: [String]
        var subject: String
        var from: Contact?
        var to: [Contact]
        var cc: [Contact]
        var replyTo: [Contact]
        var date: Date?
        var html: String
        var attachments: [ParsedAttachment]
        var hasAttachments: Bool
        /// Bülten, bildirim gibi otomatik gönderilmiş mail
        var isAutomated: Bool
    }

    // MARK: - Mesaj

    static func message(from data: Data) -> ParsedMessage {
        let root = parse(data)
        var html: String?
        var plain: String?
        var attachments: [ParsedAttachment] = []
        collect(root, html: &html, plain: &plain, attachments: &attachments)

        var body = html ?? plain.map(htmlFromPlainText) ?? ""
        // Satır içi görseller (cid:) data URI olarak gömülür; uzak içerik engeli bunları etkilemez
        for attachment in attachments where attachment.contentID != nil && attachment.mimeType.hasPrefix("image/") && attachment.data.count < 3_000_000 {
            guard let cid = attachment.contentID else { continue }
            let uri = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            body = body.replacingOccurrences(of: "cid:\(cid)", with: uri)
        }
        let referencedInline = attachments.filter { attachment in
            guard let cid = attachment.contentID else { return false }
            return (html ?? "").contains("cid:\(cid)")
        }.map(\.contentID)
        let visible = attachments.filter { !($0.isInline && referencedInline.contains($0.contentID)) }
        let from = addresses(root.header("from") ?? "").first

        return ParsedMessage(
            messageID: root.header("message-id").map(cleanMessageID),
            inReplyTo: root.header("in-reply-to").map(cleanMessageID),
            references: (root.header("references") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { cleanMessageID(String($0)) }.filter { !$0.isEmpty },
            subject: decodeEncodedWords(root.header("subject") ?? ""),
            from: from,
            to: addresses(root.header("to") ?? ""),
            cc: addresses(root.header("cc") ?? ""),
            replyTo: addresses(root.header("reply-to") ?? ""),
            date: root.header("date").flatMap(parseDate),
            html: body,
            attachments: visible,
            hasAttachments: !visible.isEmpty || root.contentType == "multipart/mixed",
            isAutomated: MailClassifier.isAutomated(header: root.header, from: from)
        )
    }

    private static func collect(_ part: Part, html: inout String?, plain: inout String?, attachments: inout [ParsedAttachment]) {
        if part.contentType.hasPrefix("multipart/") {
            if part.contentType == "multipart/alternative" {
                // En zengin biçim: HTML varsa onu al
                let chosenIndex = part.children.lastIndex { containsType($0, "text/html") }
                    ?? part.children.lastIndex { containsType($0, "text/plain") }
                    ?? (part.children.isEmpty ? nil : 0)
                for (index, child) in part.children.enumerated() {
                    if index == chosenIndex {
                        collect(child, html: &html, plain: &plain, attachments: &attachments)
                    } else if child.contentType.hasPrefix("multipart/") {
                        // Seçilmeyen alternatiflerdeki ekleri yine de topla
                        var ignoredHTML: String?
                        var ignoredPlain: String?
                        collect(child, html: &ignoredHTML, plain: &ignoredPlain, attachments: &attachments)
                    }
                }
            } else {
                for child in part.children {
                    collect(child, html: &html, plain: &plain, attachments: &attachments)
                }
            }
            return
        }

        let isText = part.contentType == "text/html" || part.contentType == "text/plain"
        let isAttachment = part.isAttachmentDisposition || (part.filename != nil && !isText) || (!isText && !part.contentType.hasPrefix("message/"))

        if isText && !part.isAttachmentDisposition {
            let text = decodeText(part.body, charset: part.parameters["charset"])
            if part.contentType == "text/html" {
                html = (html.map { $0 + "<br>" } ?? "") + text
            } else if html == nil {
                plain = (plain.map { $0 + "\n\n" } ?? "") + text
            }
            return
        }

        if part.contentType == "message/rfc822" {
            let nested = message(from: part.body)
            let name = nested.subject.isEmpty ? "ileti.eml" : "\(nested.subject).eml"
            attachments.append(ParsedAttachment(filename: name, mimeType: "message/rfc822", data: part.body, contentID: nil, isInline: false))
            return
        }

        if isAttachment || part.contentID != nil {
            let fallbackName = "ek." + (part.contentType.split(separator: "/").last.map(String.init) ?? "bin")
            attachments.append(ParsedAttachment(
                filename: part.filename ?? fallbackName,
                mimeType: part.contentType,
                data: part.body,
                contentID: part.contentID,
                isInline: !part.isAttachmentDisposition && part.contentID != nil
            ))
        }
    }

    private static func containsType(_ part: Part, _ type: String) -> Bool {
        part.contentType == type || part.children.contains { containsType($0, type) }
    }

    // MARK: - Parça ayrıştırma

    static func parse(_ data: Data) -> Part {
        let bytes = [UInt8](data)
        let (headerEnd, bodyStart) = splitHeaders(bytes)
        let headerText = decodeHeaderBytes(Array(bytes[0..<headerEnd]))
        let headers = parseHeaders(headerText)
        let typeValue = headers.first { $0.name == "content-type" }?.value ?? "text/plain; charset=us-ascii"
        let (type, parameters) = MIME.parameters(of: typeValue)
        let contentType = type.isEmpty ? "text/plain" : type
        let rawBody = bodyStart < bytes.count ? Array(bytes[bodyStart...]) : []

        if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"], !boundary.isEmpty {
            let children = splitMultipart(rawBody, boundary: boundary).map { parse(Data($0)) }
            return Part(headers: headers, contentType: contentType, parameters: parameters, body: Data(), children: children)
        }

        let encoding = headers.first { $0.name == "content-transfer-encoding" }?.value.lowercased().trimmingCharacters(in: .whitespaces) ?? "7bit"
        let decoded: Data
        switch encoding {
        case "base64": decoded = decodeBase64(rawBody)
        case "quoted-printable": decoded = decodeQuotedPrintable(rawBody)
        default: decoded = Data(rawBody)
        }
        return Part(headers: headers, contentType: contentType, parameters: parameters, body: decoded, children: [])
    }

    private static func splitHeaders(_ bytes: [UInt8]) -> (headerEnd: Int, bodyStart: Int) {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { return (index, index + 2) }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { return (index, index + 3) }
            }
            index += 1
        }
        return (bytes.count, bytes.count)
    }

    private static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        // "\r\n" Swift'te tek karakterdir; önce tüm satır sonları "\n" yapılır
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first else { continue }
            if first == " " || first == "\t" {
                if !result.isEmpty {
                    result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                result.append((name, value))
            }
        }
        return result
    }

    private static func splitMultipart(_ bytes: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [[UInt8]] = []
        var current: [UInt8]?
        var lineStart = 0
        var index = 0
        func handleLine(_ start: Int, _ end: Int) -> Bool {
            // true: kapanış sınırı bulundu
            var lineEnd = end
            if lineEnd > start, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let length = lineEnd - start
            if length >= delimiter.count, Array(bytes[start..<(start + delimiter.count)]) == delimiter {
                let rest = bytes[(start + delimiter.count)..<lineEnd]
                if let part = current { parts.append(trimTrailingNewline(part)) }
                if rest.starts(with: [0x2D, 0x2D]) {
                    current = nil
                    return true
                }
                current = []
                return false
            }
            if current != nil {
                current?.append(contentsOf: bytes[start..<min(end + 1, bytes.count)])
            }
            return false
        }
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if handleLine(lineStart, index) { return parts }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart < bytes.count { _ = handleLine(lineStart, bytes.count) }
        if let part = current, !part.isEmpty { parts.append(part) }
        return parts
    }

    private static func trimTrailingNewline(_ bytes: [UInt8]) -> [UInt8] {
        var end = bytes.count
        if end > 0, bytes[end - 1] == 0x0A { end -= 1 }
        if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
        return Array(bytes[0..<end])
    }

    /// "text/html; charset=utf-8" → ("text/html", ["charset": "utf-8"]); RFC 2231 devam parametrelerini de birleştirir
    static func parameters(of value: String) -> (String, [String: String]) {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ";" && !inQuotes {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        let type = items.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for item in items.dropFirst() {
            guard let equals = item.firstIndex(of: "=") else { continue }
            var key = item[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = item[item.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.lastIndex(of: "*"), let number = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((number, raw, extended))
            } else {
                parameters[key] = extended ? decodeRFC2231(raw, isFirst: true) : raw
            }
        }
        for (key, pieces) in continuations {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            var charset: String?
            var result = ""
            for (index, piece) in sorted.enumerated() {
                if piece.2 {
                    if index == 0 {
                        let components = piece.1.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if components.count == 3 {
                            charset = String(components[0])
                            result += percentDecode(String(components[2]), charset: charset)
                            continue
                        }
                    }
                    result += percentDecode(piece.1, charset: charset)
                } else {
                    result += piece.1
                }
            }
            parameters[key] = result
        }
        return (type, parameters)
    }

    private static func decodeRFC2231(_ value: String, isFirst: Bool) -> String {
        let components = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return percentDecode(value, charset: nil) }
        return percentDecode(String(components[2]), charset: String(components[0]))
    }

    private static func percentDecode(_ value: String, charset: String?) -> String {
        var bytes: [UInt8] = []
        var iterator = Array(value.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25, let high = iterator.next(), let low = iterator.next(),
               let decoded = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(decoded)
            } else {
                bytes.append(byte)
            }
        }
        return decodeText(Data(bytes), charset: charset)
    }

    // MARK: - Aktarım kodlamaları

    static func decodeBase64(_ bytes: [UInt8]) -> Data {
        var clean = bytes.filter { !($0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09) }
        // Yarım kalmış (kısmi indirilmiş) veride geçerli kısmı çöz
        clean.removeLast(clean.count % 4)
        return Data(base64Encoded: Data(clean), options: .ignoreUnknownCharacters) ?? Data()
    }

    static func decodeQuotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
            } else if underscoreIsSpace && byte == 0x5F {
                output.append(0x20)
            } else {
                output.append(byte)
            }
            index += 1
        }
        return Data(output)
    }

    // MARK: - Karakter setleri

    static func encoding(for charset: String?) -> String.Encoding? {
        guard var name = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        if name == "utf8" { name = "utf-8" }
        if name == "ks_c_5601-1987" { name = "euc-kr" }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(for: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1254) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeHeaderBytes(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// RFC 2047: =?utf-8?B?...?= ve =?iso-8859-9?Q?...?=
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/#
        var result = ""
        var remainder = Substring(value)
        var lastWasEncoded = false
        while let match = remainder.firstMatch(of: pattern) {
            let between = remainder[..<match.range.lowerBound]
            // Kodlanmış kelimeler arasındaki boşluklar yok sayılır
            if !(lastWasEncoded && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            let charset = String(match.1).split(separator: "*").first.map(String.init)
            let text = Array(String(match.3).utf8)
            let data = match.2.lowercased() == "b"
                ? decodeBase64(text)
                : decodeQuotedPrintable(text, underscoreIsSpace: true)
            result += decodeText(data, charset: charset)
            remainder = remainder[match.range.upperBound...]
            lastWasEncoded = true
        }
        result += remainder
        return result
    }

    // MARK: - Adresler ve tarih

    static func addresses(_ value: String) -> [Contact] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        for character in value {
            if (character == "," || character == ";") && !inQuotes && depth == 0 {
                items.append(current)
                current = ""
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == "<" { depth += 1 }
            if character == ">" { depth = max(0, depth - 1) }
            current.append(character)
        }
        items.append(current)
        return items.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = name.replacingOccurrences(of: "\\\"", with: "\"")
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                return Contact(name: decodeEncodedWords(name), address: address)
            }
            let address = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard address.contains("@") else { return nil }
            return Contact(name: "", address: address)
        }
    }

    static func cleanMessageID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parseDate(_ value: String) -> Date? {
        var cleaned = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        cleaned = cleaned.replacingOccurrences(of: " GMT", with: " +0000").replacingOccurrences(of: " UT", with: " +0000")
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - Düz metinden HTML

    static func htmlFromPlainText(_ text: String) -> String {
        var escaped = HTMLText.escape(text)
        escaped = escaped.replacingOccurrences(
            of: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])"#,
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
        // Alıntı satırları
        let lines = escaped.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            line.hasPrefix("&gt;") ? "<span style=\"color:GrayText\">\(line)</span>" : line
        }
        return "<div style=\"white-space:pre-wrap\">\(lines.joined(separator: "\n"))</div>"
    }
}
