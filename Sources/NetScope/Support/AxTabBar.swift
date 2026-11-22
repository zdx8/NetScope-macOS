import SwiftUI

/// 顶部胶囊分段选项栏：紧凑的槽位底 + 抬升选中胶囊，适配 macOS 菜单栏弹窗。
struct AxTabBar<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String

        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                tab(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func tab(_ option: Option) -> some View {
        let selected = option.value == selection
        return Button {
            guard !selected else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                selection = option.value
            }
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(selected ? Theme.surfaceElevated : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .strokeBorder(selected ? Theme.border : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
