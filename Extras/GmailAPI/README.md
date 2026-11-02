# Gmail API sağlayıcısı (kullanılmıyor)

Gmail'e kendi Google Cloud projen, OAuth (PKCE) ve Gmail REST API ile bağlanan sağlayıcı.
Google, OAuth uygulamasını yayına almak için ana sayfa ve gizlilik politikası adresi istediğinden
şimdilik Gmail uygulama şifresiyle IMAP/SMTP üzerinden bağlanıyor (`Posta/Providers/IMAP`).

Yeniden kullanmak için dosyaları `Posta/Providers/Gmail` altına taşı, `SyncEngine.provider(for:)`
içinde Gmail için `GmailProvider`'ı seç ve hesap ekleme akışına OAuth adımını geri ekle.
