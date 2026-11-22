import CoreBluetooth
import Foundation

/// Even Realities G2 BLE UUIDs and advertisement parsers.
public enum G2Constants {
    public static let uuidBase = "00002760-08C2-11E1-9073-0E8AC72E"

    public static let serviceControl = CBUUID(string: "\(uuidBase)5450")
    public static let charWrite = CBUUID(string: "\(uuidBase)5401")
    public static let charNotify = CBUUID(string: "\(uuidBase)5402")
    public static let charAppHello = CBUUID(string: "\(uuidBase)5403")

    public static let serviceAudio = CBUUID(string: "\(uuidBase)6450")
    public static let charAudioNotify = CBUUID(string: "\(uuidBase)6402")

    public static let serviceFile = CBUUID(string: "\(uuidBase)7450")
    public static let charFileWrite = CBUUID(string: "\(uuidBase)7401")
    public static let charFileNotify = CBUUID(string: "\(uuidBase)7402")

    public static let manufacturerCompanyID: UInt16 = 0x5245 // "RE"

    public enum LensSide: String, Codable, CaseIterable {
        case left = "L"
        case right = "R"

        public var displayName: String {
            self == .left ? "좌측(L)" : "우측(R)"
        }
    }

    public struct ParsedLensName: Equatable {
        public let pairId: String
        public let side: LensSide
        public let macTail: String
    }

    /// Parses names like `"Even G2_42_L_ABCDEF"` into pair ID, side, and MAC suffix.
    public static func parseLensName(_ name: String?) -> ParsedLensName? {
        guard let name, !name.isEmpty else { return nil }
        let pattern = #"G2_(\w+?)_([LR])_([0-9A-Fa-f]{6})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges == 4,
              let r1 = Range(match.range(at: 1), in: name),
              let r2 = Range(match.range(at: 2), in: name),
              let r3 = Range(match.range(at: 3), in: name)
        else { return nil }

        let pairId = String(name[r1])
        let side: LensSide = (String(name[r2]) == "R") ? .right : .left
        let macTail = String(name[r3]).uppercased()
        return ParsedLensName(pairId: pairId, side: side, macTail: macTail)
    }
}
