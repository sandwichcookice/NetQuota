import Foundation

/// App 的版本號，對應 git 的版本 tag（v1.2、v1.2.1）。
/// 第三碼是修 bug 的版本，前兩碼變動是新功能。
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 接受 "1.2"、"1.2.1"、"v1.2.1"，其他格式（例如 "v1.2-beta"）回傳 nil。
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// 顯示用；patch 為 0 時省略（1.2 而不是 1.2.0），和 tag 的寫法一致。
    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    public var tag: String { "v\(description)" }

    /// 和 `other` 相比只有第三碼不同，也就是修 bug 的版本。
    public func isPatchUpdate(from other: AppVersion) -> Bool {
        major == other.major && minor == other.minor && patch != other.patch
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// 從 `git ls-remote --tags --refs` 的輸出（`<sha>\trefs/tags/v1.2`）找出最大的版本。
    public static func latest(fromLsRemote output: String) -> AppVersion? {
        output.split(whereSeparator: \.isNewline).compactMap { line -> AppVersion? in
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/v") else { return nil }
            return AppVersion(String(ref.dropFirst("refs/tags/".count)))
        }.max()
    }
}
