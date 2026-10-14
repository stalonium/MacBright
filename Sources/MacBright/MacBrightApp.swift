import SwiftUI

@main
struct MacBrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = BoostController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BoostController.shared.shutdown()
    }
}

/// `MacBright --selftest`: exercises the real display and light sensor for
/// about 12 seconds, checking the gamma table at each step, then exits with
/// status 0 if everything passed.
///
/// 1. Manual ×1.3 boost is applied.
/// 2. Automatic mode with a start level below the current lux boosts by what
///    the curve predicts.
/// 3. Automatic mode with a start level above the current lux stands by and
///    restores the display.
/// 4. Turning it off restores the display.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() {
        let controller = BoostController.shared
        guard let screen = BoostController.builtInScreen(), let id = screen.displayID,
              let basePeak = GammaBooster.currentPeak(of: id) else {
            print("FAIL: no built-in display / gamma table")
            exit(1)
        }
        print("potential headroom ×\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), baseline gamma peak \(basePeak)")

        let saved = (controller.factor, controller.isAutomatic, controller.autoStartLux)
        func peak() -> Double { Double(GammaBooster.currentPeak(of: id) ?? -1) / Double(basePeak) }

        let log = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                print(String(format: "  status=%@ target=×%.3f gamma=×%.3f headroom=×%.2f lux=%@",
                             String(describing: controller.status), controller.targetFactor, peak(),
                             controller.headroom, controller.lux.map { "\(Int($0))" } ?? "-"))
            }
        }

        print("1. manual ×1.3")
        controller.isAutomatic = false
        controller.factor = 1.3
        controller.isEnabled = true

        after(4) {
            check("manual boost applied", abs(peak() - 1.3) < 0.01)

            guard let lux = AmbientLightSensor()?.lux else {
                print("ambient light sensor not found, skipping automatic mode")
                return finish()
            }
            print("2. automatic, start at \(Int(lux / 4)) lux (¼ of current \(Int(lux)) lux)")
            controller.autoStartLux = lux / 4
            controller.isAutomatic = true

            after(3) {
                let expected = controller.lux.map {
                    BoostController.autoFactor(lux: $0, startLux: controller.autoStartLux, maxFactor: 1.3)
                } ?? 0
                check("auto boost active", controller.status == .active)
                check(String(format: "auto boost ≈ curve (×%.3f)", expected), abs(peak() - expected) < 0.02)

                print("3. automatic, start at \(Int(lux * 4)) lux (4× current)")
                controller.autoStartLux = lux * 4

                after(2.5) {
                    check("standing by", controller.status == .standby)
                    check("standby restored display", abs(peak() - 1) < 0.003)

                    print("4. manual again, then off")
                    controller.isAutomatic = false
                    after(2) {
                        controller.isEnabled = false
                        after(1.5) {
                            check("off restored display", abs(peak() - 1) < 0.003)
                            finish()
                        }
                    }
                }
            }
        }

        func finish() {
            log.invalidate()
            controller.isEnabled = false
            (controller.factor, controller.isAutomatic, controller.autoStartLux) = saved
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("  \(ok ? "OK  " : "FAIL") \(name)")
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated(body)
        }
    }
}
