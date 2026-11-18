import SwiftUI

/// 「清理释放」页下半部分的程序列表。
///
/// 三个交互：
/// 1. 两种排序（按 CPU / 按内存），选中项高亮——同一份数据，不重新采样；
/// 2. 固定高度 + 内部滚动：面板尺寸不随进程数变化，末行也不会被裁；
/// 3. 鼠标移到某行时，右侧出现「关闭」，直接对该应用聚合到的 pid 发 SIGTERM。
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

    /// 进度条的归一化基准：榜首那一条占满，其余按比例
    private var peak: Double {
        switch sort {
        case .cpu: return max(sorted.first?.cpu ?? 0, 0.1)
        case .memory: return max(Double(sorted.first?.memory ?? 0), 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 2)
                .padding(.bottom, Ax.s2)

            Group {
                if sorted.isEmpty {
                    VStack(spacing: Ax.s2) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textTertiary)
                        Text("正在采集进程数据…")
                            .font(AxFont.supporting)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(sorted) { row in
                                ProcessRowView(row: row, metric: sort, peak: peak,
                                               accent: accent, onClose: onClose)
                                // 最后一行不画分隔线：否则会贴着卡片下沿，看起来像被裁掉
                                if row.id != sorted.last?.id {
                                    AxDivider(inset: Ax.s3 + 24)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .clipShape(RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous))
                }
            }
            .frame(height: 209)   // 6 行 × 34pt + 5 条分隔线：刚好整行，末行不会被裁
                                  // （1.2.1 面板加高到 560 后从 5 行扩到 6 行）
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 「程序 ［按 CPU｜按内存］ N 个」
    private var header: some View {
        HStack(spacing: Ax.s2) {
            Text("程序")
                .font(AxFont.section)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: Ax.s2)

            HStack(spacing: 2) {
                ForEach([ProcessMetric.cpu, .memory], id: \.self) { metric in
                    sortButton(metric)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                    .fill(Theme.surfaceMuted)
            )

            Text("\(rows.count) 个")
                .font(AxFont.caption)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    private func sortButton(_ metric: ProcessMetric) -> some View {
        let selected = sort == metric
        return Button {
            guard !selected else { return }
            sort = metric
        } label: {
            Text(metric.sortTitle)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Theme.surface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? Theme.border : Color.clear, lineWidth: 1)
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

    var body: some View {
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

            VStack(alignment: .trailing, spacing: 1) {
                Text(primary)
                    .font(AxFont.number(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(secondary)
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            .frame(width: 62, alignment: .trailing)

            // 悬停时才出现「关闭」：常态下这一列不存在，行内数字不会被永久挤窄
            if hovering, row.canClose {
                Button("关闭") { onClose(row) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.fault)
                    .help("向「\(row.name)」的 \(row.processCount) 个进程发送退出信号")
            }
        }
        .padding(.horizontal, Ax.s3)
        .frame(height: Ax.rowHeight)
        .contentShape(Rectangle())
        .modifier(AxHoverBackground())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
