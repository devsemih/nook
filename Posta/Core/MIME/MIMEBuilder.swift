import Foundation

/// Giden maili RFC 5322 / MIME olarak oluşturur (SMTP ve Gmail messages.send için)
nonisolated enum MIMEBuilder {
    struct OutgoingAttachment: Sendable {
        var filename: String
        var mimeType: String
        var data: Data
    }

    struct Outgoing: Sendable {
        var from: Contact
        var to: [Contact]
        var cc: [Contact]
        var subject: String
        var html: String
        var plainText: String
        var attachments: [OutgoingAttachment]
        var inReplyTo: String?
        var references: [String]
        var messageID: String
        var date: Date
    }

    static func makeMessageID(for address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "posta.local"
        return "\(UUID().uuidString.lowercased())@\(domain)"
    }

    static func build(_ message: Outgoing) -> Data {
        var headers: [String] = []
        headers.append("From: \(encodeAddress(message.from))")
        if !message.to.isEmpty { headers.append("To: \(message.to.map(encodeAddress).joined(separator: ", "))") }
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.map(encodeAddress).joined(separator: ", "))") }
        headers.append("Subject: \(encodeHeaderText(message.subject))")
        headers.append("Date: \(rfc2822Date(message.date))")
        headers.append("Message-ID: <\(message.messageID)>")
        if let inReplyTo = message.inReplyTo { headers.append("In-Reply-To: <\(inReplyTo)>") }
        if !message.references.isEmpty {
            headers.append("References: " + message.references.map { "<\($0)>" }.joined(separator: " "))
        }
        headers.append("MIME-Version: 1.0")
        headers.append("X-Mailer: Nook")

        let alternativeBoundary = "posta-alt-\(UUID().uuidString)"
        let alternative = [
            "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"",
            "",
            "--\(alternativeBoundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Lines(Data(message.plainText.utf8)),
            "--\(alternativeBoundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Lines(Data(htmlDocument(message.html).utf8)),
            "--\(alternativeBoundary)--",
            "",
        ].joined(separator: "\r\n")

        var body: String
        if message.attachments.isEmpty {
            body = alternative
        } else {
            let mixedBoundary = "posta-mixed-\(UUID().uuidString)"
            var lines = [
                "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"",
                "",
                "--\(mixedBoundary)",
                alternative,
            ]
            for attachment in message.attachments {
                let name = encodeParameter(attachment.filename)
                lines += [
                    "--\(mixedBoundary)",
                    "Content-Type: \(attachment.mimeType); name=\(name)",
                    "Content-Disposition: attachment; filename=\(name)",
                    "Content-Transfer-Encoding: base64",
                    "",
                    base64Lines(attachment.data),
                ]
            }
            lines.append("--\(mixedBoundary)--")
            lines.append("")
            body = lines.joined(separator: "\r\n")
        }

        // Üst seviye Content-Type, gövdenin ilk satırında; başlıklarla birleştir
        let firstLineEnd = body.range(of: "\r\n")!
        let contentTypeHeader = String(body[..<firstLineEnd.lowerBound])
        body = String(body[firstLineEnd.upperBound...])
        headers.append(contentTypeHeader)
        return Data((headers.joined(separator: "\r\n") + "\r\n" + body).utf8)
    }

    private static func htmlDocument(_ html: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\(html)</body></html>"
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func encodeAddress(_ contact: Contact) -> String {
        guard !contact.name.isEmpty else { return contact.address }
        let name: String
        if contact.name.allSatisfy({ $0.isASCII }) {
            let needsQuotes = contact.name.contains { "()<>[]:;@\\,.\"".contains($0) }
            name = needsQuotes ? "\"\(contact.name.replacingOccurrences(of: "\"", with: "\\\""))\"" : contact.name
        } else {
            name = encodeHeaderText(contact.name)
        }
        return "\(name) <\(contact.address)>"
    }

    /// Türkçe karakter içeren başlıklar için RFC 2047 B kodlaması
    static func encodeHeaderText(_ text: String) -> String {
        guard !text.allSatisfy({ $0.isASCII }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            let candidate = chunk + String(character)
            if Data(candidate.utf8).base64EncodedString().count > 60 {
                words.append(chunk)
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func encodeParameter(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) {
            return "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
        }
        return "\"\(encodeHeaderText(value).replacingOccurrences(of: "\r\n ", with: " "))\""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func rfc2822Date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
