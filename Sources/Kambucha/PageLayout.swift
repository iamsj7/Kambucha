import SwiftUI
import AppKit

/// The one layout rule for the main window's detail column. A reading page is a column of at most `readingWidth`, centred
/// when the window is wider. A data page fills the column. Both start directly under the toolbar, which holds every
/// switcher and filter, and empty, error and loading states use `PageState`, so they land in the same place on every screen.
enum PageLayout {
    enum Kind { case reading, data }

    /// Width of a reading page's cards.
    static let readingWidth: CGFloat = 720
    /// A grouped Form's own side margin, which a reading page's banners and cards line up on.
    static let inset: CGFloat = 20
    /// Where a List's and a Table's rows start, which a data page's banners and text line up on.
    static let dataInset: CGFloat = 16
    /// Between a banner and what's next to it.
    static let bannerGap: CGFloat = 8
    static let cardRadius: CGFloat = 12

    /// What a reading page adds to each side, on top of a Form's own `inset`, to centre its column in `width`.
    static func readingMargin(in width: CGFloat) -> CGFloat {
        max(0, (width - readingWidth) / 2 - inset)
    }
}

extension View {
    /// Centres a scrolling page's column. Safe area and not a frame, so the scroller stays at the window's edge and the
    /// margins scroll too. `ownInset` is for a List, which has no side margin of its own as a Form has.
    func readingColumn(ownInset: Bool = false) -> some View { modifier(ReadingColumn(ownInset: ownInset)) }

    /// The page's width.
    func measuringWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self, of: \.size.width) { width.wrappedValue = $0 }
    }
}

private struct ReadingColumn: ViewModifier {
    let ownInset: Bool
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.horizontal, PageLayout.readingMargin(in: width) + (ownInset ? PageLayout.inset : 0))
            .measuringWidth($width)
    }
}

/// A reading page.
struct ReadingForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .readingColumn()
    }
}

extension EnvironmentValues {
    /// Moves a `PageState` back to where it would sit with no banners, so a banner can't move it.
    @Entry fileprivate var pageStateShift: CGFloat = 0
    @Entry fileprivate var pageKind = PageLayout.Kind.data
}

/// An empty, error or loading state. Fills what the page has below the toolbar and centres in it.
struct PageState<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.pageStateShift) private var shift

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: shift)
    }
}

extension PageState where Content == ProgressView<Text, EmptyView> {
    init(loading title: LocalizedStringKey) { self.init { ProgressView(title) } }
}

/// A warning or reminder, at the page's side inset. Goes in a `BannerPage`.
struct PageBanner<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.pageKind) private var kind

    var body: some View {
        HStack { content }
            .padding(PageLayout.bannerGap + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PageCard.fill, in: .rect(cornerRadius: PageLayout.cardRadius))
            .padding(.horizontal, kind == .reading ? PageLayout.inset : PageLayout.dataInset)
            .padding(.vertical, PageLayout.bannerGap / 2)
            .accessibilityElement(children: .contain)
    }
}

/// A data page's scope: what it's showing, and its main action. Under the toolbar and not in it, as a toolbar has room for
/// one switcher and search, and overflows the rest into a menu.
struct PageScopeBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { content }
                .padding(.horizontal, PageLayout.dataInset)
                .padding(.vertical, PageLayout.bannerGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}

/// A page with banners above and below it. They stay put while the page scrolls.
struct BannerPage<Top: View, Content: View, Bottom: View>: View {
    var kind = PageLayout.Kind.data
    @ViewBuilder var top: Top
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            banners(top, height: $topHeight)
            content.environment(\.pageStateShift, (bottomHeight - topHeight) / 2)
            banners(bottom, height: $bottomHeight)
        }
    }

    private func banners(_ content: some View, height: Binding<CGFloat>) -> some View {
        VStack(spacing: 0) { content }
            .environment(\.pageKind, kind)
            .frame(maxWidth: kind == .reading ? PageLayout.readingWidth + 2 * PageLayout.inset : .infinity)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height.wrappedValue = $0 }
    }
}

extension BannerPage where Bottom == EmptyView {
    init(kind: PageLayout.Kind = .data, @ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content) {
        self.init(kind: kind, top: top, content: content, bottom: { EmptyView() })
    }
}

/// Makes a List's rows look like a grouped Form's cards. A Form builds every row up front, even thousands, so a page with
/// a long list can't be one.
enum PageCard {
    enum Position {
        case only, first, middle, last

        init(index: Int, count: Int) {
            self = count == 1 ? .only : index == 0 ? .first : index == count - 1 ? .last : .middle
        }

        var roundsTop: Bool { self == .only || self == .first }
        var roundsBottom: Bool { self == .only || self == .last }
    }

    /// The colour of a grouped Form's cards, in light and dark.
    static let fill = Color.primary.opacity(0.03)
    fileprivate static let separator = Color.primary.opacity(0.08)
    /// A List row is already this far in, and a card's rows sit 10 from its edge as a Form's do.
    fileprivate static let rowInset: CGFloat = -6
    fileprivate static let rowPadding: CGFloat = 10
}

extension View {
    /// One row of a card.
    func cardRow(_ position: PageCard.Position) -> some View {
        let radius = PageLayout.cardRadius
        let top = position.roundsTop ? radius : 0, bottom = position.roundsBottom ? radius : 0
        return listRowInsets(EdgeInsets(top: PageCard.rowPadding, leading: PageCard.rowInset, bottom: PageCard.rowPadding, trailing: PageCard.rowInset))
            .listRowBackground(UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
                .fill(PageCard.fill))
            .listRowSeparatorTint(PageCard.separator)
            .listRowSeparator(position.roundsTop ? .hidden : .visible, edges: .top)
            .listRowSeparator(position.roundsBottom ? .hidden : .visible, edges: .bottom)
    }

    /// A section header that floats: lined up with the cards, and solid, or the rows would show through it as they pass.
    func cardHeader() -> some View {
        padding(.horizontal, PageCard.rowInset)
            .padding(.vertical, PageCard.rowPadding / 2)
            .background(.background)
    }

    /// A row outside the cards, for what a Form has as a section's header and footer.
    func cardCaption() -> some View {
        listRowInsets(EdgeInsets(top: PageCard.rowPadding / 2, leading: PageCard.rowInset, bottom: PageCard.rowPadding / 2, trailing: PageCard.rowInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// How wide Coverage's columns are. The grid's height doesn't matter here: it scrolls.
struct CoverageLayout: Equatable {
    /// What a column has when there are too many to share the width.
    static let fixedColumn: CGFloat = 156
    /// Any narrower and "Preview Needed" doesn't fit, so sharing stops.
    static let minColumn: CGFloat = 140
    /// Past this a checkbox and its word only drift from the set they belong to.
    static let maxColumn: CGFloat = 260
    static let minName: CGFloat = 220
    static let maxName: CGFloat = 340

    var name: CGFloat
    var column: CGFloat
    /// The width of the grid, which row lines span. More than what's available when the columns don't fit, and the grid
    /// then scrolls sideways.
    var width: CGFloat

    init(available: CGFloat, columns: Int) {
        let count = CGFloat(max(columns, 1))
        let shared = (available - Self.minName) / count
        guard shared >= Self.minColumn else {
            name = Self.minName
            column = Self.fixedColumn
            width = max(available, name + count * column)
            return
        }
        column = min(shared, Self.maxColumn)
        name = min(max(available - count * column, Self.minName), Self.maxName)
        width = available
    }
}
