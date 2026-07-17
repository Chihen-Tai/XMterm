package struct TerminalGridSize: Equatable, Hashable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = max(2, columns)
        self.rows = max(1, rows)
    }

    public static func calculating(
        pointWidth: Double,
        pointHeight: Double,
        cellWidth: Double,
        cellHeight: Double
    ) throws -> Self {
        guard pointWidth.isFinite,
              pointHeight.isFinite,
              cellWidth.isFinite,
              cellHeight.isFinite,
              pointWidth >= 0,
              pointHeight >= 0,
              cellWidth > 0,
              cellHeight > 0 else {
            throw TerminalGridSizeError.invalidDimensions
        }

        return Self(
            columns: max(2, clampedFloor(pointWidth / cellWidth)),
            rows: max(1, clampedFloor(pointHeight / cellHeight))
        )
    }

    private static func clampedFloor(_ value: Double) -> UInt16 {
        guard value < Double(UInt16.max) else { return .max }
        return UInt16(value.rounded(.down))
    }
}

package enum TerminalGridSizeError: Error, Equatable, Sendable {
    case invalidDimensions
}

package struct TerminalResizeCoalescingState: Equatable, Sendable {
    public let lastEmittedSize: TerminalGridSize?
    public let pendingSize: TerminalGridSize?

    public init(
        lastEmittedSize: TerminalGridSize? = nil,
        pendingSize: TerminalGridSize? = nil
    ) {
        self.lastEmittedSize = lastEmittedSize
        self.pendingSize = pendingSize
    }

    public func receiving(_ size: TerminalGridSize) -> Self {
        guard size != lastEmittedSize else {
            return Self(lastEmittedSize: lastEmittedSize, pendingSize: nil)
        }
        return Self(lastEmittedSize: lastEmittedSize, pendingSize: size)
    }

    public func firing() -> (state: Self, emittedSize: TerminalGridSize?) {
        guard let pendingSize else { return (self, nil) }
        return (
            Self(lastEmittedSize: pendingSize, pendingSize: nil),
            pendingSize
        )
    }

    public func cancelling() -> Self {
        Self(lastEmittedSize: lastEmittedSize, pendingSize: nil)
    }
}
