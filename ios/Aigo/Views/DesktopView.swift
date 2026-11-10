import SwiftUI

/// "View screen" (#63): the active PC's desktop, view only until the user
/// takes control. Shown full screen; works in portrait and landscape.
struct DesktopView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = DesktopModel()
    @State private var chrome = true
    @State private var confirmControl = false
    @State private var wasInBackground = false
    /// The space between the top bar and the controls/keyboard (global coordinates).
    @State private var freeRect: CGRect = .zero
    @State private var fitRequest = 0

    var body: some View {
        ZStack {
            Color(aigoHex: 0x08090A).ignoresSafeArea()
            switch model.phase {
            case .unavailable(let title, let message):
                unavailable(title: title, message: message)
            default:
                DesktopSurface(model: model, freeRect: freeRect, fitRequest: fitRequest) {
                    withAnimation(.easeOut(duration: 0.15)) { chrome.toggle() }
                }
                .ignoresSafeArea()
                if !model.hasFrame {
                    waiting
                }
                bars
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(.hidden)
        .onAppear { model.start(client: store.client) }
        .onDisappear { model.stop() }
        .onChange(of: store.clientGeneration) { _, _ in
            model.start(client: store.client)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
                model.suspend()
            case .active:
                if wasInBackground {
                    wasInBackground = false
                    model.resume()
                }
            default:
                break
            }
        }
        .onChange(of: model.control) { _, on in
            if on { chrome = true }
        }
        .sheet(isPresented: $confirmControl) {
            TakeControlSheet(hostLabel: model.hostLabel) {
                confirmControl = false
                Haptics.warning()
                model.control = true
            } onCancel: {
                confirmControl = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - States

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.secondary)
            Text(waitingText)
                .font(.aigo(.callout))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .connecting(let problem) = model.phase, problem != nil {
                Button {
                    Haptics.tap()
                    model.retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .allowsHitTesting(model.phase != .live)
    }

    private var waitingText: String {
        switch model.phase {
        case .loading: return "Asking \(model.hostLabel) for its screen…"
        case .connecting(let problem?): return problem
        case .connecting(.none): return "Connecting to \(model.hostLabel)…"
        case .live: return model.hostError ?? "Waiting for the first picture…"
        case .unavailable: return ""
        }
    }

    private func unavailable(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                closeButton
                Spacer()
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(Theme.coral)
                    Text("REMOTE DESKTOP")
                        .font(Theme.monoLabel)
                        .tracking(1.0)
                        .foregroundStyle(Theme.coral)
                }
                Text(title)
                    .font(.aigo(.title3, .semibold))
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(.aigo(.callout))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        model.retry()
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Close") { dismiss() }
                        .buttonStyle(SoftButtonStyle(tint: Theme.lime))
                }
                .padding(.top, 6)
            }
            .padding(16)
            .aigoCard()
            Spacer()
        }
        .padding(Theme.gutter)
        .frame(maxWidth: 520)
    }

    // MARK: - Bars

    private var bars: some View {
        VStack(spacing: 0) {
            if chrome {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let err = model.hostError, model.hasFrame {
                InlineBanner(text: "\(model.hostLabel): \(err)")
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 6)
            }
            // The picture is fitted into this space (above the keyboard and controls, #73).
            GeometryReader { geo in
                Color.clear
                    .onAppear { freeRect = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, r in freeRect = r }
            }
            .allowsHitTesting(false)
            if chrome && model.control {
                controlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if chrome && model.phase == .live && model.hasFrame && !model.controlAllowed {
                Label(model.controlReason ?? "View only: this PC doesn't allow control from this device.",
                      systemImage: "eye")
                    .font(.aigo(.caption))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            } else if chrome && model.phase == .live && model.hasFrame {
                Text("View only · pinch to zoom · drag to move · tap to hide controls")
                    .font(.aigo(.caption))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var closeButton: some View {
        Button {
            model.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close screen"))
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text(model.hostLabel)
                    .font(.aigo(.footnote, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.phase == .live ? Theme.lime : Theme.secondary)
                        .frame(width: 6, height: 6)
                    Text(statsText)
                        .font(.aigo(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            settingsMenu
            if !model.controlAllowed {
                Label("View only", systemImage: "eye")
                    .font(.aigo(.caption, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .accessibilityLabel(Text("View only. \(model.controlReason ?? "")"))
            } else {
                Button {
                    Haptics.tap()
                    if model.control {
                        model.control = false
                    } else {
                        confirmControl = true
                    }
                } label: {
                    Text(model.control ? "Release" : "Take control")
                }
                .buttonStyle(SoftButtonStyle(tint: model.control ? Theme.coral : Theme.lime,
                                             text: model.control ? Theme.coralButtonText : nil,
                                             fullWidth: false, minHeight: 36))
                .disabled(model.phase != .live && !model.control)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.72))
    }

    private var statsText: String {
        switch model.phase {
        case .live:
            var parts: [String] = []
            parts.append(model.fps == 0 ? "still" : "\(model.fps) fps")
            if let rtt = model.rttMs { parts.append("\(rtt) ms") }
            parts.append("\(model.kbps) KB/s")
            if model.sourceSize != .zero {
                parts.append("\(Int(model.sourceSize.width))×\(Int(model.sourceSize.height))")
            }
            return parts.joined(separator: " · ")
        case .connecting: return "reconnecting…"
        case .loading: return "connecting…"
        case .unavailable: return "unavailable"
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                fitRequest += 1
            } label: {
                Label("Fit picture", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            Section("Monitor") {
                if model.monitors.isEmpty {
                    Button {} label: {
                        Label(primaryLabel, systemImage: "checkmark")
                    }
                    .disabled(true)
                    Text("This PC streams its primary monitor only.")
                } else {
                    Picker("Monitor", selection: $model.monitor) {
                        ForEach(model.monitors) { m in
                            Text(m.label).tag(m.index)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            Picker("Resolution", selection: $model.maxWidth) {
                ForEach([960, 1280, 1600, 1920, 2560], id: \.self) { w in
                    Text("\(w) px wide").tag(w)
                }
            }
            .pickerStyle(.menu)
            Picker("Quality", selection: $model.quality) {
                ForEach([30, 45, 60, 75, 90], id: \.self) { q in
                    Text("JPEG \(q)").tag(q)
                }
            }
            .pickerStyle(.menu)
            Picker("Frame rate", selection: $model.targetFps) {
                ForEach(model.fpsChoices, id: \.self) { f in
                    Text("\(f) fps").tag(f)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "display")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Monitor and picture settings"))
    }

    private var primaryLabel: String {
        if model.sourceSize == .zero { return "Primary monitor" }
        return "Primary monitor · \(Int(model.sourceSize.width))×\(Int(model.sourceSize.height))"
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(spacing: 6) {
            if model.keyboard {
                specialKeys
            }
            HStack(spacing: 6) {
                modeButton(title: "Touch", symbol: "hand.point.up.left", on: !model.trackpad && !model.panLock) {
                    model.panLock = false
                    model.trackpad = false
                }
                modeButton(title: "Trackpad", symbol: "rectangle.and.hand.point.up.left", on: model.trackpad && !model.panLock) {
                    model.panLock = false
                    model.trackpad = true
                }
                modeButton(title: "Pan", symbol: "arrow.up.and.down.and.arrow.left.and.right", on: model.panLock) {
                    model.panLock.toggle()
                }
                modeButton(title: "Keys", symbol: "keyboard", on: model.keyboard) {
                    model.keyboard.toggle()
                }
            }
            Text(hint)
                .font(.aigo(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.78))
    }

    private var hint: String {
        if model.panLock { return "Pan: drag and pinch move the picture anywhere; nothing is sent to the PC. Double tap fits it." }
        if model.trackpad { return "Drag moves the pointer · tap clicks · hold then drag drags · two-finger tap right-clicks · two fingers scroll" }
        return "Tap clicks · drag drags · two-finger tap right-clicks · two fingers scroll · pinch zooms"
    }

    private func modeButton(title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.aigo(size: 10.5, on ? .bold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? Theme.lime : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(on ? Theme.lime.opacity(0.15) : Theme.softWhite,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var specialKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                keyButton("Esc") { model.press(code: "Escape", key: "Escape") }
                keyButton("Tab") { model.press(code: "Tab", key: "Tab") }
                ForEach(DesktopModifier.allCases) { m in
                    keyButton(m.label, on: model.latched.contains(m)) { model.toggle(m) }
                }
                keyButton("←") { model.press(code: "ArrowLeft", key: "ArrowLeft") }
                keyButton("↑") { model.press(code: "ArrowUp", key: "ArrowUp") }
                keyButton("↓") { model.press(code: "ArrowDown", key: "ArrowDown") }
                keyButton("→") { model.press(code: "ArrowRight", key: "ArrowRight") }
                keyButton("Enter") { model.press(code: "Enter", key: "Enter") }
                keyButton("⌫") { model.press(code: "Backspace", key: "Backspace") }
                keyButton("Del") { model.press(code: "Delete", key: "Delete") }
            }
        }
    }

    private func keyButton(_ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.aigo(.footnote, .semibold))
                .foregroundStyle(on ? Theme.bg : Theme.text)
                .padding(.horizontal, 12)
                .frame(minWidth: 40, minHeight: 38)
                .background(on ? Theme.lime : Theme.softWhite,
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Confirms before phone taps start acting on the real PC.
private struct TakeControlSheet: View {
    let hostLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .foregroundStyle(Theme.coral)
                Text("TAKE CONTROL")
                    .font(Theme.monoLabel)
                    .tracking(1.0)
                    .foregroundStyle(Theme.coral)
            }
            Text("Control \(hostLabel) from this iPhone?")
                .font(.aigo(.title3, .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Taps, drags, scrolling and keys act on the real PC as if you were sitting at it, including closing windows and deleting files. Anyone at the PC sees the pointer move. Tap Release to go back to view only.")
                .font(.aigo(.callout))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Take control", action: onConfirm)
                    .buttonStyle(SoftButtonStyle(tint: Theme.coral, text: Theme.coralButtonText))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg.ignoresSafeArea())
    }
}
