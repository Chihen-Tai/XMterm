import Foundation

public enum RemotePathValidationError: Error, Equatable, Sendable {
    case emptyComponent
    case slashInComponent
    case nulByte
    case componentTooLong(maximum: Int, actual: Int)
    case pathMustBeAbsolute
    case pathTooLong(maximum: Int, actual: Int)
}

public struct RemotePathComponent: Hashable, Sendable {
    public static let maximumRawByteCount = 4 * 1_024

    private let storage: Data

    public var rawBytes: [UInt8] {
        Array(storage)
    }

    public var losslessString: String? {
        String(data: storage, encoding: .utf8)
    }

    public var escapedDisplayString: String {
        RemoteByteDisplay.escaped(storage)
    }

    public init(rawBytes: [UInt8]) throws {
        guard !rawBytes.isEmpty else {
            throw RemotePathValidationError.emptyComponent
        }
        guard rawBytes.count <= Self.maximumRawByteCount else {
            throw RemotePathValidationError.componentTooLong(
                maximum: Self.maximumRawByteCount,
                actual: rawBytes.count
            )
        }
        guard !rawBytes.contains(0x2F) else {
            throw RemotePathValidationError.slashInComponent
        }
        guard !rawBytes.contains(0x00) else {
            throw RemotePathValidationError.nulByte
        }
        storage = Data(rawBytes)
    }
}

public struct RemotePath: Hashable, Sendable {
    public static let maximumRawByteCount = 32 * 1_024
    public static let root = Self(
        validatedComponents: ArraySlice<RemotePathComponent>()
    )

    private let storedComponents: ArraySlice<RemotePathComponent>

    public var components: [RemotePathComponent] {
        Array(storedComponents)
    }

    public var rawBytes: [UInt8] {
        guard !storedComponents.isEmpty else { return [0x2F] }
        return storedComponents.flatMap { [0x2F] + $0.rawBytes }
    }

    public var losslessString: String? {
        String(bytes: rawBytes, encoding: .utf8)
    }

    public var escapedDisplayString: String {
        guard !storedComponents.isEmpty else { return "/" }
        return storedComponents
            .map(\.escapedDisplayString)
            .joined(separator: "/")
            .withLeadingSlash
    }

    public var parent: Self? {
        guard !storedComponents.isEmpty else { return nil }
        return Self(validatedComponents: storedComponents.dropLast())
    }

    public var breadcrumbPaths: [Self] {
        (0...storedComponents.count).map { componentCount in
            Self(validatedComponents: storedComponents.prefix(componentCount))
        }
    }

    public var posixShellQuotedString: String? {
        losslessString.map { path in
            "'\(path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        }
    }

    public init(rawBytes: [UInt8]) throws {
        guard rawBytes.first == 0x2F else {
            throw RemotePathValidationError.pathMustBeAbsolute
        }
        guard rawBytes.count <= Self.maximumRawByteCount else {
            throw RemotePathValidationError.pathTooLong(
                maximum: Self.maximumRawByteCount,
                actual: rawBytes.count
            )
        }
        storedComponents = try Self.parseComponents(from: rawBytes)[...]
    }

    public init(components: [RemotePathComponent]) throws {
        let byteCount = Self.canonicalRawByteCount(for: components)
        guard byteCount <= Self.maximumRawByteCount else {
            throw RemotePathValidationError.pathTooLong(
                maximum: Self.maximumRawByteCount,
                actual: byteCount
            )
        }
        storedComponents = components[...]
    }

    public func appending(_ component: RemotePathComponent) throws -> Self {
        try Self(components: storedComponents + [component])
    }

    private init(validatedComponents: ArraySlice<RemotePathComponent>) {
        storedComponents = validatedComponents
    }

    var lastComponent: RemotePathComponent? {
        storedComponents.last
    }

    private static func parseComponents(
        from bytes: [UInt8]
    ) throws -> [RemotePathComponent] {
        try bytes.split(separator: 0x2F, omittingEmptySubsequences: true).map { bytes in
            try RemotePathComponent(rawBytes: Array(bytes))
        }
    }

    private static func canonicalRawByteCount(
        for components: [RemotePathComponent]
    ) -> Int {
        guard !components.isEmpty else { return 1 }
        return components.reduce(0) { count, component in
            count + 1 + component.rawBytes.count
        }
    }
}

enum RemoteByteDisplay {
    private enum Unit {
        case scalar(Unicode.Scalar)
        case invalidByte(UInt8)
    }

    static func escaped(_ data: Data) -> String {
        let units = decodedUnits(in: Array(data))
        var result = ""
        var scalarRun: [Unicode.Scalar] = []

        for unit in units {
            switch unit {
            case let .scalar(scalar):
                scalarRun.append(scalar)
            case let .invalidByte(byte):
                result += RemoteUnicodeSafety.escaped(scalarRun)
                scalarRun.removeAll(keepingCapacity: true)
                result += hexadecimalEscape(byte)
            }
        }
        result += RemoteUnicodeSafety.escaped(scalarRun)
        return result
    }

    private static func decodedUnits(in bytes: [UInt8]) -> [Unit] {
        var units: [Unit] = []
        var index = 0

        while index < bytes.count {
            if bytes[index] < 0x80,
               let scalar = Unicode.Scalar(Int(bytes[index])) {
                units.append(.scalar(scalar))
                index += 1
            } else if let decoded = decodedScalar(in: bytes, at: index) {
                units.append(.scalar(decoded.scalar))
                index += decoded.length
            } else {
                units.append(.invalidByte(bytes[index]))
                index += 1
            }
        }
        return units
    }

    private static func decodedScalar(
        in bytes: [UInt8],
        at index: Int
    ) -> (scalar: Unicode.Scalar, length: Int)? {
        guard let length = utf8SequenceLength(for: bytes[index]),
              index + length <= bytes.count,
              let text = String(bytes: bytes[index..<(index + length)], encoding: .utf8),
              text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else {
            return nil
        }
        return (scalar, length)
    }

    private static func utf8SequenceLength(for leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }

    private static func hexadecimalEscape(_ byte: UInt8) -> String {
        let hexadecimal = String(byte, radix: 16, uppercase: true)
        return "\\x\(hexadecimal.count == 1 ? "0" + hexadecimal : hexadecimal)"
    }
}

private extension String {
    var withLeadingSlash: String {
        "/" + self
    }
}
