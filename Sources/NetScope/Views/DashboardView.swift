import SwiftUI

/// 菜单栏弹窗的根视图：顶部胶囊分段导航 + 状态指示，或独立设置导航头，底部为上下文工具栏。
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
            headerBar
            if showSettings {
                SettingsView(settings: settings)
            } else {
                switch router.tab {
                case .cleanup:
                    ResourcesTab(monitor: engine.systemLoad,
                                 sort: $router.sort,
                                 onClose: { row in engine.systemLoad.close(row) })
                case .system:
                    NetworkTab(engine: engine, settings: settings, router: router)
                }
            }
            footer
        }
        .frame(width: Ax.panelWidth, height: Ax.panelHeight)
        .background(Theme.background)
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(spacing: Ax.s2) {
            if showSettings {
                settingsHeader
            } else {
                monitorHeader
            }
        }
        .padding(.horizontal, Ax.s4)
        .frame(height: Ax.headerHeight)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { AxDivider() }
    }

    private var monitorHeader: some View {
        Group {
            AxTabBar(options: [
                .init(value: PanelRouter.Tab.system, title: "网络"),
                .init(value: PanelRouter.Tab.cleanup, title: "系统")
            ], selection: $router.tab)

            Spacer(minLength: Ax.s2)

            HStack(spacing: 5) {
                if engine.isTunnelActive {
                    AxStatusBadge(text: "VPN",
                                  tint: Theme.up,
                                  symbol: "lock.shield.fill")
                        .help(tunnelHelpText)
                }

                AxStatusBadge(text: statusShortText,
                              tint: Theme.accent(for: engine.status))
                    .help(engine.status.label)
            }
        }
    }

    private var settingsHeader: some View {
        Group {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSettings = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .buttonStyle(AxGhostButtonStyle(tint: Theme.textPrimary, compact: true))
            .help("返回监控面板")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 14)

            Text("设置")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 0)

            AxChip(text: "v\(AppInfo.version)", tint: Theme.textSecondary)
        }
    }

    private var statusShortText: String {
        switch engine.status {
        case .running: return "监控中"
        case .starting: return "启动中"
        case .paused: return "已暂停"
        case .failed: return "异常"
        }
    }

    private var tunnelHelpText: String {
        if engine.tunnelNames.isEmpty {
            return "检测到活动 VPN 隧道：总量仅统计物理网卡"
        }
        return "活动隧道：\(engine.tunnelNames.joined(separator: ", "))（总量仅统计物理网卡）"
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: Ax.s1) {
            if showSettings {
                Text("NetScope · 本地实时监控")
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, Ax.s1)

                Spacer(minLength: 0)

                Button("完成") {
                    withAnimation(.easeInOut(duration: 0.16)) { showSettings = false }
                }
                .buttonStyle(AxGhostButtonStyle(tint: Theme.textPrimary, compact: true))
            } else {
                Button {
                    engine.togglePause()
                } label: {
                    Label(engine.isPausedNow ? "继续" : "暂停",
                          systemImage: engine.isPausedNow ? "play.fill" : "pause.fill")
                }
                .buttonStyle(AxGhostButtonStyle(compact: true))

                Button {
                    engine.resetSession()
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AxGhostButtonStyle(compact: true))

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showSettings.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                }
                .buttonStyle(AxGhostButtonStyle(compact: true))
                .help("设置")
            }

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
