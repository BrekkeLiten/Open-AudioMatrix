import Foundation

public enum SourceLevelCodec {
    public static func channelKey(bundleID: String, monoChannel: Int) -> String {
        "\(bundleID)|\(monoChannel)"
    }

    public static func parseChannelKey(_ key: String) -> (bundleID: String, monoChannel: Int)? {
        guard let separator = key.lastIndex(of: "|") else { return nil }
        let bundleID = String(key[..<separator])
        let channelPart = String(key[key.index(after: separator)...])
        guard let monoChannel = Int(channelPart), !bundleID.isEmpty else { return nil }
        return (bundleID, monoChannel)
    }
}
