import SwiftUI

/// 一欄的定義：標題、寬度（nil 為彈性）、對齊、排序方式與內容。
/// `sort` 的 order 是第一次點這欄時的方向。
struct PlainColumn<Row> {
    let title: String
    var width: CGFloat?
    var alignment: Alignment = .leading
    var sort: KeyPathComparator<Row>?
    let cell: (Row) -> AnyView

    init<Cell: View>(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading,
                     sort: KeyPathComparator<Row>? = nil, @ViewBuilder cell: @escaping (Row) -> Cell) {
        self.title = title
        self.width = width
        self.alignment = alignment
        self.sort = sort
        self.cell = { AnyView(cell($0)) }
    }
}

/// 簡單的表格：表頭固定在上方、實心不透明，捲動的列直接被表頭蓋住，
/// 不會像 macOS 26 系統表格那樣在表頭底下模糊淡出。
struct PlainTable<Row: Identifiable>: View {
    @Environment(\.theme) private var theme
    let rows: [Row]
    let columns: [PlainColumn<Row>]
    /// 有給的話，點有 `sort` 的表頭可切換排序；同一欄再點一次反轉方向。
    var sortOrder: Binding<[KeyPathComparator<Row>]>?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        line { $0.cell(row) }
                            .accessibilityElement(children: .combine)
                            .font(.callout.monospacedDigit())
                            .padding(.vertical, 5)
                            .background(index.isMultiple(of: 2) ? Color.clear : stripe)
                    }
                } header: {
                    line { column in AnyView(header(column)) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.isHack ? theme.accent : .secondary)
                        .padding(.vertical, 6)
                        .background(headerBackground)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.isHack ? theme.accent.opacity(0.4) : Color.primary.opacity(0.12))
                                .frame(height: 1)
                        }
                }
            }
        }
        .modifier(NoScrollEdgeEffect())
    }

    private func line(_ content: @escaping (PlainColumn<Row>) -> AnyView) -> some View {
        HStack(spacing: 12) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                if let width = column.width {
                    content(column).lineLimit(1).frame(width: width, alignment: column.alignment)
                } else {
                    content(column).lineLimit(1).frame(maxWidth: .infinity, alignment: column.alignment)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func header(_ column: PlainColumn<Row>) -> some View {
        if let sort = column.sort, let sortOrder {
            let current = sortOrder.wrappedValue.first.flatMap { $0.keyPath == sort.keyPath ? $0 : nil }
            Button {
                var next = sort
                if let current { next.order = current.order == .forward ? .reverse : .forward }
                sortOrder.wrappedValue = [next]
            } label: {
                HStack(spacing: 3) {
                    Text(column.title)
                    if let current {
                        Image(systemName: current.order == .forward ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(theme.isHack ? theme.accent : current != nil ? .primary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(current.map { $0.order == .forward ? "遞增排序" : "遞減排序" } ?? "")
        } else {
            Text(column.title)
        }
    }

    /// 表頭用實心顏色，不用材質或模糊。
    private var headerBackground: Color {
        switch theme.kind {
        case .hack: Color(red: 0.01, green: 0.03, blue: 0.02)
        case .glass where theme.isGlass: Color(white: 0.11)
        default: Color(nsColor: .windowBackgroundColor)
        }
    }

    private var stripe: Color {
        theme.isHack ? theme.accent.opacity(0.05) : Color.primary.opacity(0.04)
    }
}

private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}
