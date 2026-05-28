// MumblurCore/Sources/MumblurCore/WERNormalizer.swift
import Foundation

public struct WERNormalizer: Sendable {
    public init() {}

    public func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == " " { return Character(scalar) }
            return " "
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    public func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}
