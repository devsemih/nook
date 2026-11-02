import Foundation

nonisolated enum SMTPError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): String(localized: "The outgoing mail server rejected the message: \(message)")
        }
    }
}

/// STARTTLS ve AUTH PLAIN ile gönderim (iCloud: smtp.mail.me.com:587)
nonisolated enum SMTPClient {
    static func send(
        host: String,
        port: Int = 587,
        username: String,
        password: String,
        from: String,
        recipients: [String],
        data: Data
    ) async throws {
        let connection = StreamConnection(host: host, port: port)
        await connection.open(tls: false)
        defer { Task { await connection.close() } }

        try await expect(220, on: connection)
        try await connection.write("EHLO posta.local\r\n")
        try await expect(250, on: connection)
        try await connection.write("STARTTLS\r\n")
        try await expect(220, on: connection)
        await connection.startTLS()
        try await connection.write("EHLO posta.local\r\n")
        try await expect(250, on: connection)

        let credentials = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        try await connection.write("AUTH PLAIN \(credentials)\r\n")
        try await expect(235, on: connection)

        try await connection.write("MAIL FROM:<\(from)>\r\n")
        try await expect(250, on: connection)
        for recipient in recipients {
            try await connection.write("RCPT TO:<\(recipient)>\r\n")
            try await expect([250, 251], on: connection)
        }
        try await connection.write("DATA\r\n")
        try await expect(354, on: connection)
        try await connection.write(dotStuffed(data))
        try await connection.write("\r\n.\r\n")
        try await expect(250, on: connection)
        try? await connection.write("QUIT\r\n")
    }

    private static func expect(_ code: Int, on connection: StreamConnection) async throws {
        try await expect([code], on: connection)
    }

    /// Çok satırlı yanıtları ("250-…" … "250 …") sonuna kadar okur
    private static func expect(_ codes: [Int], on connection: StreamConnection) async throws {
        var lastLine = ""
        while true {
            let line = String(decoding: try await connection.readLine(), as: UTF8.self)
            lastLine = line
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        guard let code = Int(lastLine.prefix(3)), codes.contains(code) else {
            throw SMTPError.rejected(lastLine)
        }
    }

    private static func dotStuffed(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 64)
        var atLineStart = true
        for byte in data {
            if atLineStart && byte == 0x2E { output.append(0x2E) }
            output.append(byte)
            atLineStart = byte == 0x0A
        }
        return output
    }
}
