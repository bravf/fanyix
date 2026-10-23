import AppKit
import SwiftUI
import ApplicationServices
import TranslationCore

enum SettingsPage: String, CaseIterable {
    case translation = "翻译", agent = "Agent 与模型", rules = "翻译规则", shortcuts = "快捷键", privacy = "权限与隐私", about = "关于FanyiX"
    var symbol: String {
        switch self {
        case .translation: return "character.bubble"
        case .agent: return "cpu"
        case .rules: return "doc.text"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .translation: return "选中文字，让表达自然一点。"
        case .agent: return "选择用于翻译的 Agent 和模型。"
        case .rules: return "一份目录规则，让每次翻译保持独立。"
        case .shortcuts: return "不切换应用，一步翻译当前选区。"
        case .privacy: return "了解FanyiX需要什么权限，以及文字如何处理。"
        case .about: return "随手选中，快捷翻译。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppDelegate
    @State private var page: SettingsPage
    private var permission: Bool { model.accessibilityTrusted }
    @State private var customModel = ""
    @State private var preview = 0
    private let loadsModels: Bool
    init(model: AppDelegate, initialPage: SettingsPage = .translation, loadsModels: Bool = true) {
        self.model = model; _page = State(initialValue: initialPage); self.loadsModels = loadsModels
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TranslationToolbar(title: "设置", symbol: "gearshape")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .overlay(OverlayDragHandle {}).help("拖动调整位置")
                Button { model.closeSettings() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).frame(width: 23, height: 27).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(AppTheme.secondary).help("关闭设置").accessibilityLabel("关闭设置")
            }.padding(.horizontal, 12).frame(height: 44)
            SettingsDivider()
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(AppTheme.line.opacity(0.8)).frame(width: 0.7)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(page.rawValue).font(.system(size: 17, weight: .semibold))
                            Text(page.subtitle).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                        }.padding(.bottom, 2)
                        content
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
            SettingsDivider()
            HStack(spacing: 7) {
                Circle().fill(model.busy ? AppTheme.green : AppTheme.secondary.opacity(0.5)).frame(width: 5, height: 5)
                Text(model.status).lineLimit(1).help(model.status)
                Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 16).frame(height: 36)
        }.tint(AppTheme.green).modifier(FloatingPanelSurface())
            .frame(minWidth: 680, minHeight: 560)
            .onAppear { model.refreshAccessibilityPermission(); if loadsModels { model.refreshModels() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsPage.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 19)
                        Text(item.rawValue).font(.system(size: 12)); Spacer(minLength: 0)
                        if item == .privacy && !permission { Circle().fill(.orange).frame(width: 5, height: 5) }
                    }.foregroundStyle(page == item ? AppTheme.green : AppTheme.ink)
                        .padding(.horizontal, 10).frame(height: 38)
                        .background(page == item ? AppTheme.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(10).frame(width: 154).frame(maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .translation: translationPage
        case .agent: agentPage
        case .rules: rulesPage
        case .shortcuts: shortcutsPage
        case .privacy: privacyPage
        case .about: aboutPage
        }
    }

    private func row<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(.vertical, 19)
            Spacer(minLength: 12)
            trailing()
        }.frame(minHeight: 68)
    }

    private var translationPage: some View {
        Group {
            SettingsCard {
                row("翻译选中文字", subtitle: "有选区时翻译，未选中或内容为空时打开历史。") {
                    Text(HotKey.titles[safe: model.configuration.shortcut, default: 0]).font(.system(size: 19, weight: .medium, design: .rounded))
                        .tracking(2).padding(.horizontal, 16).padding(.vertical, 10).background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
                SettingsDivider()
                row("翻译方向", subtitle: "中文译英文，英文译中文；混合文本按主要语言判断。") { Text("中英文自动互译").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                SettingsDivider()
                row("替换方式", subtitle: "只替换选中文字，本次翻译沿用启动时的设置。") {
                    SettingsModelMenu(title: model.configuration.replacementStyle.title,
                                      selected: model.configuration.replacementStyle.rawValue,
                                      options: ReplacementStyle.allCases.map { ModelMenuOption(id: $0.rawValue, title: $0.title) },
                                      symbol: "text.badge.plus", accessibilityTitle: "替换方式") { value in
                        guard let style = ReplacementStyle(rawValue: value) else { return }
                        model.configuration.replacementStyle = style
                        model.saveSettings()
                    }.frame(width: 190)
                }
                SettingsDivider()
                row("英文注释", subtitle: "开启后额外用中文解释英文单词、固定搭配与语法：原文是英文时解释原文，原文是中文时解释英文译文。注释只显示在历史详情中，默认关闭以减少耗时。") {
                    Toggle("", isOn: Binding(
                        get: { model.configuration.notes },
                        set: { enabled in model.configuration.notes = enabled; model.saveSettings() }
                    )).labelsHidden().toggleStyle(.switch).tint(AppTheme.green).accessibilityLabel("英文注释")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("替换预览 · 选中「今天真冷」").font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                    Text(model.configuration.replacementStyle.replacement(source: "今天真冷", translation: "It's really cold today."))
                        .font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 7)).padding(.bottom, 16)
                SettingsDivider()
                row("当前翻译 Agent", subtitle: model.configuration.selectedModel.isEmpty ? "沿用本机默认模型" : model.configuration.selectedModel) {
                    Button { page = .agent } label: { HStack(spacing: 8) { Text(model.configuration.backend.title); Image(systemName: "chevron.right").font(.system(size: 9)) } }.buttonStyle(QuietButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("翻译浮层").font(.system(size: 14)); Spacer(); Text("样式预览").font(.system(size: 11)).foregroundStyle(AppTheme.secondary) }
                SettingsCard {
                    VStack(alignment: .leading, spacing: 19) {
                        Picker("浮层模式", selection: $preview) { Text("简单模式").tag(0); Text("展开模式").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                TranslationToolbar(title: preview == 0 ? "正在翻译…" : "翻译记录", spinning: preview == 0, symbol: "clock")
                                Spacer(minLength: 0)
                                Image(systemName: preview == 0 ? "stop" : "chevron.down").font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                                Image(systemName: preview == 0 ? "chevron.up" : "xmark").font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                            }.padding(.horizontal, 12).frame(height: 44)
                            if preview == 1 {
                                SettingsDivider()
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("翻译历史与详情").font(.system(size: 12, weight: .medium))
                                        Text("原文 · 译文 · 复制 · 删除").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(AppTheme.green)
                                }.padding(14)
                            }
                        }.frame(width: 292).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.line)).shadow(color: .black.opacity(0.04), radius: 7, y: 3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(preview == 0 ? "右下角显示精简状态，可拖动并记住位置。替换成功后直接消失；未替换时显示「译文已保留」，展开即可复制。" : "在同一浮层查看历史与完整原文、译文。翻译完成后保持展开；翻译中操作历史会保留译文，不再自动替换。")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("仅在本机保留最近 100 条，可逐条删除或清空。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            Spacer()
                            Button("查看翻译历史") { model.showResult() }.buttonStyle(QuietButtonStyle())
                        }
                    }.padding(.vertical, 21)
                }
            }
            Text("翻译不会自动发送消息。快捷键：有文字时翻译，空选区时打开历史。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentPage: some View {
        Group {
            SettingsCard {
                ForEach(Array(Backend.allCases.enumerated()), id: \.element) { index, backend in
                    if index > 0 { SettingsDivider() }
                    Button { guard model.configuration.backend != backend else { return }; model.configuration.backend = backend; customModel = ""; model.agentSettingsChanged() } label: {
                        HStack(spacing: 13) {
                            radio(model.configuration.backend == backend)
                            Text(backend.title).font(.system(size: 14))
                            Spacer()
                            if model.configuration.backend == backend { Text("正在使用").font(.system(size: 11)).foregroundStyle(AppTheme.green) }
                        }.padding(.vertical, 17).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.busy)
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("翻译模型").font(.system(size: 14)); Spacer(); if model.loadingModels { ProgressView().controlSize(.small) }; Button("刷新列表") { model.refreshModels() }.buttonStyle(QuietButtonStyle()).disabled(model.loadingModels) }
                    SettingsModelMenu(title: selectedModelTitle, selected: model.configuration.selectedModel, options: modelOptions, onSelect: model.selectModel).disabled(model.busy)
                    Text(model.modelStatus.isEmpty ? "模型列表由所选 Agent 提供，各 Agent 的选择分别保存。" : model.modelStatus).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    if let selected = model.currentModels.first(where: { $0.id == model.configuration.selectedModel }), !selected.detail.isEmpty { Text(selected.detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义模型").font(.system(size: 12)).foregroundStyle(AppTheme.ink)
                        HStack(spacing: 10) {
                            SettingsTextField(title: "自定义模型 ID", placeholder: model.configuration.backend == .pi ? "provider/model" : "输入模型 ID", text: $customModel, onSubmit: applyCustomModel).disabled(model.busy)
                            Button("使用模型", action: applyCustomModel).buttonStyle(QuietButtonStyle(prominent: true))
                                .disabled(model.busy || customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text(model.configuration.backend == .pi ? "使用 provider/model 格式，按回车即可应用。" : "填写 Agent 支持的模型 ID，按回车即可应用。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    }
                }.padding(.vertical, 21)
            }
            SettingsCard {
                row("翻译会话", subtitle: "连续翻译复用会话，重置后下次创建新会话。") {
                    Button("重置会话") { model.resetSession() }.buttonStyle(QuietButtonStyle()).disabled(model.busy)
                }
            }
        }
    }

    private var selectedModelTitle: String {
        let id = model.configuration.selectedModel
        guard !id.isEmpty else { return "使用 Agent 默认模型" }
        guard let item = model.currentModels.first(where: { $0.id == id }) else { return id + "（已保存）" }
        return item.name == item.id ? item.name : item.name + " · " + item.id
    }

    private var modelOptions: [ModelMenuOption] {
        var items = [ModelMenuOption(id: "", title: "使用 Agent 默认模型")]
        items += model.currentModels.map { ModelMenuOption(id: $0.id, title: $0.name == $0.id ? $0.name : $0.name + " · " + $0.id) }
        let selected = model.configuration.selectedModel
        if !selected.isEmpty && !items.contains(where: { $0.id == selected }) { items.append(ModelMenuOption(id: selected, title: selected + "（已保存）")) }
        return items
    }

    private func applyCustomModel() {
        let id = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.busy, !id.isEmpty else { return }
        model.selectModel(id)
    }

    private func radio(_ selected: Bool) -> some View {
        ZStack { Circle().stroke(selected ? AppTheme.green : AppTheme.line.opacity(1.5), lineWidth: selected ? 6 : 1.5).frame(width: 19, height: 19); if selected { Circle().fill(.white).frame(width: 7, height: 7) } }.frame(width: 24, height: 24)
    }

    private var rulesPage: some View {
        Group {
            SettingsCard {
                row("独立翻译规则", subtitle: "通过工作目录中的 AGENTS.md 配置，不写死在请求中。") { Button("打开规则文件…") { model.openTranslationRules() }.buttonStyle(QuietButtonStyle()) }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(["每次只翻译当前选区，不续写上一句", "保留原文含义、语气、姓名与数字", "中文译英文、英文译中文，只输出译文", "开启英文注释时，按 notes 请求解释英文语言点"], id: \.self) { text in HStack(spacing: 10) { Image(systemName: "checkmark").foregroundStyle(AppTheme.green); Text(text) }.font(.system(size: 12)) }
                    Text("以上为默认规则摘要，实际行为以你编辑后的文件为准。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                }.padding(.vertical, 21)
            }
            Text(AgentWorkspace.instructionsFile.path).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsPage: some View {
        Group {
            SettingsCard {
                ForEach(0..<HotKey.titles.count, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    Button { model.configuration.shortcut = index; model.saveSettings() } label: {
                        HStack(spacing: 14) { radio(model.configuration.shortcut == index); Text(HotKey.titles[index]).font(.system(size: 20, weight: .medium, design: .rounded)).tracking(3); Spacer(); Text(index == 0 ? "推荐" : "备选快捷键").font(.system(size: 11)).foregroundStyle(AppTheme.secondary) }.frame(height: 74).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.busy)
                }
            }
            SettingsCard {
                row("有选区时翻译", subtitle: "先松开修饰键，应用再读取原文并开始翻译。") { Image(systemName: "cursorarrow.rays").foregroundStyle(AppTheme.secondary) }
                SettingsDivider()
                row("无选区时打开历史", subtitle: "未选中文字、选区为空或仅有空白时，不调用 Agent，直接展开翻译历史。") { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(AppTheme.secondary) }
            }
        }
    }

    private var privacyPage: some View {
        Group {
            SettingsCard {
                row("辅助功能权限", subtitle: permission ? "已允许读取选区与写回译文。" : "读取选中文字和替换译文需要此权限。") {
                    HStack(spacing: 7) { Circle().fill(permission ? AppTheme.green : .orange).frame(width: 7, height: 7); Text(permission ? "已允许" : "待授权").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                }
                SettingsDivider()
                HStack { Button("打开系统权限设置") { SelectionAccess.requestPermission(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.buttonStyle(QuietButtonStyle(prominent: true)); Button("刷新状态") { model.refreshAccessibilityPermission() }.buttonStyle(QuietButtonStyle()); Spacer() }.padding(.vertical, 19)
                if !permission {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已开启但仍未识别？先退出并重新打开FanyiX。若仍无效，在系统列表中移除旧条目，再添加当前这份应用。开发版本重新构建后可能需要重新授权。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("定位当前应用") { model.revealApplicationForPermission() }.buttonStyle(QuietButtonStyle())
                        Text(Bundle.main.bundleURL.path).font(.system(size: 10)).foregroundStyle(AppTheme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 16)
                }
            }
            SettingsCard {
                row("本机进程通信", subtitle: "应用直接调用已安装的 Agent，不启动 HTTP 服务，不监听端口。") { Image(systemName: "desktopcomputer").foregroundStyle(AppTheme.secondary) }
                SettingsDivider()
                row("文字与模型服务", subtitle: "使用云端模型时，选中文字会发送到该模型服务。本机调用不等于离线推理。") { Image(systemName: "cloud").foregroundStyle(AppTheme.secondary) }
                SettingsDivider()
                row("保护你的新输入", subtitle: "选区或焦点变化后，只保留译文。微信兼容模式在输入、点击或切换窗口后停止自动替换；密码框不翻译，不自动发送消息。") { Image(systemName: "lock").foregroundStyle(AppTheme.secondary) }
            }
        }
    }

    private var aboutPage: some View {
        Group {
            SettingsCard {
                VStack(alignment: .leading, spacing: 20) {
                    AppMark(size: 52)
                    Text("FanyiX").font(.system(size: 24, weight: .semibold))
                    Text("选中一句话，换一种表达。").font(.system(size: 16))
                    Text("在网页、聊天或文档中选中文字，按下快捷键，让 AI Agent 帮你进行中英文互译。").font(.system(size: 12)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                }.padding(.vertical, 27)
            }
            Text("可编辑的选区自动替换，只读文字在翻译历史中查看。").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
        }
    }
}
