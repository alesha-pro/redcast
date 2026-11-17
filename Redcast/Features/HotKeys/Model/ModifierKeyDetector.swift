import Foundation

struct ModifierKeyDetector: Sendable {
    enum Event: Equatable {
        case pressed(ModifierKey)
        case released(ModifierKey, doubleTap: Bool, held: Bool)
        case cancelled
    }

    static let resolutionWindow: Duration = .seconds(
        DoubleTapDetector.maxGap + DoubleTapDetector.maxHold + 0.02)

    private(set) var held: Set<ModifierKey> = []
    private var press: (key: ModifierKey, startedAt: TimeInterval)?
    private var pendingTap: (key: ModifierKey, releasedAt: TimeInterval)?

    /// Fork: `holding` is the key held to talk, which Shift may join so ⇧Tab reaches the capsule.
    mutating func handle(
        _ keys: Set<ModifierKey>, at now: TimeInterval, holding: ModifierKey? = nil
    ) -> Event? {
        let previous = held
        held = keys
        guard keys != previous else { return nil }
        if let holding, press?.key == holding, !keys.isEmpty,
            keys.subtracting([holding]).isSubset(of: [.leftShift, .rightShift])
        {
            guard !keys.contains(holding) else { return nil }
            cancel()
            return .released(holding, doubleTap: false, held: true)
        }
        if keys.isEmpty {
            guard let press else { return nil }
            self.press = nil
            let isHeld = now - press.startedAt > DoubleTapDetector.maxHold
            let isDouble =
                !isHeld && pendingTap?.key == press.key
                && press.startedAt - (pendingTap?.releasedAt ?? 0) <= DoubleTapDetector.maxGap
            pendingTap = isHeld || isDouble ? nil : (press.key, now)
            return .released(press.key, doubleTap: isDouble, held: isHeld)
        }
        guard previous.isEmpty, keys.count == 1, let key = keys.first else {
            cancel()
            return .cancelled
        }
        if pendingTap?.key != key { pendingTap = nil }
        press = (key, now)
        return .pressed(key)
    }

    mutating func cancel() {
        press = nil
        pendingTap = nil
    }

    mutating func reset() {
        held = []
        cancel()
    }
}
