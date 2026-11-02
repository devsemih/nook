import Foundation

/// IMAP yanıtlarının ayrıştırılmış hali: atom, dize (tırnaklı veya literal), liste, NIL
nonisolated enum IMAPValue: Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case none

    var text: String? {
        switch self {
        case .atom(let value): value
        case .string(let data): String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        default: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let value): Data(value.utf8)
        default: nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let values) = self { return values }
        return nil
    }

    var number: UInt32? { text.flatMap { UInt32($0) } }
}

/// Literal'lar dahil ham yanıt baytlarını değer ağacına çevirir
nonisolated struct IMAPTokenizer {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ bytes: [UInt8]) -> [IMAPValue] {
        var tokenizer = IMAPTokenizer(bytes)
        return tokenizer.values(until: nil)
    }

    private mutating func values(until close: UInt8?) -> [IMAPValue] {
        var result: [IMAPValue] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x0D, 0x0A:
                index += 1
            case 0x29: // )
                index += 1
                if close == 0x29 { return result }
            case 0x28: // (
                index += 1
                result.append(.list(values(until: 0x29)))
            case 0x22: // "
                result.append(.string(quoted()))
            case 0x7B: // {
                if let literal = literal() {
                    result.append(.string(literal))
                } else {
                    result.append(.atom(atom()))
                }
            default:
                let value = atom()
                result.append(value.uppercased() == "NIL" ? .none : .atom(value))
            }
        }
        return result
    }

    private mutating func quoted() -> Data {
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C, index + 1 < bytes.count {
                output.append(bytes[index + 1])
                index += 2
                continue
            }
            index += 1
            if byte == 0x22 { break }
            output.append(byte)
        }
        return Data(output)
    }

    private mutating func literal() -> Data? {
        let saved = index
        index += 1
        var digits: [UInt8] = []
        while index < bytes.count, bytes[index] != 0x7D {
            if bytes[index] != 0x2B { digits.append(bytes[index]) }
            index += 1
        }
        guard index < bytes.count, let count = Int(String(decoding: digits, as: UTF8.self)) else {
            index = saved
            return nil
        }
        index += 1 // }
        if index < bytes.count, bytes[index] == 0x0D { index += 1 }
        if index < bytes.count, bytes[index] == 0x0A { index += 1 }
        let end = min(index + count, bytes.count)
        let data = Data(bytes[index..<end])
        index = end
        return data
    }

    /// Köşeli parantez içindeki boşlukları da kapsar: BODY[HEADER.FIELDS (FROM TO)]<0>
    private mutating func atom() -> String {
        var output: [UInt8] = []
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if depth == 0 && (byte == 0x20 || byte == 0x28 || byte == 0x29 || byte == 0x0D || byte == 0x0A) { break }
            if byte == 0x5B { depth += 1 }
            if byte == 0x5D { depth = max(0, depth - 1) }
            output.append(byte)
            index += 1
        }
        if output.isEmpty { index += 1 }
        return String(decoding: output, as: UTF8.self)
    }
}

nonisolated extension Array where Element == UInt32 {
    /// [1,2,3,7,9,10] → "1:3,7,9:10"
    var imapSequenceSet: String {
        let sorted = Set(self).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            ranges.append(end == index ? "\(sorted[index])" : "\(sorted[index]):\(sorted[end])")
            index = end + 1
        }
        return ranges.joined(separator: ",")
    }
}
