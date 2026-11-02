import Foundation

nonisolated enum ConnectionError: LocalizedError {
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .closed: String(localized: "The server closed the connection.")
        case .timedOut: String(localized: "The server didn't respond.")
        }
    }
}

/// Satır tabanlı TCP bağlantısı. IMAP için doğrudan TLS, SMTP için STARTTLS ile sonradan TLS'e geçer.
actor StreamConnection {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer: [UInt8] = []
    private var start = 0
    private var isOpen = false

    init(host: String, port: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        // Okuma ve yazma kendi süre sınırlarını kullanır; IDLE dakikalarca sessiz bekleyebilir
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: host, port: port)
    }

    func open(tls: Bool) {
        task.resume()
        if tls { task.startSecureConnection() }
        isOpen = true
    }

    func startTLS() {
        task.startSecureConnection()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            task.write(data, timeout: 60) { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }

    /// CRLF hariç bir satır. timeout: bu süre hiç veri gelmezse hata (IDLE'da uzun tutulur)
    func readLine(timeout: TimeInterval = 120) async throws -> [UInt8] {
        while true {
            if let newline = buffer[start...].firstIndex(of: 0x0A) {
                var end = newline
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                let line = Array(buffer[start..<end])
                start = newline + 1
                compact()
                return line
            }
            try await fill(timeout: timeout)
        }
    }

    func read(count: Int) async throws -> [UInt8] {
        while buffer.count - start < count {
            try await fill()
        }
        let data = Array(buffer[start..<(start + count)])
        start += count
        compact()
        return data
    }

    private func fill(timeout: TimeInterval = 120) async throws {
        let (data, atEOF) = try await readChunk(timeout: timeout)
        if let data, !data.isEmpty {
            buffer.append(contentsOf: data)
        } else if atEOF {
            throw ConnectionError.closed
        } else {
            throw ConnectionError.timedOut
        }
    }

    private func readChunk(timeout: TimeInterval) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout) { data, atEOF, error in
                once.resume(error.map { .failure($0) } ?? .success((data, atEOF)))
            }
        }
    }

    private func compact() {
        if start > 512 * 1024 || start == buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        task.closeWrite()
        task.cancel()
        session.invalidateAndCancel()
    }
}

/// CFNetwork bazı ağ hatalarında (ör. uykudan uyanınca kopan bağlantı) tamamlanma bloğunu iki kez çağırabiliyor.
/// Swift'in hazır async sarmalayıcısı ikinci çağrıda çöküyor; burada yalnızca ilk sonuç kullanılır.
nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
