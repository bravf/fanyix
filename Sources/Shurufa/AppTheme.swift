import AppKit
import SwiftUI

enum AppTheme {
    static let controlHeight: CGFloat = 33
    static let green = Color(red: 0.10, green: 0.76, blue: 0.55)
    static let ink = Color(red: 0.13, green: 0.14, blue: 0.14)
    static let secondary = Color(red: 0.53, green: 0.55, blue: 0.55)
    static let canvas = Color(red: 0.965, green: 0.967, blue: 0.968)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.91)
}

struct AppMark: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: FanyiXIcon.image(size: size)).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("FanyiX")
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 0.8))
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(height: AppTheme.controlHeight)
            .foregroundStyle(isEnabled ? (prominent ? .white : AppTheme.ink) : AppTheme.secondary)
            .background(isEnabled ? (prominent ? AppTheme.green : .white) : AppTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(prominent && isEnabled ? AppTheme.green : AppTheme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct SettingsTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        TextField(title, text: $text, prompt: Text(placeholder).foregroundColor(AppTheme.secondary.opacity(0.8)))
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(AppTheme.ink)
            .focused($focused).onSubmit(onSubmit).padding(.horizontal, 12).frame(height: AppTheme.controlHeight)
            .background(focused ? Color.white : AppTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? AppTheme.green : hovered ? AppTheme.secondary.opacity(0.45) : AppTheme.line, lineWidth: focused ? 1.5 : 1))
            .shadow(color: focused ? AppTheme.green.opacity(0.10) : .clear, radius: 3)
            .onHover { hovered = $0 }.opacity(isEnabled ? 1 : 0.55).accessibilityLabel(title)
    }
}

struct ModelMenuOption: Identifiable {
    let id: String
    let title: String
}

struct SettingsModelMenu: View {
    let title: String
    let selected: String
    let options: [ModelMenuOption]
    var symbol = "cpu"
    var accessibilityTitle = "翻译模型"
    let onSelect: (String) -> Void
    @State private var hovered = false
    @State private var expanded = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(AppTheme.secondary)
                Text(title).font(.system(size: 13, weight: .regular)).foregroundStyle(AppTheme.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppTheme.secondary)
            }.padding(.horizontal, 12).frame(height: AppTheme.controlHeight).frame(maxWidth: .infinity)
                .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(expanded ? AppTheme.green : hovered ? AppTheme.secondary.opacity(0.45) : AppTheme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .onHover { hovered = $0 }.opacity(isEnabled ? 1 : 0.55).accessibilityLabel(accessibilityTitle).accessibilityValue(title)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(options) { option in
                            Button { expanded = false; onSelect(option.id) } label: {
                                HStack(spacing: 12) {
                                    Text(option.title).font(.system(size: 13)).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    if selected == option.id { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.green) }
                                }.padding(.horizontal, 13).padding(.vertical, 8).frame(minHeight: AppTheme.controlHeight).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(AppTheme.ink).background(selected == option.id ? AppTheme.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(selected == option.id ? .isSelected : [])
                        }
                    }.padding(8)
                }.frame(width: 420, height: min(CGFloat(options.count) * (AppTheme.controlHeight + 3) + 16, 330)).background(.white).preferredColorScheme(.light)
                    .onExitCommand { expanded = false }
            }
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(AppTheme.line.opacity(0.8)).frame(height: 0.7) }
}

/// 设置页示意与真实翻译浮层共用同一种横向工具条。
struct TranslationToolbar: View {
    let title: String
    var spinning = false
    var symbol = "character.bubble"
    var body: some View {
        HStack(spacing: 12) {
            AppMark(size: 25)
            Rectangle().fill(AppTheme.line).frame(width: 1, height: 21)
            if spinning { ProgressView().controlSize(.small).tint(AppTheme.green).scaleEffect(0.85).frame(width: 17) }
            else { Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(AppTheme.green).frame(width: 17) }
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink).lineLimit(1)
        }
    }
}

/// 设置与翻译历史共用白色、细边框和 12 点圆角外壳。
struct FloatingPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(AppTheme.ink).background(.white)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12)).preferredColorScheme(.light)
    }
}

final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
