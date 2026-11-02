import Foundation

/// Giriş ve doğrulama maillerindeki tek kullanımlık kodu bulur. Kod, "kod", "code", "OTP" gibi bir sözcüğün
/// yakınındaki 4–8 haneli sayı (ya da 123 456 biçimi) ya da sözcüğün hemen yanındaki harf-rakam karışımıdır.
/// Yıllar, tutarlar, tarihler ve telefon numaraları elenir.
nonisolated enum VerificationCode {
    static func find(subject: String, text: String) -> String? {
        // Konu önce gelir: kodlar çoğu zaman konuda da yazar
        let source = subject + "\n" + String(text.prefix(2500))
        let lower = source.lowercased()
        let strong = keywordRanges(of: strongKeywords, in: lower)
        let keywords = strong + keywordRanges(of: weakKeywords, in: lower)
        guard !keywords.isEmpty else { return nil }
        let characters = Array(lower)

        var best: (code: String, distance: Int)?
        for candidate in candidates(in: source) {
            let distance = keywords.map { keyword in
                if candidate.range.lowerBound >= keyword.upperBound { return candidate.range.lowerBound - keyword.upperBound }
                if keyword.lowerBound >= candidate.range.upperBound { return keyword.lowerBound - candidate.range.upperBound }
                return 0
            }.min() ?? .max
            // Yalnızca "code" gibi genel bir sözcük varsa ya da kod harf içeriyorsa sözcüğün hemen yanında olmalı
            let limit = candidate.isAlphanumeric || strong.isEmpty ? 18 : 160
            guard distance <= limit else { continue }
            // "Order 99812345", "Sipariş no 5521" gibi numaralar kod değildir
            if describesOtherNumber(before: candidate.range.lowerBound, in: characters) { continue }
            if best == nil || distance < best!.distance { best = (candidate.code, distance) }
        }
        return best?.code
    }

    // MARK: Sözcükler

    private static let strongKeywords = [
        "verification", "security code", "login code", "sign-in code", "sign in code", "confirmation code",
        "one-time", "one time", "passcode", "otp", "2fa", "two-factor", "authentication code", "access code",
        "your code", "code is", "doğrulama", "dogrulama", "güvenlik kodu", "guvenlik kodu", "tek kullanımlık",
        "tek kullanimlik", "onay kodu", "giriş kodu", "giris kodu", "şifreniz", "sifreniz", "kodunuz",
    ]

    private static let weakKeywords = ["code", "kod", "pin"]

    /// Kendisinden sonra gelen sayıyı kod olmaktan çıkaran sözcükler
    private static let numberWords: Set<String> = [
        "order", "invoice", "tracking", "ref", "reference", "no", "number", "account", "case", "ticket", "promo",
        "sipariş", "siparis", "fatura", "takip", "numara", "numarası", "numarasi", "hesap",
    ]

    private static let codeWords: Set<String> = ["code", "kod", "kodu", "kodunuz", "passcode", "pin", "otp"]

    /// Sayıdan geriye doğru en fazla üç sözcük: bir "kod" sözcüğüne varmadan "sipariş", "fatura" gibi biri çıkarsa
    private static func describesOtherNumber(before index: Int, in characters: [Character]) -> Bool {
        var end = index
        for _ in 0..<3 {
            while end > 0, !characters[end - 1].isLetter { end -= 1 }
            var start = end
            while start > 0, characters[start - 1].isLetter { start -= 1 }
            guard start < end else { return false }
            let word = String(characters[start..<end])
            if codeWords.contains(word) { return false }
            if numberWords.contains(word) { return true }
            end = start
        }
        return false
    }

    /// Sözcüklerin geçtiği yerler (karakter konumu olarak)
    private static func keywordRanges(of keywords: [String], in lower: String) -> [Range<Int>] {
        let characters = Array(lower)
        var ranges: [Range<Int>] = []
        for keyword in keywords {
            let needle = Array(keyword)
            guard needle.count <= characters.count else { continue }
            var index = 0
            while index <= characters.count - needle.count {
                if characters[index..<index + needle.count].elementsEqual(needle) {
                    // "code" ve "kod" başka sözcüklerin içinde de geçer (barcode, kodak); başı sözcük başı olmalı
                    let startsWord = index == 0 || !characters[index - 1].isLetter
                    if startsWord { ranges.append(index..<index + needle.count) }
                    index += needle.count
                } else {
                    index += 1
                }
            }
        }
        return ranges
    }

    // MARK: Adaylar

    private struct Candidate {
        var code: String
        var range: Range<Int>
        var isAlphanumeric: Bool
    }

    private static func candidates(in source: String) -> [Candidate] {
        let characters = Array(source)
        var result: [Candidate] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isASCII, characters[index].isLetter || characters[index].isNumber else {
                index += 1
                continue
            }
            // Bir sözcüğü (harf, rakam) sonuna kadar oku
            var end = index
            while end < characters.count, characters[end].isASCII, characters[end].isLetter || characters[end].isNumber { end += 1 }
            var token = String(characters[index..<end])
            var tokenEnd = end

            // 123 456 ya da 123-456: iki üçlü birleşir
            if token.count == 3, token.allSatisfy(\.isNumber), end + 4 <= characters.count,
               characters[end] == " " || characters[end] == "-",
               characters[end + 1..<end + 4].allSatisfy(\.isNumber),
               end + 4 == characters.count || !(characters[end + 4].isLetter || characters[end + 4].isNumber) {
                token += String(characters[end + 1..<end + 4])
                tokenEnd = end + 4
            }

            let before = index > 0 ? characters[index - 1] : " "
            let after = tokenEnd < characters.count ? characters[tokenEnd] : " "
            let afterNext = tokenEnd + 1 < characters.count ? characters[tokenEnd + 1] : " "
            defer { index = tokenEnd }

            // Tutar, yüzde, tarih, saat, sürüm, telefon, adres parçası
            if "$€£₺#+/\\@.:,".contains(before) || "%/@".contains(after) { continue }
            if (after == "." || after == ":" || after == ",") && afterNext.isNumber { continue }
            if before == "-" && index >= 2 && characters[index - 2].isNumber { continue }

            let digits = token.filter(\.isNumber).count
            if token.allSatisfy(\.isNumber) {
                guard (4...8).contains(token.count) else { continue }
                if token.count == 4, let year = Int(token), (1900...2099).contains(year) { continue }
                result.append(Candidate(code: token, range: index..<tokenEnd, isAlphanumeric: false))
            } else if (6...8).contains(token.count), digits >= 2, token == token.uppercased() {
                // K7P2QX gibi büyük harf ve rakam karışımı
                result.append(Candidate(code: token, range: index..<tokenEnd, isAlphanumeric: true))
            }
        }
        return result
    }
}
