import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: BoostController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            boostSlider
            automatic
            statusRow
            Divider()
            safety
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MacBright").font(.headline)
                Text("Extra brightness from the XDR headroom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Boost", isOn: $controller.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var boostSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(controller.isAutomatic ? "Max boost" : "Boost")
                Spacer()
                Text(String(format: "×%.2f", controller.factor))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $controller.factor, in: 1...BoostController.maxFactor, step: 0.05) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "sun.min")
            } maximumValueLabel: {
                Image(systemName: "sun.max.fill")
            }
            .labelsHidden()
        }
    }

    private var automatic: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Follow ambient light", isOn: $controller.isAutomatic)
                .disabled(!controller.hasLightSensor)
            if !controller.hasLightSensor {
                Text("No ambient light sensor found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.isAutomatic {
                Picker("Start boosting at", selection: $controller.autoStartLux) {
                    ForEach(BoostController.startLuxChoices, id: \.self) { lux in
                        Text("\(Int(lux).formatted()) lux").tag(lux)
                    }
                }
                .fixedSize()
                Text("Reaches max boost at \(Int(controller.autoStartLux * 10).formatted()) lux.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safety")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Pause below \(BoostController.batteryThreshold)% battery", isOn: $controller.pauseOnLowBattery)
            Toggle("Pause in Low Power Mode", isOn: $controller.pauseInLowPowerMode)
            Picker("Turn off after", selection: $controller.autoOffMinutes) {
                ForEach(BoostController.autoOffChoices, id: \.self) { minutes in
                    Text(autoOffLabel(minutes)).tag(minutes)
                }
            }
            .fixedSize()
            Text("Always pauses when the Mac is running hot, and never goes beyond the headroom macOS allows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $controller.launchAtLogin)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func autoOffLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case ..<60: "\(minutes) min"
        default: "\(minutes / 60) h"
        }
    }

    private var statusText: String {
        switch controller.status {
        case .off: "Off"
        case .noBuiltInDisplay: "Built-in display not available"
        case .waitingForHDR: "Waiting for HDR mode…"
        case .active:
            String(format: controller.isAutomatic ? "Auto boost ×%.2f" : "Boosting ×%.2f", controller.targetFactor)
        case .limited: String(format: "Limited to ×%.2f by macOS", controller.targetFactor)
        case .paused(let reason): "Paused: \(reason.text)"
        case .standby: "Standing by: not bright enough"
        case .noLightSensor: "Can't read the light sensor"
        }
    }

    private var statusDetail: String? {
        var parts: [String] = []
        if let lux = controller.lux {
            parts.append("\(Int(lux).formatted()) lux")
        }
        switch controller.status {
        case .active, .limited, .waitingForHDR:
            parts.append(String(format: "HDR headroom ×%.2f", controller.headroom))
        default:
            break
        }
        if let minutes = controller.minutesUntilAutoOff {
            parts.append("off in \(minutes) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch controller.status {
        case .active: .green
        case .limited, .waitingForHDR, .paused, .noLightSensor: .orange
        case .standby: .blue
        case .off, .noBuiltInDisplay: .secondary
        }
    }
}
