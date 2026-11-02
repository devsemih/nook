import os

/// Tanılama logları. Yalnızca olaylar ve sayılar yazılır; adres, şifre, token ve mail içeriği yazılmaz.
/// İzlemek için: log stream --predicate 'subsystem == "com.odinstudio.posta"'
nonisolated enum Log {
    static let sync = Logger(subsystem: "com.odinstudio.posta", category: "sync")
    static let notifications = Logger(subsystem: "com.odinstudio.posta", category: "notifications")
    static let app = Logger(subsystem: "com.odinstudio.posta", category: "app")
}
