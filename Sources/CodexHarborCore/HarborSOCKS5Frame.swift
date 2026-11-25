import Foundation

/// Small RFC 1928 framing helpers for the gateway. TCP payloads and DNS
/// resolution remain with the selected engine; only the control exchange
/// is inspected to bound unsupported or unsafe UDP associations.
public enum HarborSOCKS5Frame {
    public enum Command: UInt8, Sendable { case connect = 1, bind = 2, udpAssociate = 3 }

    public struct Address: Equatable, Sendable {
        public let host: String
        public let port: UInt16
        public let isUnspecified: Bool

        public var isLoopback: Bool { HarborGatewayConfiguration.isLoopback(host) }
        public var isLocalAssociation: Bool { isLoopback || isUnspecified }
    }

    public static func parseAddress(_ frame: Data) -> Address? {
        let bytes = Array(frame)
        guard bytes.count >= 7, bytes[0] == 5, bytes[2] == 0 else { return nil }
        let address: String
        let portIndex: Int
        switch bytes[3] {
        case 1:
            guard bytes.count == 10 else { return nil }
            address = bytes[4..<8].map(String.init).joined(separator: ".")
            portIndex = 8
        case 3:
            let length = Int(bytes[4])
            guard length > 0, bytes.count == 7 + length,
                  let host = String(bytes: bytes[5..<(5 + length)], encoding: .utf8),
                  !host.isEmpty, host.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else { return nil }
            address = host
            portIndex = 5 + length
        case 4:
            guard bytes.count == 22 else { return nil }
            address = stride(from: 4, to: 20, by: 2).map { index in
                String(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]), radix: 16)
            }.joined(separator: ":")
            portIndex = 20
        default: return nil
        }
        let canonical = HarborIPAddress.normalizedLiteral(address) ?? address
        let port = UInt16(bytes[portIndex]) << 8 | UInt16(bytes[portIndex + 1])
        return Address(host: canonical, port: port, isUnspecified: canonical == "0.0.0.0" || canonical == "::")
    }

    public static func command(_ frame: Data) -> Command? {
        guard parseAddress(frame) != nil else { return nil }
        return Command(rawValue: frame[frame.startIndex + 1])
    }

    public static func permitsUDPReply(_ frame: Data, forbiddenPorts: Set<UInt16>) -> Bool {
        guard let address = parseAddress(frame), frame[frame.startIndex + 1] == 0,
              address.isLoopback, !address.isUnspecified, address.port != 0,
              !forbiddenPorts.contains(address.port) else { return false }
        return true
    }

    /// RFC 1928 UDP header. Fragmentation is deliberately unsupported:
    /// accepting only FRAG=0 prevents unbounded reassembly state.
    public static func udpDestination(_ datagram: Data) -> Address? {
        let bytes = Array(datagram.prefix(262))
        guard datagram.count >= 7, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0 else { return nil }
        let length: Int
        switch bytes[3] {
        case 1: length = 10
        case 4: length = 22
        case 3: length = 7 + Int(bytes[4])
        default: return nil
        }
        guard datagram.count >= length, bytes.count >= length else { return nil }
        var frame = Data(bytes.prefix(length))
        frame[0] = 5
        guard let address = parseAddress(frame), address.port != 0, !address.isUnspecified else { return nil }
        return address
    }

    public static func udpAssociationRequest() -> Data {
        Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    public static func loopbackReply(port: UInt16) -> Data {
        Data([5, 0, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)])
    }

    public static func failure(_ code: UInt8) -> Data {
        Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}
