import SwiftUI

/// 「系统」页下半部分的程序列表：统一 `PanelListCard` 卡内吸顶表头 + 悬停覆盖式二次确认关闭。
struct ProcessListSection: View {
    let rows: [ProcessUsageRow]
    @Binding var sort: ProcessMetric
    var accent: Color
    var onClose: (ProcessUsageRow) -> Void

    private var sorted: [ProcessUsageRow] {
        switch sort {
        case .cpu: return rows.sorted { $0.cpu > $1.cpu }
        case .memory: return rows.sorted { $0.memory > $1.memory }
        }
    }

    private var peak: Double {
        switch sort {
        case .cpu: return max(sorted.first?.cpu ?? 0, 0.1)
        case .memory: return max(Double(sorted.first?.memory ?? 0), 1)
        }
    }

    var body: some View {
        PanelListCard {
            header
        } content: {
            if sorted.isEmpty {
                VStack(spacing: Ax.s2) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                    Text("正在采集进程数据…")
                        .font(AxFont.supporting)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
            } else {
                ForEach(sorted) { row in
                    ProcessRowView(row: row,
                                   metric: sort,
                                   peak: peak,
                                   accent: accent,
                                   onClose: onClose)
                    if row.id != sorted.last?.id {
                        AxDivider(inset: Ax.s3 + 24)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 卡内吸顶表头：「程序（N）  [按 CPU | 按内存]」
    private var header: some View {
        HStack(spacing: Ax.s2) {
            Text("程序")
                .font(AxFont.caption)
                .foregroundStyle(Theme.textTertiary)

            Text("\(rows.count)")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.surface)
                )

            Spacer(minLength: Ax.s2)

            HStack(spacing: 2) {
                ForEach([ProcessMetric.cpu, .memory], id: \.self) { metric in
                    sortButton(metric)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private func sortButton(_ metric: ProcessMetric) -> some View {
        let selected = sort == metric
        return Button {
            guard !selected else { return }
            sort = metric
        } label: {
            Text(metric.sortTitle)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Theme.surfaceMuted : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(metric == .cpu ? "按 CPU 占用排序" : "按内存占用排序")
    }
}

private struct ProcessRowView: View {
    let row: ProcessUsageRow
    let metric: ProcessMetric
    let peak: Double
    let accent: Color
    var onClose: (ProcessUsageRow) -> Void

    @State private var hovering = false
    @State private var confirmingClose = false

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: Ax.s2) {
                icon
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(AxFont.label)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.name)

                    AxMeter(fraction: fraction, color: accent, height: 2.5)
                        .frame(maxWidth: 108)
                }

                Spacer(minLength: Ax.s2)

                // 数值列固定在右侧，悬停按钮覆盖在上方而不挤动布局
                VStack(alignment: .trailing, spacing: 1) {
                    Text(primary)
                        .font(AxFont.number(12))
                        .foregroundStyle(Theme.textPrimary)
                    Text(secondary)
                        .font(AxFont.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
                .frame(width: 68, alignment: .trailing)
                .opacity((hovering && row.canClose) ? 0.12 : 1)
            }

            if hovering, row.canClose {
                closeOverlayButton
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .padding(.horizontal, Ax.s3)
        .frame(height: Ax.rowHeight)
        .contentShape(Rectangle())
        .background(hovering ? Theme.hover : Color.clear)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hovering = inside
                if !inside { confirmingClose = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var closeOverlayButton: some View {
        Button {
            if confirmingClose {
                confirmingClose = false
                onClose(row)
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    confirmingClose = true
                }
            }
        } label: {
            Text(confirmingClose ? "确认关闭？" : "关闭")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(confirmingClose ? Color.white : Theme.fault)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(confirmingClose ? Theme.fault : Theme.fault.opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.fault.opacity(confirmingClose ? 0 : 0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(confirmingClose
              ? "再次点击以结束「\(row.name)」的 \(row.processCount) 个进程"
              : "向「\(row.name)」的 \(row.processCount) 个进程发送退出信号")
    }

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        switch metric {
        case .cpu: return min(row.cpu / peak, 1)
        case .memory: return min(Double(row.memory) / peak, 1)
        }
    }

    private var primary: String {
        switch metric {
        case .cpu: return PercentFormat.process(row.cpu)
        case .memory: return ByteFormat.size(row.memory)
        }
    }

    private var secondary: String {
        switch metric {
        case .cpu: return row.processCount > 1 ? "\(row.processCount) 进程" : "单进程"
        case .memory: return String(format: "%.1f%%", row.memoryPercent)
        }
    }

    private var accessibilityText: String {
        switch metric {
        case .cpu: return "\(row.name)，CPU \(PercentFormat.process(row.cpu))，\(row.processCount) 个进程"
        case .memory: return "\(row.name)，内存 \(ByteFormat.size(row.memory))，占 \(secondary)"
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
