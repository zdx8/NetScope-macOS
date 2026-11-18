import SwiftUI

/// 菜单栏弹窗的根视图：顶部「清理释放 / 系统功能」两个选项栏，下面是内容与页脚。
///
/// 1.1.7 之前是三个独立面板（CPU / 内存 / 网络）。现在按需求合并为两页：
/// - 清理释放 = CPU + 内存 + 程序列表（两种排序、悬停可关闭）；
/// - 系统功能 = 磁盘占用（含可用空间）/ 本机速率，样式对齐 CPU/内存指标卡。
struct DashboardView: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var settings: Settings
    @ObservedObject var router: PanelRouter

    @State private var showSettings: Bool

    init(engine: MonitorEngine, settings: Settings, router: PanelRouter,
         showSettingsInitially: Bool = false) {
        _engine = ObservedObject(wrappedValue: engine)
        _settings = ObservedObject(wrappedValue: settings)
        _router = ObservedObject(wrappedValue: router)
        _showSettings = State(initialValue: showSettingsInitially)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if showSettings {
                settingsPanel
            } else {
                switch router.tab {
                case .cleanup:
                    CleanupTab(monitor: engine.systemLoad,
                               sort: $router.sort,
                               onClose: { row in engine.systemLoad.close(row) })
                case .system:
                    SystemTab(engine: engine, settings: settings, router: router)
                }
            }
            footer
        }
        .frame(width: Ax.panelWidth, height: Ax.panelHeight)
        .background(Theme.background)
    }

    // MARK: - 选项栏

    private var tabBar: some View {
        AxTabBar(options: [
            .init(value: PanelRouter.Tab.cleanup, title: "清理释放"),
            .init(value: PanelRouter.Tab.system, title: "系统功能")
        ], selection: Binding(get: { router.tab },
                          set: { newValue in
                              router.tab = newValue
                              if showSettings { showSettings = false }
                          }))
        .padding(.horizontal, Ax.s4)
        .frame(height: Ax.headerHeight, alignment: .bottom)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { AxDivider() }
    }

    // MARK: - 设置

    private var settingsPanel: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                AxCard(padding: Ax.s3, spacing: Ax.s2) {
                    AxSectionTitle(title: "菜单栏")
                    HStack(spacing: Ax.s3) {
                        Toggle("CPU", isOn: $settings.menuBarShowsCPU).toggleStyle(.checkbox)
                        Toggle("内存", isOn: $settings.menuBarShowsMemory).toggleStyle(.checkbox)
                        Toggle("网络", isOn: $settings.menuBarShowsNetwork).toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                    }
                    .font(AxFont.supporting)
                    .help("三段共用菜单栏上的一项，关掉不关心的段即可缩短宽度")

                    settingRow("网络图标") {
                        Picker("网络图标", selection: $settings.networkBarStyle) {
                            ForEach(Settings.NetworkBarStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 116)
                    }
                }

                AxCard(padding: Ax.s3, spacing: Ax.s2) {
                    AxSectionTitle(title: "外观")
                    settingRow("主题") {
                        Picker("主题", selection: $settings.appearanceTheme) {
                            ForEach(Settings.AppearanceTheme.allCases) { theme in
                                Text(theme.label).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 156)
                        .help("只影响面板；菜单栏徽标跟随系统菜单栏的深浅")
                    }
                }

                AxCard(padding: Ax.s3, spacing: Ax.s2) {
                    AxSectionTitle(title: "采样")
                    settingRow("刷新间隔") {
                        Picker("刷新间隔", selection: $settings.sampleInterval) {
                            ForEach([1, 2, 3, 5], id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 116)
                    }
                    settingRow("显示条数") {
                        Picker("显示条数", selection: $settings.maxVisibleRows) {
                            ForEach([5, 8, 12], id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 116)
                    }
                    Toggle("列表只统计物理链路", isOn: $settings.physicalOnlyList)
                        .toggleStyle(.checkbox)
                        .font(AxFont.supporting)
                        .help("开启后各应用之和与总量一致，但走 VPN 隧道内的应用将不再显示")
                }

                AxCard(padding: Ax.s3, spacing: Ax.s2) {
                    AxSectionTitle(title: "提醒")
                    Toggle("流量告警", isOn: $settings.alertsEnabled)
                        .toggleStyle(.checkbox)
                        .font(AxFont.supporting)
                    if settings.alertsEnabled {
                        settingRow("阈值 (MB/s)") {
                            Picker("阈值", selection: $settings.alertThresholdMBps) {
                                ForEach([1.0, 5.0, 10.0, 20.0], id: \.self) { mbps in
                                    Text("\(Int(mbps))").tag(mbps)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 116)
                        }
                    }
                    Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                        .toggleStyle(.checkbox)
                        .font(AxFont.supporting)
                }
            }
            .padding(.horizontal, Ax.s4)
            .padding(.top, Ax.s3)
            .padding(.bottom, Ax.s1)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    private func settingRow<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Ax.s2) {
            Text(title)
                .font(AxFont.supporting)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Ax.s2)
            content()
        }
        .frame(height: 22)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: Ax.s1) {
            Button {
                engine.togglePause()
            } label: {
                Label(engine.isPausedNow ? "继续" : "暂停",
                      systemImage: engine.isPausedNow ? "play.fill" : "pause.fill")
            }
            .buttonStyle(AxGhostButtonStyle())

            Button {
                engine.resetSession()
            } label: {
                Label("重置", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(AxGhostButtonStyle())

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showSettings.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(AxGhostButtonStyle(tint: showSettings ? Theme.textPrimary : Theme.textSecondary,
                                            compact: true))
            .help("设置")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(AxGhostButtonStyle(compact: true))
            .help("退出 NetScope")
        }
        .padding(.horizontal, Ax.s3)
        .frame(height: Ax.footerHeight)
        .background(Theme.surface)
        .overlay(alignment: .top) { AxDivider() }
    }
}
