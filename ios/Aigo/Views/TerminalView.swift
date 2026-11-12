import SwiftUI
import UIKit

/// Live terminal pane: the session's terminal (SwiftTerm), plus a status
/// strip (live / reconnecting, PC size vs Fit to phone, text size, copy and
/// paste). The same view shows exited sessions read-only.
struct TerminalPane: View {
    @ObservedObject var model: TerminalModel
    @Binding var fontSize: Double
    /// Running session: tap for the keyboard, keys go to the terminal.
    var interactive = false

    var body: some View {
        VStack(spacing: 0) {
            strip
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            TerminalSurface(model: model, fontSize: $fontSize, interactive: interactive)
                .background(Theme.codeBg)
        }
        .background(Theme.codeBg)
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.live ? Theme.lime : (model.exited ? Theme.idle : Theme.coral))
                .frame(width: 7, height: 7)
                .shadow(color: model.live ? Theme.lime.opacity(0.6) : .clear, radius: 3)
            Text(stateText)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !model.exited {
                sizeToggle
            }
            Menu {
                Section("Text size") {
                    Button {
                        fontSize = min(fontSize + 1, 24)
                    } label: {
                        Label("Larger text", systemImage: "textformat.size.larger")
                    }
                    Button {
                        fontSize = max(fontSize - 1, 6)
                    } label: {
                        Label("Smaller text", systemImage: "textformat.size.smaller")
                    }
                    Button {
                        fontSize = 12
                        model.surface.resetZoom()
                    } label: {
                        Label("Default size", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        model.surface.resetZoom()
                    } label: {
                        Label("Fit width (undo pinch zoom)", systemImage: "arrow.left.and.right")
                    }
                }
                Section {
                    Button {
                        if let text = model.selectedText(), !text.isEmpty {
                            UIPasteboard.general.string = text
                            Haptics.success()
                        } else {
                            Haptics.error()
                        }
                    } label: {
                        Label("Copy selection", systemImage: "selection.pin.in.out")
                    }
                    if interactive && !model.exited {
                        Button {
                            model.paste()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard.fill")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = model.screenText()
                        Haptics.success()
                    } label: {
                        Label("Copy screen", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = model.allText()
                        Haptics.success()
                    } label: {
                        Label("Copy screen and history", systemImage: "doc.on.clipboard")
                    }
                    if !model.exited {
                        Button {
                            model.refreshSnapshot()
                        } label: {
                            Label("Redraw", systemImage: "arrow.clockwise")
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.aigo(.footnote, .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Text size, copy and paste"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(Theme.bg)
    }

    /// "PC size" (watch at the PC's size, scaled) vs "Fit to phone" (the PC's
    /// terminal takes this phone's size).
    private var sizeToggle: some View {
        HStack(spacing: 0) {
            segment("PC size", on: model.choice == .pc, hint: "Keeps the PC's terminal size; the text is scaled to fit") {
                model.choose(.pc)
            }
            segment("Fit to phone", on: model.choice == .phone, hint: "Resizes the terminal on the PC to fit this phone") {
                model.choose(.phone)
            }
        }
        .padding(2)
        .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func segment(_ title: String, on: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(.aigo(.caption, on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.bg : Theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .background(on ? Theme.text : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(Text(hint))
    }

    private var stateText: String {
        if model.exited { return "exited · read-only · pinch to zoom" }
        if model.live {
            if let s = model.ptySize {
                return model.owner ? "live · \(s.cols)×\(s.rows)" : "live · PC \(s.cols)×\(s.rows)"
            }
            return "live"
        }
        if let p = model.problem { return "reconnecting · \(p)" }
        return "connecting…"
    }
}
