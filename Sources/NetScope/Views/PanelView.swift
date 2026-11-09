import SwiftUI

/// 菜单栏弹出面板。
struct PanelView: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var settings: Settings

    @State private var showSettings = false
    @State private var mode: PanelMode = .live

    private let panelWidth: CGFloat = 348

    enum PanelMode {
        case live
        case history
    }

    /// `initialMode` / `showSettingsInitially` 供截图与调试直接落到指定状态。
    init(engine: MonitorEngine,
         settings: Settings,
         initialMode: PanelMode = .live,
         showSettingsInitially: Bool = false) {
        _engine = ObservedObject(wrappedValue: engine)
        _settings = ObservedObject(wrappedValue: settings)
        _mode = State(initialValue: initialMode)
        _showSettings = State(initialValue: showSettingsInitially)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            switch mode {
            case .live:
                summary
                chart
                divider
                listSection
            case .history:
                divider
                HistorySection(
                    todayTotal: engine.todayTotal,
                    weekTotal: engine.weekTotal,
                    topApps: engine.topAppsInHistory,
                    dailyTotals: engine.dailyTotals
                )
            }

            divider
            if showSettings {
                settingsSection
                divider
            }
            footer
        }
        .frame(width: panelWidth)
        .onChange(of: mode) { _, newValue in
            if newValue == .history { engine.refreshHistory() }
        }
        .onAppear {
            if mode == .history { engine.refreshHistory() }
        }
    }

    // MARK: - 顶部状态

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.accent(for: engine.status))
                .frame(width: 7, height: 7)
            Text("NetScope")
                .font(.system(size: 12, weight: .semibold))
            if engine.isTunnelActive {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.healthy)
                    .help(tunnelHelp)
            }
            Spacer(minLength: 8)
            Text(statusDetail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    mode = mode == .live ? .history : .live
                }
            } label: {
                Image(systemName: mode == .live ? "chart.bar.xaxis" : "waveform.path.ecg")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(mode == .live ? "查看历史用量" : "回到实时速率")
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 7)
    }

    private var tunnelHelp: String {
        let interfaces = engine.tunnelNames.joined(separator: "、")
        var lines = ["已检测到 VPN 隧道（\(interfaces)）"]
        if engine.isUsingPhysicalTotal {
            lines.append("总量按物理网卡统计，不含虚拟接口的重复计数")
        } else {
            lines.append("总量已退化为全接口合计（物理网卡采样不可用）")
        }
        lines.append("列表中的 VPN 应用显示的是它在物理链路上的加密流量，因此各应用之和会大于总量")
        return lines.joined(separator: "\n")
    }

    private var statusDetail: String {
        switch engine.status {
        case .running:
            var parts = ["\(engine.processCount) 个进程", "每 \(settings.sampleInterval) 秒"]
            if engine.isTunnelActive { parts.append("VPN") }
            return parts.joined(separator: " · ")
        case .starting:
            return "正在采集…"
        case .paused:
            return "已暂停"
        case .failed(let reason):
            return reason
        }
    }

    // MARK: - 速率总览

    private var summary: some View {
        HStack(alignment: .top) {
            rateBlock(title: "下行", value: engine.totalDown, total: engine.sessionDown,
                      icon: "arrow.down", color: Theme.down, alignment: .leading)
            Spacer(minLength: 12)
            rateBlock(title: "上行", value: engine.totalUp, total: engine.sessionUp,
                      icon: "arrow.up", color: Theme.up, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func rateBlock(title: String, value: Double, total: UInt64,
                           icon: String, color: Color,
                           alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 4) {
                if alignment == .leading {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(ByteFormat.rate(value))
                    .font(.system(size: 19, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                if alignment == .trailing {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            Text("本次 \(ByteFormat.size(total))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var chart: some View {
        VStack(spacing: 4) {
            Sparkline(history: engine.history, height: 48)
            HStack {
                Text("近 \(engine.history.capacity * max(settings.sampleInterval, 1)) 秒")
                Spacer()
                if engine.history.points.count > 1 {
                    Text("峰值 \(ByteFormat.rate(engine.history.peak))")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 应用列表

    private var listSection: some View {
        Group {
            if engine.rows.isEmpty {
                VStack(spacing: 8) {
                    if case .failed = engine.status {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.fault)
                        Text("无法读取网络计数")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("重试") { engine.start() }
                            .controlSize(.small)
                    } else if engine.sampleCount == 0 {
                        ProgressView().controlSize(.small)
                        Text("正在采集…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                        Text("当前没有活跃网络流量")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("系统级守护进程的后台同步可能仍在进行")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 132)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(engine.rows) { row in
                            AppRowView(row: row, fraction: fraction(for: row))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                }
                // 上限留足 8 行的空间（每行约 40pt + 内边距）：
                // 设小了会把最后一行裁掉，而 SwiftUI 不会报任何错。
                .frame(maxHeight: 380)
            }
        }
    }

    private func fraction(for row: AppTrafficRow) -> Double {
        guard engine.peakRowTotal > 0 else { return 0 }
        return row.total / engine.peakRowTotal
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(spacing: 7) {
            toggleRow("菜单栏趋势图", isOn: $settings.showMenuBarSparkline)
            HStack {
                Text("刷新间隔")
                Spacer()
                Picker("刷新间隔", selection: $settings.sampleInterval) {
                    ForEach([1, 2, 3, 5], id: \.self) { seconds in
                        Text("\(seconds)s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 124)
            }
            HStack {
                Text("显示条数")
                Spacer()
                Picker("显示条数", selection: $settings.maxVisibleRows) {
                    ForEach([5, 8, 12], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 124)
            }

            Divider().opacity(0.4).padding(.vertical, 1)

            toggleRow("列表只统计物理链路", isOn: $settings.physicalOnlyList)
                .help("开启后各应用之和与总量一致，但走 VPN 隧道内的应用将不再显示")

            toggleRow("流量告警", isOn: $settings.alertsEnabled)
            if settings.alertsEnabled {
                HStack {
                    Text("阈值 (MB/s)")
                    Spacer()
                    Picker("阈值", selection: $settings.alertThresholdMBps) {
                        ForEach([1.0, 5.0, 10.0, 20.0], id: \.self) { mbps in
                            Text("\(Int(mbps))").tag(mbps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 124)
                }
            }

            Divider().opacity(0.4).padding(.vertical, 1)

            toggleRow("开机自动启动", isOn: $settings.launchAtLogin)
        }
        .font(.system(size: 11))
        .controlSize(.mini)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 复选框样式：`.switch` + `.mini` 在这个宽度下状态几乎看不出来（实测开关恒显示为关），
    /// 而复选框的勾选状态在任何尺寸下都清晰。
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton(
                title: engine.isPausedNow ? "继续" : "暂停",
                icon: engine.isPausedNow ? "play.fill" : "pause.fill"
            ) {
                engine.togglePause()
            }
            footerButton(title: "重置", icon: "arrow.counterclockwise") {
                engine.resetSession()
            }
            Spacer(minLength: 0)
            footerButton(title: nil, icon: "slider.horizontal.3") {
                withAnimation(.easeInOut(duration: 0.16)) { showSettings.toggle() }
            }
            footerButton(title: "退出", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func footerButton(title: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                if let title {
                    Text(title).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var divider: some View {
        Divider().opacity(0.55)
    }
}
