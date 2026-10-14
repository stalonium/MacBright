import CoreGraphics

/// Scales a display's gamma (transfer) table.
///
/// While the display is in EDR mode, output values above 1.0 land in the HDR
/// headroom, so multiplying the table brightens all regular SDR content past
/// the normal maximum. The original table is captured first and multiplied, so
/// any calibration or color profile curve is preserved.
///
/// macOS discards custom gamma tables when the owning process exits, so even a
/// crash can't leave the display stuck in a boosted state.
@MainActor
final class GammaBooster {
    let displayID: CGDirectDisplayID
    private(set) var factor: Double = 1

    private var baseR: [CGGammaValue] = []
    private var baseG: [CGGammaValue] = []
    private var baseB: [CGGammaValue] = []

    init?(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        guard capture() else { return nil }
    }

    /// Remembers the display's current table as the unboosted baseline.
    @discardableResult
    func capture() -> Bool {
        guard var table = Self.read(displayID) else { return false }

        // A sane SDR table never exceeds 1.0. If it does, something (maybe
        // another booster) already scaled it, and multiplying again would
        // compound the boost. Fall back to the system's ColorSync table.
        if table.max > 1.001 {
            CGDisplayRestoreColorSyncSettings()
            guard let restored = Self.read(displayID), restored.max <= 1.001 else { return false }
            table = restored
        }

        (baseR, baseG, baseB) = (table.r, table.g, table.b)
        return true
    }

    func apply(_ newFactor: Double) {
        factor = min(max(newFactor, 1), BoostController.maxFactor)
        let s = CGGammaValue(factor)
        CGSetDisplayTransferByTable(
            displayID,
            UInt32(baseR.count),
            baseR.map { $0 * s },
            baseG.map { $0 * s },
            baseB.map { $0 * s }
        )
    }

    /// Writes the captured baseline back.
    func restore() {
        apply(1)
    }

    /// Whether the table on the display is still the one we last wrote. macOS
    /// resets gamma on some display events, and other apps may overwrite it.
    func isIntact() -> Bool {
        guard let table = Self.read(displayID), table.r.count == baseR.count else { return false }
        let s = CGGammaValue(factor)
        for i in [baseR.count / 2, baseR.count - 1] {
            if abs(table.r[i] - baseR[i] * s) > 0.003
                || abs(table.g[i] - baseG[i] * s) > 0.003
                || abs(table.b[i] - baseB[i] * s) > 0.003 {
                return false
            }
        }
        return true
    }

    /// The largest value in the display's current table. Used by the self-test.
    static func currentPeak(of displayID: CGDirectDisplayID) -> CGGammaValue? {
        read(displayID)?.max
    }

    private struct Table {
        var r, g, b: [CGGammaValue]
        var max: CGGammaValue { Swift.max(r.max() ?? 0, g.max() ?? 0, b.max() ?? 0) }
    }

    /// Always 256 entries: on Apple Silicon the display reports a capacity of
    /// 1024, but a full-size table with values above 1.0 is silently dropped,
    /// while a 256-entry one is accepted (and interpolated by the system).
    private static let tableSize: UInt32 = 256

    private static func read(_ displayID: CGDirectDisplayID) -> Table? {
        let capacity = min(tableSize, CGDisplayGammaTableCapacity(displayID))
        guard capacity > 0 else { return nil }

        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r
        var b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &count) == .success,
              count > 1 else { return nil }

        let n = Int(count)
        return Table(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
    }
}
