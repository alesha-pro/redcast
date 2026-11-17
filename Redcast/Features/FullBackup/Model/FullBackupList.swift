import Foundation

/// An array that decodes item by item: one record from a newer build is dropped, not the section.
struct FullBackupList<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var items: [Element]
    /// Records this build couldn't read; counted so the import can say so.
    var dropped = 0

    init(_ items: [Element]) {
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                _ = try container.decode(Skipped.self)
                dropped += 1
            }
        }
        self.items = items
        self.dropped = dropped
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.items == rhs.items }

    /// Advances past one element of any shape.
    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

/// A preference value an extension stores: text, a number, a switch, or an app's path.
enum FullBackupValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case application(String)

    private enum CodingKeys: String, CodingKey { case application }

    init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
            let path = try? keyed.decode(String.self, forKey: .application)
        {
            self = .application(path)
            return
        }
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try value.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .application(let path):
            var keyed = encoder.container(keyedBy: CodingKeys.self)
            try keyed.encode(path, forKey: .application)
        case .string(let text):
            var value = encoder.singleValueContainer()
            try value.encode(text)
        case .number(let number):
            var value = encoder.singleValueContainer()
            try value.encode(number)
        case .bool(let flag):
            var value = encoder.singleValueContainer()
            try value.encode(flag)
        }
    }
}
