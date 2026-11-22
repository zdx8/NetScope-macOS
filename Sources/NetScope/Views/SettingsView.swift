import SwiftUI

/// 独立设置视图：自定义分组表单、胶囊开关行与分段控件，视觉语言与主面板统一。
struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                menuBarCard
                appearanceCard
                samplingCard
                alertsCard
            }
            .padding(.horizontal, Ax.s4)
            .padding(.top, Ax.s3)
            .padding(.bottom, Ax.s2)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 菜单栏

    private var menuBarCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            AxSectionTitle(title: "菜单栏", trailing: "至少保留一项")

            SettingToggleRow(title: "显示 CPU 占用",
                             isOn: menuBarBinding(get: { settings.menuBarShowsCPU },
                                                  set: { settings.menuBarShowsCPU = $0 },
                                                  othersVisible: settings.menuBarShowsMemory || settings.menuBarShowsNetwork))
            AxDivider()
            SettingToggleRow(title: "显示内存占用",
                             isOn: menuBarBinding(get: { settings.menuBarShowsMemory },
                                                  set: { settings.menuBarShowsMemory = $0 },
                                                  othersVisible: settings.menuBarShowsCPU || settings.menuBarShowsNetwork))
            AxDivider()
            SettingToggleRow(title: "显示网络速率",
                             isOn: menuBarBinding(get: { settings.menuBarShowsNetwork },
                                                  set: { settings.menuBarShowsNetwork = $0 },
                                                  othersVisible: settings.menuBarShowsCPU || settings.menuBarShowsMemory))
            AxDivider()

            SettingSegmentRow(title: "网络图标形态",
                              options: Settings.NetworkBarStyle.allCases.map { ($0, $0.label) },
                              selection: $settings.networkBarStyle)
        }
    }

    private func menuBarBinding(get: @escaping () -> Bool,
                                set: @escaping (Bool) -> Void,
                                othersVisible: Bool) -> Binding<Bool> {
        Binding(
            get: get,
            set: { newValue in
                if !newValue && !othersVisible {
                    NSSound.beep()
                    return
                }
                set(newValue)
            }
        )
    }

    // MARK: - 外观

    private var appearanceCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            AxSectionTitle(title: "外观")
            SettingSegmentRow(title: "面板主题",
                              subtitle: "仅作用于弹出面板，菜单栏徽标跟随系统",
                              options: Settings.AppearanceTheme.allCases.map { ($0, $0.label) },
                              selection: $settings.appearanceTheme)
        }
    }

    // MARK: - 采样与列表

    private var samplingCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            AxSectionTitle(title: "采样与列表")

            SettingSegmentRow(title: "刷新间隔",
                              options: [1, 2, 3, 5].map { ($0, "\($0)s") },
                              selection: $settings.sampleInterval)

            AxDivider()

            SettingSegmentRow(title: "列表条数",
                              options: [5, 8, 12].map { ($0, "\($0)") },
                              selection: $settings.maxVisibleRows)

            AxDivider()

            SettingToggleRow(title: "仅统计物理链路",
                             subtitle: "各应用之和与总量一致，但不显示 VPN 隧道内应用",
                             isOn: $settings.physicalOnlyList)
        }
    }

    // MARK: - 提醒与启动

    private var alertsCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            AxSectionTitle(title: "提醒与启动")

            SettingToggleRow(title: "高流量告警",
                             subtitle: "连续 3 秒超阈值时推送通知（10 分钟冷却）",
                             isOn: $settings.alertsEnabled)

            if settings.alertsEnabled {
                AxDivider()
                SettingSegmentRow(title: "告警阈值",
                                  options: [1.0, 5.0, 10.0, 20.0].map { ($0, "\(Int($0))M") },
                                  selection: $settings.alertThresholdMBps)
            }

            AxDivider()

            SettingToggleRow(title: "开机自动启动",
                             subtitle: "需将 NetScope.app 置于「应用程序」目录",
                             isOn: $settings.launchAtLogin)
        }
    }
}

// MARK: - 自定义表单行组件

private struct SettingToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Ax.s2) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Ax.s2)

            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(isOn ? Theme.healthy : Theme.surfaceMuted)
                        .frame(width: 30, height: 17)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isOn ? Color.clear : Theme.border, lineWidth: 1)
                        )

                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        .padding(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "已开启" : "已关闭")
        }
        .padding(.vertical, 2)
    }
}

private struct SettingSegmentRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Ax.s2) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Ax.s2)

            HStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let selected = option.0 == selection
                    Button {
                        guard !selected else { return }
                        selection = option.0
                    } label: {
                        Text(option.1)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(selected ? Theme.surfaceElevated : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .strokeBorder(selected ? Theme.border : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusInner + 1, style: .continuous)
                    .fill(Theme.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ax.radiusInner + 1, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(.vertical, 2)
    }
}
