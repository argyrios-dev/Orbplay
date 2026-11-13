import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var audio: SpatialAudio

    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            header
            Divider()
            spatialSection
            Divider()
            equalizerSection
            footer
        }
        .padding(18)
        .frame(width: 440)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Orbplay").font(.title2.bold())
                Text(audio.isProcessing ? "System audio active" : "3D spatial audio & EQ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                audio.toggleProcessing()
            } label: {
                Label(audio.isProcessing ? "Stop" : "Start", systemImage: audio.isProcessing ? "stop.fill" : "power")
            }
            .buttonStyle(.borderedProminent)
            .tint(audio.isProcessing ? .orange : .cyan)
        }
    }

    private var spatialSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("System Audio", systemImage: "hifispeaker")
                    .font(.headline)
                Spacer()
                Button { audio.refreshOutputDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh output devices")
            }
            Text("Spotify, Safari, calls, and more")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: audio.outputDevices.first(where: { $0.uid == audio.selectedOutputUID })?.isBluetooth == true ? "headphones" : "hifispeaker")
                    .foregroundStyle(.cyan)
                Picker("Output", selection: Binding(
                    get: { audio.selectedOutputUID },
                    set: { audio.selectOutput($0) }
                )) {
                    ForEach(audio.outputDevices) { device in
                        Text(device.name + (device.isBluetooth ? " · Bluetooth" : ""))
                            .tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(audio.isProcessing)
            }
            if audio.isProcessing {
                Text("Stop processing to change the output device.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Sound Position")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    directionButton("Front", icon: "arrow.up", selected: audio.sourceZ < -0.7 && abs(audio.sourceX) < 0.2) {
                        audio.setSource(x: 0, y: 0.86)
                    }
                    directionButton("Back", icon: "arrow.down", selected: audio.sourceZ > 0.7 && abs(audio.sourceX) < 0.2) {
                        audio.setSource(x: 0, y: -0.86)
                    }
                    directionButton("Left", icon: "arrow.left", selected: audio.sourceX < -0.7) {
                        audio.setSource(x: -0.86, y: 0)
                    }
                    directionButton("Right", icon: "arrow.right", selected: audio.sourceX > 0.7) {
                        audio.setSource(x: 0.86, y: 0)
                    }
                }
            }

            HeadTrackingSection(tracker: audio.headTracker)
        }
    }

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Equalizer", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Picker("Preset", selection: Binding(
                    get: { audio.selectedEQPreset },
                    set: { value in
                        if let preset = EQPreset(rawValue: value), preset != .custom {
                            audio.applyEQPreset(preset)
                        }
                    }
                )) {
                    ForEach(EQPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 142)
                Toggle("EQ", isOn: $audio.equalizerEnabled).labelsHidden().toggleStyle(.switch).scaleEffect(0.8)
            }
            HStack(alignment: .center, spacing: 2) {
                ForEach(labels.indices, id: \.self) { index in
                    VStack(spacing: 4) {
                        Text(audio.gains[index], format: .number.sign(strategy: .always()).precision(.fractionLength(0)))
                            .font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary)
                        VerticalEQSlider(value: gainBinding(index), enabled: audio.equalizerEnabled)
                            .frame(width: 34, height: 88)
                        Text(labels[index]).font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text("−12 dB"); Spacer(); Text("0"); Spacer(); Text("+12 dB")
            }
            .font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("SIGNAL")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.18))
                        Capsule().fill(audio.inputLevel > 0.001 ? .green : .secondary)
                            .frame(width: geometry.size.width * min(1, CGFloat(audio.inputLevel)), height: 5)
                    }
                }
                .frame(height: 5)
                Text(audio.inputLevel > 0.00001 ? "\(Int(20 * log10(audio.inputLevel))) dB" : "— dB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 43, alignment: .trailing)
            }
            HStack(spacing: 7) {
                Circle().fill(audio.isProcessing ? .green : .secondary).frame(width: 7, height: 7)
                Text(audio.status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = audio.error {
                Text(error).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Open audio capture permission settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Capture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            Text("Audio from all apps is processed through the selected output. Headphones are recommended. Zero latency and bit-perfect playback are not guaranteed.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit Orbplay") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { audio.gains[index] },
            set: { audio.setEQGain($0, at: index) }
        )
    }

    @ViewBuilder
    private func directionButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        if selected {
            button.buttonStyle(.borderedProminent).tint(.cyan)
        } else {
            button.buttonStyle(.bordered).tint(.cyan)
        }
    }
}

private struct VerticalEQSlider: View {
    @Binding var value: Double
    let enabled: Bool

    private let minimum = -12.0
    private let maximum = 12.0
    private let step = 0.5

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height - 12
            let centerY = height / 2
            let normalized = (value - minimum) / (maximum - minimum)
            let thumbY = 6 + height * (1 - normalized)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.secondary.opacity(0.22))
                    .frame(width: 4, height: height)
                    .position(x: geometry.size.width / 2, y: 6 + centerY)
                Rectangle()
                    .fill(.secondary.opacity(0.55))
                    .frame(width: 12, height: 1)
                    .position(x: geometry.size.width / 2, y: 6 + centerY)
                Capsule()
                    .fill(value >= 0 ? Color.cyan : Color.orange)
                    .frame(width: 4, height: abs(thumbY - (6 + centerY)))
                    .position(x: geometry.size.width / 2, y: (thumbY + 6 + centerY) / 2)
                Circle()
                    .fill(enabled ? Color.white : Color.gray)
                    .overlay(Circle().stroke(enabled ? Color.cyan : Color.secondary, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .position(x: geometry.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled, height > 0 else { return }
                let clampedY = min(height, max(0, gesture.location.y - 6))
                let rawValue = maximum - (clampedY / height) * (maximum - minimum)
                value = min(maximum, max(minimum, (rawValue / step).rounded() * step))
            })
            .opacity(enabled ? 1 : 0.45)
            .accessibilityElement()
            .accessibilityLabel("Equalizer gain")
            .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(1)))) dB")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                switch direction {
                case .increment: value = min(maximum, value + step)
                case .decrement: value = max(minimum, value - step)
                @unknown default: break
                }
            }
        }
    }
}

private struct HeadTrackingSection: View {
    @ObservedObject var tracker: CameraHeadTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Head Tracking", systemImage: "face.smiling")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    tracker.isTracking ? tracker.stop() : tracker.start()
                } label: {
                    Label(tracker.isTracking ? "Stop Camera" : "Start Tracking",
                          systemImage: tracker.isTracking ? "video.slash" : "video")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 7) {
                Circle().fill(tracker.hasFace ? .green : (tracker.isTracking ? .orange : .secondary))
                    .frame(width: 7, height: 7)
                Text(tracker.status)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Recenter Head") { tracker.recenter() }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .disabled(!tracker.isTracking || !tracker.hasFace)
            }
            HStack(spacing: 8) {
                Text("Sensitivity")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("Sensitivity", selection: $tracker.sensitivity) {
                    ForEach(HeadTrackingSensitivity.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 205)
                Spacer(minLength: 0)
            }
            Text("The camera tracks your face turning left or right to keep the sound source in place. Analysis happens on this Mac; video is not saved.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if tracker.status.contains("Camera permission denied") {
                Button("Open Camera Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

