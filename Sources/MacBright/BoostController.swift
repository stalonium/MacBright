import AppKit
import IOKit.ps
import ServiceManagement

enum PauseReason: Equatable {
    case thermal
    case lowPowerMode
    case lowBattery(Int)
    case asleep

    var text: String {
        switch self {
        case .thermal: "Mac is running hot"
        case .lowPowerMode: "Low Power Mode is on"
        case .lowBattery(let percent): "Battery at \(percent)%"
        case .asleep: "Display asleep"
        }
    }
}

enum BoostStatus: Equatable {
    case off
    case noBuiltInDisplay
    case waitingForHDR
    case active
    /// Boosting, but capped below the requested factor by the headroom macOS grants.
    case limited
    case paused(PauseReason)
    /// Automatic mode, and it isn't bright enough around the Mac to need a boost.
    case standby
    case noLightSensor
}

/// Owns the boost: decides whether it should be on, how strong, and fades the
/// gamma table there. Re-evaluates every second and on system events.
///
/// Safety model: the effective factor never exceeds the EDR headroom macOS
/// reports for the panel right now. macOS lowers that headroom on its own when
/// the display gets hot or power-limited, so the boost backs off with it.
/// On top of that the boost pauses entirely on thermal pressure, low battery,
/// Low Power Mode and sleep.
@MainActor
final class BoostController: ObservableObject {
    static let shared = BoostController()

    static let maxFactor = 2.0
    static let defaultFactor = 1.5
    static let batteryThreshold = 20
    static let autoOffChoices = [0, 15, 30, 60, 120]
    static let startLuxChoices: [Double] = [1_000, 2_000, 5_000, 10_000]

    /// Boost for an ambient light level in automatic mode: none up to
    /// `startLux`, then an S-curve on a log scale (how we perceive light) that
    /// reaches `maxFactor` at 10× `startLux`.
    static func autoFactor(lux: Double, startLux: Double, maxFactor: Double) -> Double {
        guard lux > startLux else { return 1 }
        let t = min(log10(lux / startLux), 1)
        let eased = t * t * (3 - 2 * t)
        return 1 + (maxFactor - 1) * eased
    }

    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            enabledAt = isEnabled ? Date() : nil
            evaluate()
        }
    }

    @Published var factor: Double {
        didSet { defaults.set(factor, forKey: Keys.factor); evaluate() }
    }

    @Published var pauseOnLowBattery: Bool {
        didSet { defaults.set(pauseOnLowBattery, forKey: Keys.pauseOnLowBattery); evaluate() }
    }

    @Published var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: Keys.pauseInLowPowerMode); evaluate() }
    }

    /// Minutes until the boost switches itself off; 0 means never.
    @Published var autoOffMinutes: Int {
        didSet { defaults.set(autoOffMinutes, forKey: Keys.autoOffMinutes); evaluate() }
    }

    /// Follow the ambient light sensor; `factor` then acts as the maximum boost.
    @Published var isAutomatic: Bool {
        didSet {
            defaults.set(isAutomatic, forKey: Keys.isAutomatic)
            sampleLight()
            evaluate()
        }
    }

    @Published var autoStartLux: Double {
        didSet { defaults.set(autoStartLux, forKey: Keys.autoStartLux); evaluate() }
    }

    @Published private(set) var status: BoostStatus = .off
    @Published private(set) var headroom: Double = 1
    @Published private(set) var targetFactor: Double = 1
    @Published private(set) var minutesUntilAutoOff: Int?
    @Published private(set) var lux: Double?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MacBright: launch at login change failed: \(error)")
            }
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .active, .limited, .waitingForHDR: "sun.max.fill"
        case .standby: "sun.min"
        case .paused, .noLightSensor: "sun.haze"
        case .off, .noBuiltInDisplay: "sun.max"
        }
    }

    private enum Keys {
        static let factor = "factor"
        static let pauseOnLowBattery = "pauseOnLowBattery"
        static let pauseInLowPowerMode = "pauseInLowPowerMode"
        static let autoOffMinutes = "autoOffMinutes"
        static let isAutomatic = "isAutomatic"
        static let autoStartLux = "autoStartLux"
    }

    private let defaults = UserDefaults.standard
    private var trigger: EDRTrigger?
    private var gamma: GammaBooster?
    private var appliedFactor = 1.0
    private var wantsBoost = false
    private var enabledAt: Date?
    private var waitingSince: Date?
    private var isAsleep = false
    private var wakeWork: DispatchWorkItem?
    private var fadeTimer: Timer?
    private var tickTimer: Timer?
    private var battery: (percent: Int, onBattery: Bool)?
    private var batteryCheckedAt = Date.distantPast
    private lazy var sensor = AmbientLightSensor()
    private var smoothedLogLux: Double?
    private var isStandingBy = false

    private init() {
        defaults.register(defaults: [
            Keys.factor: Self.defaultFactor,
            Keys.pauseOnLowBattery: true,
            Keys.pauseInLowPowerMode: true,
            Keys.autoOffMinutes: 0,
            Keys.isAutomatic: false,
            Keys.autoStartLux: 2_000.0,
        ])
        factor = min(max(defaults.double(forKey: Keys.factor), 1), Self.maxFactor)
        pauseOnLowBattery = defaults.bool(forKey: Keys.pauseOnLowBattery)
        pauseInLowPowerMode = defaults.bool(forKey: Keys.pauseInLowPowerMode)
        autoOffMinutes = defaults.integer(forKey: Keys.autoOffMinutes)
        isAutomatic = defaults.bool(forKey: Keys.isAutomatic)
        autoStartLux = defaults.double(forKey: Keys.autoStartLux)

        observeSystem()
        sampleLight()
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleLight()
                self?.evaluate()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    var hasLightSensor: Bool { sensor != nil }

    /// Reads the sensor once per tick and smooths it: quick to follow more
    /// light (stepping outside), slow to follow less (a passing shadow or hand).
    private func sampleLight() {
        guard isAutomatic, let reading = sensor?.lux else {
            lux = nil
            smoothedLogLux = nil
            return
        }
        lux = reading
        let logLux = log10(max(reading, 1))
        if let previous = smoothedLogLux {
            let rate = logLux > previous ? 0.5 : 0.15
            smoothedLogLux = previous + (logLux - previous) * rate
        } else {
            smoothedLogLux = logLux
        }
    }

    // MARK: - Decision

    func evaluate() {
        let screen = Self.builtInScreen()
        headroom = screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) } ?? 1

        if isEnabled, autoOffMinutes > 0, let enabledAt {
            let remaining = Double(autoOffMinutes * 60) - Date().timeIntervalSince(enabledAt)
            if remaining <= 0 {
                isEnabled = false // didSet re-evaluates
                return
            }
            minutesUntilAutoOff = Int((remaining / 60).rounded(.up))
        } else {
            minutesUntilAutoOff = nil
        }

        guard isEnabled else {
            stopBoosting(status: .off)
            return
        }
        guard let screen, let displayID = screen.displayID else {
            stopBoosting(status: .noBuiltInDisplay, immediately: true)
            return
        }
        if let reason = pauseReason() {
            stopBoosting(status: .paused(reason), immediately: reason == .asleep)
            return
        }

        var requested = factor
        if isAutomatic {
            guard let smoothedLogLux else {
                stopBoosting(status: .noLightSensor)
                return
            }
            requested = Self.autoFactor(lux: pow(10, smoothedLogLux), startLux: autoStartLux, maxFactor: factor)
            // Hysteresis, so hovering around the start level doesn't keep
            // flipping the display in and out of HDR mode.
            isStandingBy = requested < (isStandingBy ? 1.03 : 1.01)
            if isStandingBy {
                stopBoosting(status: .standby)
                return
            }
        }

        wantsBoost = true
        activate(on: screen, displayID: displayID)

        guard headroom >= 1.05 else {
            status = .waitingForHDR
            fade(to: 1)
            if let waitingSince, Date().timeIntervalSince(waitingSince) > 5 {
                trigger?.refresh(on: screen)
                self.waitingSince = Date()
            } else if waitingSince == nil {
                waitingSince = Date()
            }
            return
        }
        waitingSince = nil

        var target = min(requested, headroom)
        if isAutomatic, abs(target - targetFactor) < 0.01 {
            target = targetFactor // ignore sensor jitter
        }
        status = target < requested - 0.01 ? .limited : .active
        fade(to: target)
    }

    private func pauseReason() -> PauseReason? {
        if isAsleep { return .asleep }

        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .thermal
        default: break
        }

        if pauseInLowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPowerMode
        }

        if pauseOnLowBattery {
            if Date().timeIntervalSince(batteryCheckedAt) > 10 {
                battery = Self.readBattery()
                batteryCheckedAt = Date()
            }
            if let battery, battery.onBattery, battery.percent <= Self.batteryThreshold {
                return .lowBattery(battery.percent)
            }
        }
        return nil
    }

    // MARK: - Applying

    private func activate(on screen: NSScreen, displayID: CGDirectDisplayID) {
        if trigger == nil { trigger = EDRTrigger() }
        trigger?.show(on: screen)

        if let gamma, gamma.displayID != displayID {
            gamma.restore()
            self.gamma = nil
            appliedFactor = 1
        }

        if gamma == nil {
            gamma = GammaBooster(displayID: displayID)
        } else if let gamma, fadeTimer == nil, !gamma.isIntact() {
            // Something reset the table; adopt it as the new baseline and reapply.
            gamma.capture()
            gamma.apply(appliedFactor)
        }
    }

    private func stopBoosting(status newStatus: BoostStatus, immediately: Bool = false) {
        wantsBoost = false
        waitingSince = nil
        status = newStatus
        if immediately {
            teardown()
        } else {
            fade(to: 1)
        }
    }

    private func fade(to target: Double) {
        targetFactor = target
        if abs(appliedFactor - target) < 0.001 {
            fadeFinished()
            return
        }
        guard fadeTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeStep() {
        let diff = targetFactor - appliedFactor
        if abs(diff) < 0.003 {
            appliedFactor = targetFactor
            gamma?.apply(appliedFactor)
            fadeTimer?.invalidate()
            fadeTimer = nil
            fadeFinished()
        } else {
            appliedFactor += diff * 0.15
            gamma?.apply(appliedFactor)
        }
    }

    private func fadeFinished() {
        if !wantsBoost, appliedFactor <= 1.0005 {
            teardown()
        }
    }

    /// Restores the gamma table and leaves EDR mode right away.
    private func teardown() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        gamma?.restore()
        gamma = nil
        appliedFactor = 1
        targetFactor = 1
        trigger?.hide()
    }

    func shutdown() {
        wantsBoost = false
        teardown()
    }

    // MARK: - System events

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        let reevaluate: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reevaluate)
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: reevaluate)
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: reevaluate)

        let sleep: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(true) }
        }
        let wake: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(false) }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: sleep)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: wake)
        }
    }

    private func setAsleep(_ asleep: Bool) {
        wakeWork?.cancel()
        if asleep {
            isAsleep = true
            evaluate()
        } else {
            // Give the display a moment to settle before boosting again.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.isAsleep = false
                    self?.evaluate()
                }
            }
            wakeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    // MARK: - Helpers

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    private static func readBattery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }

            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / capacity, onBattery)
        }
        return nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
