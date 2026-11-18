import SwiftUI

/// 顶部文字选项栏（对齐参考图：选中项加粗 + 2pt 下划线，未选中为次级灰）。
///
/// 为什么不用 `Picker(.segmented)`：分段控件自带灰色胶囊底和边框，
/// 放在面板顶部会和卡片描边叠成两层线；参考图里的选项栏是「纯文字 + 下划线」，
/// 视觉上更轻，也不会把标题行挤成控件行。
struct AxTabBar<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String

        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Ax.s6) {
            ForEach(options) { option in
                tab(option)
            }
            Spacer(minLength: 0)
        }
    }

    private func tab(_ option: Option) -> some View {
        let selected = option.value == selection
        return Button {
            guard !selected else { return }
            selection = option.value
        } label: {
            VStack(spacing: 5) {
                Text(option.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Rectangle()
                    .fill(selected ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
            // 不加 fixedSize 时下划线会被 HStack 的剩余宽度撑长，看起来像一条横贯面板的线
            .fixedSize()
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
