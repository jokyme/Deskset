import AppKit
import DesksetCore
import SwiftUI

/// Sidebar sections in Deskset's redesigned Widget Library (`ManageWindowController`), aligned with Deskset Pro (Image 4).
enum WidgetLibrarySection: String, CaseIterable, Identifiable {
    case installed
    case active
    case favorites
    case layouts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed: return L("Installed")
        case .active: return L("Loaded Skins")
        case .favorites: return L("Favorites")
        case .layouts: return L("Layouts")
        }
    }

    var symbol: String {
        switch self {
        case .installed: return "square.and.arrow.down.on.square.fill"
        case .active: return "checkmark.circle.fill"
        case .favorites: return "star.fill"
        case .layouts: return "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .installed: return Color.accentColor
        case .active: return DeskProPalette.loadedGreen
        case .favorites: return DeskProPalette.favoriteAmber
        case .layouts: return DeskProPalette.suitePurple
        }
    }
}

/// Observable state bridging `ManageWindowController` and `WidgetLibraryRootView`.
final class WidgetLibraryViewModel: ObservableObject {
    struct CardItem: Identifiable {
        let id: String // lowercased config name
        let config: SkinConfig
        let rootFolder: String
        let chosenFile: String
        let activeFile: String?
        let isHiddenByBang: Bool
        let startHidden: Bool
        let displayTitle: String
        let subtitle: String
        let author: String
        let version: String
        let isFavorite: Bool
        let hasAnyFavorite: Bool
        let isBuiltInSuite: Bool
    }

    @Published var section: WidgetLibrarySection = .installed
    @Published var selectedFolder: String? = nil // nil == All
    @Published var searchQuery: String = ""
    @Published var selectedConfigKey: String? = nil
    @Published var chosenVariants: [String: String] = [:]
    @Published var inspectorConfig: String? = nil
    @Published var scrollToCardID: String? = nil
    @Published var scrollRevision: Int = 0

    // Data snapshots updated from `ManageWindowController.reload()`
    @Published var cards: [CardItem] = []
    @Published var rootFolders: [(name: String, count: Int)] = []
    @Published var installedCount: Int = 0
    @Published var activeCount: Int = 0
    @Published var favoritesCount: Int = 0
    @Published var layoutNames: [String] = []
    @Published var selectedLayoutName: String? = nil
    @Published var layoutDraftName: String = ""
    @Published var saveEmptyLayout: Bool = false
    @Published var excludeUnloaded: Bool = false
    @Published var includeWallpaper: Bool = false
    @Published var isLoadingLayout: Bool = false
    @Published var layoutsErrorText: String = ""
    @Published var revision: Int = 0

    let thumbnails = SkinThumbnailCache()

    /// Switches top-level library section and clears any folder filter from the previous section so
    /// switching e.g. from `Installed · SomeFolder` to `Loaded Skins` never hides loaded widgets in other folders.
    func switchSection(_ newSection: WidgetLibrarySection) {
        section = newSection
        selectedFolder = nil
        scrollToCardID = nil
        if newSection == .favorites {
            chosenVariants.removeAll()
        }
    }

    func matchesSection(_ card: CardItem, section: WidgetLibrarySection? = nil) -> Bool {
        switch section ?? self.section {
        case .installed:
            return true
        case .active:
            return card.activeFile != nil
        case .favorites:
            return card.hasAnyFavorite
        case .layouts:
            return false
        }
    }

    func folderCount(_ folder: String?) -> Int {
        let base = cards.filter { matchesSection($0) }
        guard let folder else { return base.count }
        return base.filter { $0.rootFolder.caseInsensitiveCompare(folder) == .orderedSame }.count
    }

    var visibleRootFolders: [(name: String, count: Int)] {
        switch section {
        case .installed:
            return rootFolders.map { ($0.name, folderCount($0.name)) }
        case .active, .favorites:
            return rootFolders.compactMap { entry in
                let count = folderCount(entry.name)
                return count > 0 ? (entry.name, count) : nil
            }
        case .layouts:
            return []
        }
    }

    var filteredCards: [CardItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            guard matchesSection(card) else { return false }
            if let folder = selectedFolder,
               card.rootFolder.caseInsensitiveCompare(folder) != .orderedSame {
                return false
            }
            guard !query.isEmpty else { return true }
            let fields = [
                card.displayTitle,
                card.subtitle,
                card.author,
                card.config.name,
                card.chosenFile,
                card.rootFolder,
            ]
            return fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Windowed Widget Library view aligned with Deskset Pro (Image 4):
/// left sidebar (`组件库` header, `已安装 / 已加载的皮肤 / 收藏 / 布局`, folder categories, bottom `安装皮肤…`),
/// top toolbar with search (`⌘K`) and quick actions, and a 2-column live-preview card grid.
struct WidgetLibraryRootView: View {
    @ObservedObject var model: WidgetLibraryViewModel
    @ObservedObject var thumbnails: SkinThumbnailCache
    weak var controller: ManageWindowController?
    let app: AppController

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var installButtonHovered = false

    init(model: WidgetLibraryViewModel, controller: ManageWindowController, app: AppController) {
        self.model = model
        self.thumbnails = model.thumbnails
        self.controller = controller
        self.app = app
    }

    private var isDark: Bool { colorScheme == .dark }
    private var trimmedQuery: String { model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredCards: [WidgetLibraryViewModel.CardItem] {
        model.filteredCards
    }

    private func folderCount(_ folder: String?) -> Int {
        model.folderCount(folder)
    }

    private func sectionCount(_ section: WidgetLibrarySection) -> Int {
        switch section {
        case .installed: return model.installedCount
        case .active: return model.activeCount
        case .favorites: return model.favoritesCount
        case .layouts: return model.layoutNames.count
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .sheet(isPresented: Binding(
            get: { model.inspectorConfig != nil },
            set: { if !$0 { model.inspectorConfig = nil } }
        )) {
            if let configName = model.inspectorConfig,
               let controller {
                SkinInspectorSheetView(
                    configName: configName,
                    model: model,
                    controller: controller,
                    app: app,
                    onClose: { model.inspectorConfig = nil }
                )
            }
        }
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DeskAppMark(size: 18)
                Text(L("Widget Library"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 12)
            .background(WindowDragArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        sidebarSectionHeader(L("Library"))
                        ForEach(WidgetLibrarySection.allCases) { sec in
                            sidebarNavRow(
                                title: sec.title,
                                symbol: sec.symbol,
                                tint: sec.tint,
                                count: sectionCount(sec),
                                selected: model.section == sec
                            ) {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    if sec == .layouts {
                                        controller?.selectTab(.layouts)
                                    } else {
                                        if model.section == .layouts {
                                            controller?.selectTab(.skins)
                                        }
                                        model.switchSection(sec)
                                        controller?.reload()
                                    }
                                }
                            }
                        }
                    }

                    if model.section != .layouts {
                        Divider().padding(.horizontal, 12)

                        VStack(alignment: .leading, spacing: 3) {
                            sidebarSectionHeader(L("Folders"))
                            sidebarFolderRow(
                                title: L("All"),
                                symbol: "square.grid.2x2",
                                count: folderCount(nil),
                                selected: model.selectedFolder == nil
                            ) {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    model.selectedFolder = nil
                                }
                            }

                            ForEach(model.visibleRootFolders, id: \.name) { folder in
                                sidebarFolderRow(
                                    title: folder.name,
                                    symbol: folder.name.caseInsensitiveCompare("Stationery") == .orderedSame
                                        ? "sparkles"
                                        : "folder",
                                    count: folder.count,
                                    selected: model.selectedFolder?.caseInsensitiveCompare(folder.name) == .orderedSame
                                ) {
                                    withAnimation(.easeOut(duration: 0.14)) {
                                        model.selectedFolder = folder.name
                                    }
                                }
                                .contextMenu {
                                    Button(L("Create new skin")) {
                                        NewSkinWindowController.show(
                                            app: app,
                                            initialDirectory: SkinLibrary.directory(for: folder.name, root: app.skinsDirectory)
                                        )
                                    }
                                    Button(L("Show in Finder")) {
                                        Workspace.reveal(SkinLibrary.directory(for: folder.name, root: app.skinsDirectory))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }

            Divider()

            VStack(spacing: 8) {
                Button {
                    app.installSkinAction()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("Install Skin…"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(installButtonHovered ? 0.10 : 0))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                            )
                    )
                    .shadow(color: Color.accentColor.opacity(isDark ? 0.36 : 0.24), radius: 6, y: 2)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { installButtonHovered = $0 }
            }
            .padding(12)
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(DeskProPalette.librarySidebar)
    }

    private func sidebarSectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }

    private func sidebarNavRow(
        title: String,
        symbol: String,
        tint: Color,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(selected ? .white : tint)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? tint : tint.opacity(0.14))
                    )
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: selected ? .medium : .regular).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarFolderRow(
        title: String,
        symbol: String,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : Color.primary.opacity(0.82))
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(.secondary.opacity(0.75))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content Area

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            topToolbar
            Divider()
            if model.section == .layouts {
                layoutsContent
            } else {
                cardsGridContent
            }
            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbarSubtitle: String {
        if model.section == .layouts {
            return L("Save and restore desktop skin arrangements")
        }
        return L("%lld widgets available · Click Add to Desktop or adjust settings", filteredCards.count)
    }

    private var topToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.section.title)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    if model.section != .layouts, let folder = model.selectedFolder {
                        Text("· \(folder)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(toolbarSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            toolbarIconButton(symbol: "folder.badge.plus", help: L("Create new skin")) {
                controller?.performCreateNewSkin()
            }
            toolbarIconButton(symbol: "shippingbox", help: L("Create .rmskin Package…")) {
                controller?.createPackage()
            }
            toolbarIconButton(symbol: "arrow.clockwise", help: L("Refresh All")) {
                model.thumbnails.invalidateAll()
                app.refreshAllAction()
            }
            toolbarIconButton(symbol: "folder", help: L("Open Skins Folder")) {
                app.openSkinsFolderAction()
            }

            if model.section != .layouts {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField(L("Search widgets"), text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($searchFocused)
                    if model.searchQuery.isEmpty {
                        Text("⌘K")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    } else {
                        Button {
                            model.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(width: 200, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(WindowDragArea())
    }

    private func toolbarIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol: symbol, help: help, action: action)
    }

    // MARK: - Cards Grid

    private var cardsGridContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let items = filteredCards
                if items.isEmpty {
                    let emptySymbol: String = {
                        if !trimmedQuery.isEmpty { return "magnifyingglass" }
                        switch model.section {
                        case .active: return "checkmark.circle"
                        case .favorites: return "star"
                        case .installed, .layouts: return "square.grid.2x2"
                        }
                    }()
                    let emptyText: String = {
                        if !trimmedQuery.isEmpty { return L("No matching widgets") }
                        switch model.section {
                        case .active: return L("No skins loaded")
                        case .favorites: return L("No favorite skins")
                        case .installed, .layouts: return L("No skins installed")
                        }
                    }()
                    VStack(spacing: 10) {
                        Image(systemName: emptySymbol)
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.45))
                        Text(emptyText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 96)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 296, maximum: 520), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(items) { card in
                            skinCard(card)
                                .id(card.id)
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                if let target = model.scrollToCardID {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: model.scrollRevision) { _ in
                if let target = model.scrollToCardID {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private func skinCard(_ card: WidgetLibraryViewModel.CardItem) -> some View {
        let isSelected = model.selectedConfigKey == card.id
        let isExactLoaded = card.activeFile?.caseInsensitiveCompare(card.chosenFile) == .orderedSame
        let thumb = thumbnails.thumbnail(
            config: card.config.name,
            file: card.chosenFile,
            isDark: isDark,
            app: app
        )

        return VStack(alignment: .leading, spacing: 12) {
            // Preview Stage
            GeometryReader { geo in
                let availW = max(160, geo.size.width - 20)
                let availH = max(110, geo.size.height - 20)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isDark
                                    ? [DeskProPalette.hex(0x1A202E), DeskProPalette.hex(0x231D2D)]
                                    : [DeskProPalette.hex(0xEDF2FA), DeskProPalette.hex(0xF5EFEA)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(isDark ? 0.09 : 0.05), lineWidth: 0.5)
                        )

                    if let thumb {
                        let scale = min(1.0, min(availW / max(1, thumb.pointSize.width), availH / max(1, thumb.pointSize.height)))
                        Image(nsImage: thumb.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: thumb.pointSize.width * scale, height: thumb.pointSize.height * scale)
                            .shadow(color: .black.opacity(isDark ? 0.34 : 0.14), radius: 10, y: 4)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: card.activeFile != nil ? "checkmark.rectangle.stack.fill" : "square.grid.2x2")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(card.activeFile != nil ? Color.accentColor : .secondary.opacity(0.6))
                            Text(card.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(12)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isExactLoaded {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(card.isHiddenByBang ? Color.orange : DeskProPalette.loadedGreen)
                                .frame(width: 6, height: 6)
                            Text(card.isHiddenByBang ? L("Loaded, hidden") : L("Loaded"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(card.isHiddenByBang ? .orange : DeskProPalette.loadedGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                        )
                        .padding(8)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    controller?.selectInLibrary(config: card.config.name, file: card.chosenFile)
                    controller?.testToggleLoad(config: card.config.name, file: card.chosenFile)
                }
                .onTapGesture(count: 1) {
                    controller?.selectInLibrary(config: card.config.name, file: card.chosenFile)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 176)

            // Title, Badges & Description
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if card.isBuiltInSuite {
                        tagPill(L("Built-in"), tint: DeskProPalette.discoverBlue)
                    }
                    Spacer(minLength: 4)
                    Text(card.author.isEmpty ? card.rootFolder : "\(card.rootFolder) · \(card.author)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                }
                Text(card.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)
            }

            // Bottom Variant Selector + Quick Icons + Load/Unload Button
            HStack(spacing: 8) {
                variantPicker(for: card)

                Spacer(minLength: 4)

                cardIconButton(
                    symbol: card.isFavorite ? "star.fill" : "star",
                    tint: card.isFavorite ? DeskProPalette.favoriteAmber : .secondary,
                    help: L("Favorite")
                ) {
                    app.setLibraryFavorite(!card.isFavorite, config: card.config.name, file: card.chosenFile)
                }

                cardIconButton(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    tint: .secondary,
                    help: L("Edit")
                ) {
                    let url = card.config.directory.appendingPathComponent(card.chosenFile)
                    CodeEditorRouter.open(file: url, app: app)
                }

                cardIconButton(
                    symbol: "slider.horizontal.3",
                    tint: .secondary,
                    help: L("Settings")
                ) {
                    controller?.selectInLibrary(config: card.config.name, file: card.chosenFile)
                    model.inspectorConfig = card.config.name
                }

                if isExactLoaded && card.isHiddenByBang {
                    Button {
                        controller?.selectInLibrary(config: card.config.name, file: card.chosenFile)
                        controller?.testShowButton.performClick(nil)
                    } label: {
                        Text(ManageModel.Hidden.showTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isExactLoaded {
                    Button {
                        controller?.testToggleLoad(config: card.config.name, file: card.chosenFile)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(L("Unload"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.primary.opacity(0.84))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        controller?.testToggleLoad(config: card.config.name, file: card.chosenFile)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(L("Add to Desktop"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isDark ? 0.16 : 0.025), radius: 6, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(isDark ? 0.09 : 0.055),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        )
        .contextMenu {
            Button(isExactLoaded ? L("Unload") : L("Load")) {
                controller?.testToggleLoad(config: card.config.name, file: card.chosenFile)
            }
            if isExactLoaded && card.isHiddenByBang {
                Button(ManageModel.Hidden.showTitle) {
                    controller?.testContextShow(config: card.config.name)
                }
            }
            Button(L("Settings")) {
                controller?.selectInLibrary(config: card.config.name, file: card.chosenFile)
                model.inspectorConfig = card.config.name
            }
            Button(L("Edit")) {
                let url = card.config.directory.appendingPathComponent(card.chosenFile)
                CodeEditorRouter.open(file: url, app: app)
            }
            Divider()
            Button(L("Show in Finder")) {
                Workspace.reveal(card.config.directory)
            }
        }
    }

    @ViewBuilder
    private func variantPicker(for card: WidgetLibraryViewModel.CardItem) -> some View {
        let files = card.config.files
        if files.count == 1, VariantSizeGlyph.Kind(fileName: files[0]) == nil {
            Text(files[0])
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .help(files[0])
        } else if files.count <= 3 {
            HStack(spacing: 2) {
                ForEach(files, id: \.self) { file in
                    let active = file.caseInsensitiveCompare(card.chosenFile) == .orderedSame
                    let sizeKind = VariantSizeGlyph.Kind(fileName: file)
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            model.chosenVariants[card.id] = file
                            controller?.selectInLibrary(config: card.config.name, file: file)
                        }
                    } label: {
                        Group {
                            if let sizeKind {
                                VariantSizeGlyph(
                                    kind: sizeKind,
                                    color: active ? .white : Color.primary.opacity(0.72)
                                )
                                .frame(width: 30, height: 24)
                            } else {
                                Text((file as NSString).deletingPathExtension)
                                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                                    .foregroundColor(active ? .white : Color.primary.opacity(0.78))
                                    .lineLimit(1)
                                    .frame(maxWidth: 74)
                                    .padding(.horizontal, 7)
                                    .frame(height: 24)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        } else {
            Menu {
                ForEach(files, id: \.self) { file in
                    Button {
                        model.chosenVariants[card.id] = file
                        controller?.selectInLibrary(config: card.config.name, file: file)
                    } label: {
                        if file.caseInsensitiveCompare(card.chosenFile) == .orderedSame {
                            Label(file, systemImage: "checkmark")
                        } else {
                            Text(file)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((card.chosenFile as NSString).deletingPathExtension)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 96)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .foregroundColor(.primary.opacity(0.82))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func cardIconButton(symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        CardIconButton(symbol: symbol, tint: tint, help: help, action: action)
    }

    private func tagPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.13)))
    }

    // MARK: - Layouts Content

    private var layoutsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DeskProSettingsGroup(title: L("Save new layout")) {
                    DeskProSettingsRow(title: L("Name:")) {
                        HStack(spacing: 8) {
                            TextField(
                                L("Layout name"),
                                text: Binding(
                                    get: { model.layoutDraftName },
                                    set: { controller?.testTypeLayoutName($0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .disabled(model.isLoadingLayout)

                            Button(L("Save")) {
                                controller?.testSaveLayoutButton.performClick(nil)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!(controller?.testSaveLayoutButton.isEnabled ?? false))
                        }
                    }
                    DeskProSettingsRow(title: L("Save as empty layout")) {
                        Toggle("", isOn: Binding(
                            get: { model.saveEmptyLayout },
                            set: { _ in controller?.testEmptyLayoutBox.performClick(nil) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(model.isLoadingLayout)
                    }
                    DeskProSettingsRow(title: L("Exclude unloaded skins")) {
                        Toggle("", isOn: Binding(
                            get: { model.excludeUnloaded },
                            set: { _ in controller?.testExcludeUnloadedBox.performClick(nil) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(model.isLoadingLayout || model.saveEmptyLayout)
                    }
                    DeskProSettingsRow(title: L("Include current wallpaper"), divider: false) {
                        Toggle("", isOn: Binding(
                            get: { model.includeWallpaper },
                            set: { _ in controller?.testIncludeWallpaperBox.performClick(nil) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(model.isLoadingLayout || model.saveEmptyLayout)
                    }
                }

                DeskProSettingsGroup(title: L("Saved layouts")) {
                    if model.layoutNames.isEmpty {
                        DeskProSettingsRow(
                            title: model.layoutsErrorText.isEmpty ? L("No saved layouts.") : model.layoutsErrorText,
                            divider: false
                        ) {
                            EmptyView()
                        }
                    } else {
                        ForEach(Array(model.layoutNames.enumerated()), id: \.element) { idx, name in
                            let isSelected = model.selectedLayoutName?.caseInsensitiveCompare(name) == .orderedSame
                            DeskProSettingsRow(
                                title: name,
                                symbol: name.caseInsensitiveCompare("@Backup") == .orderedSame
                                    ? "clock.arrow.circlepath"
                                    : "rectangle.3.group",
                                symbolTint: isSelected ? Color.accentColor : .secondary,
                                divider: idx < model.layoutNames.count - 1
                            ) {
                                HStack(spacing: 8) {
                                    Button(L("Load")) {
                                        controller?.testSelectLayout(name)
                                        controller?.testLoadLayoutButton.performClick(nil)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.isLoadingLayout)

                                    Button(L("Edit")) {
                                        controller?.testSelectLayout(name)
                                        controller?.testEditLayoutButton.performClick(nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(model.isLoadingLayout)

                                    Button(L("Delete")) {
                                        controller?.testSelectLayout(name)
                                        controller?.testDeleteLayoutButton.performClick(nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(model.isLoadingLayout)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                controller?.testSelectLayout(name)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(DeskProPalette.page)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Label(
                L("Click Add to Desktop to load a widget, or drop a .rmskin, .zip or skin folder here to install."),
                systemImage: "sparkles"
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Header toolbar icon button that highlights on hover and immediately presents its tooltip with zero delay.
private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button {
            DeskProInstantToolTip.shared.hide()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(hovered ? 0.96 : 0.82))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.11 : 0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            DeskProInstantToolTipAnchor(text: help) { isHovering in
                hovered = isHovering
            }
        )
        .accessibilityLabel(help)
    }
}

/// Card quick-action icon button (`Favorite`, `Edit`, `Settings`) that highlights on hover and presents its tooltip immediately.
private struct CardIconButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button {
            DeskProInstantToolTip.shared.hide()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(hovered && tint == .secondary ? .primary.opacity(0.88) : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.11 : 0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            DeskProInstantToolTipAnchor(text: help) { isHovering in
                hovered = isHovering
            }
        )
        .accessibilityLabel(help)
    }
}

/// Size glyphs matching Deskset Pro's `WidgetSizeGlyph` (`Small`, `Medium`, `Large`).
private struct VariantSizeGlyph: View {
    enum Kind {
        case small, medium, large

        init?(fileName: String) {
            let base = (fileName as NSString).deletingPathExtension.lowercased()
            switch base {
            case "small": self = .small
            case "medium", "middle": self = .medium
            case "large": self = .large
            default: return nil
            }
        }
    }

    let kind: Kind
    let color: Color

    var body: some View {
        switch kind {
        case .small:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4)
                .frame(width: 11, height: 11)
        case .medium:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4)
                .frame(width: 17, height: 11)
        case .large:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4)
                .frame(width: 15, height: 14)
        }
    }
}

// MARK: - Per-Skin Inspector Sheet (Full Rainmeter Skin Settings, Metadata & Compatibility)

private struct SkinInspectorSheetView: View {
    let configName: String
    @ObservedObject var model: WidgetLibraryViewModel
    let controller: ManageWindowController
    let app: AppController
    let onClose: () -> Void

    @State private var xText: String = ""
    @State private var yText: String = ""
    @State private var fadeText: String = ""
    @State private var loadOrderText: String = ""
    @State private var zoomValue: Int = 100

    private var config: SkinConfig? { app.config(named: configName) }
    private var chosenFile: String {
        model.chosenVariants[configName.lowercased()]
            ?? app.controller(for: configName)?.file
            ?? config?.files.first
            ?? ""
    }
    private var running: SkinWindowController? { app.controller(for: configName) }
    private var isExactLoaded: Bool {
        running.map { $0.file.caseInsensitiveCompare(chosenFile) == .orderedSame } ?? false
    }
    private var skinState: SkinState {
        running?.state ?? app.state.skin(configName) ?? SkinState(file: chosenFile)
    }

    var body: some View {
        let _ = model.revision
        let editable = running != nil && !chosenFile.isEmpty
        let fileURL = config?.directory.appendingPathComponent(chosenFile)
        let metadata: [String: String] = {
            if isExactLoaded, let running { return running.runtime.snapshot.metadata }
            if let fileURL { return ManageModel.readMetadata(fileURL) }
            return [:]
        }()
        let issues: [String] = {
            if isExactLoaded, let running { return running.runtime.snapshot.issues }
            if let config, let fileURL {
                return ManageModel.dryRunIssues(config: config.name, fileURL: fileURL, skinsDirectory: app.skinsDirectory)
            }
            return []
        }()

        VStack(spacing: 0) {
            // Sheet Header
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(ManageModel.metadataValue(metadata, "Name") ?? ((chosenFile as NSString).deletingPathExtension))
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text("\(configName)\\\(chosenFile)")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isExactLoaded {
                    Button(L("Refresh")) {
                        if let running { app.refresh(running) }
                    }
                    .controlSize(.small)
                }

                Button {
                    controller.testToggleLoad(config: configName, file: chosenFile)
                    syncFields()
                } label: {
                    Text(isExactLoaded ? L("Unload") : L("Load"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isExactLoaded, let running, !running.isStopped, running.isHiddenByBang {
                        DeskProSettingsGroup {
                            DeskProSettingsRow(
                                title: ManageModel.Hidden.title,
                                detail: ManageModel.Hidden.explanation(startHidden: running.state.startHidden),
                                symbol: "eye.slash.fill",
                                symbolTint: .orange,
                                divider: false
                            ) {
                                Button(ManageModel.Hidden.showTitle) {
                                    controller.selectInLibrary(config: configName, file: chosenFile)
                                    controller.testShowButton.performClick(nil)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }

                    // Window & Display Settings
                    DeskProSettingsGroup(
                        title: L("Settings"),
                        footer: editable ? nil : L("Load the skin to change its settings.")
                    ) {
                        DeskProSettingsRow(title: L("Position:")) {
                            Picker("", selection: Binding(
                                get: { skinState.alwaysOnTop },
                                set: { val in
                                    guard let running else { return }
                                    app.changeSettings(of: running) { $0.alwaysOnTop = val }
                                }
                            )) {
                                ForEach(ManageModel.positions, id: \.value) { pos in
                                    Text(pos.title).tag(pos.value)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Transparency:")) {
                            Picker("", selection: Binding(
                                get: { ManageModel.transparencyChoiceIndex(forAlpha: skinState.alphaValue) ?? 0 },
                                set: { idx in
                                    guard let running, ManageModel.transparencyChoices.indices.contains(idx) else { return }
                                    let alpha = ManageModel.transparencyChoices[idx].alpha
                                    running.clearFadedAlpha()
                                    app.changeSettings(of: running) { $0.alphaValue = alpha }
                                }
                            )) {
                                ForEach(Array(ManageModel.transparencyChoices.enumerated()), id: \.offset) { idx, choice in
                                    Text(choice.title).tag(idx)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("On hover:")) {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { skinState.onHover },
                                    set: { val in
                                        guard let running else { return }
                                        app.changeSettings(of: running) { $0.onHover = val }
                                    }
                                )) {
                                    ForEach(SkinVisibility.HoverMode.allCases, id: \.rawValue) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)

                                TextField("", text: $fadeText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        guard let running, let v = Int(fadeText.trimmingCharacters(in: .whitespaces)) else { return }
                                        app.changeSettings(of: running) {
                                            $0.fadeDuration = min(max(v, 0), SkinState.maxFadeDuration)
                                        }
                                    }
                                Text(L("ms"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Coordinates:")) {
                            HStack(spacing: 6) {
                                Text("X").font(.system(size: 11)).foregroundColor(.secondary)
                                TextField("0", text: $xText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit(commitCoordinates)
                                Text("Y").font(.system(size: 11)).foregroundColor(.secondary)
                                TextField("0", text: $yText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit(commitCoordinates)
                            }
                            .disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Zoom:")) {
                            HStack(spacing: 6) {
                                Stepper(value: Binding(
                                    get: { zoomValue },
                                    set: { newVal in
                                        let clamped = min(max(newVal, 10), 500)
                                        zoomValue = clamped
                                        app.setSkinZoom(config: configName, percent: clamped)
                                    }
                                ), in: 10...500, step: 10) {
                                    Text("\(zoomValue)%")
                                        .font(.system(size: 12.5).monospacedDigit())
                                }
                            }
                            .disabled(!editable || app.state.forceDefaultZoom)
                        }

                        DeskProSettingsRow(title: L("Draggable")) {
                            Toggle("", isOn: Binding(
                                get: { skinState.draggable },
                                set: { v in if let running { app.changeSettings(of: running) { $0.draggable = v } } }
                            ))
                            .toggleStyle(.switch).labelsHidden().disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Click through")) {
                            Toggle("", isOn: Binding(
                                get: { skinState.clickThrough },
                                set: { v in if let running { app.changeSettings(of: running) { $0.clickThrough = v } } }
                            ))
                            .toggleStyle(.switch).labelsHidden().disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Keep on screen")) {
                            Toggle("", isOn: Binding(
                                get: { skinState.keepOnScreen },
                                set: { v in if let running { app.changeSettings(of: running) { $0.keepOnScreen = v } } }
                            ))
                            .toggleStyle(.switch).labelsHidden().disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Snap to edges")) {
                            Toggle("", isOn: Binding(
                                get: { skinState.snapEdges },
                                set: { v in if let running { app.changeSettings(of: running) { $0.snapEdges = v } } }
                            ))
                            .toggleStyle(.switch).labelsHidden().disabled(!editable)
                        }

                        DeskProSettingsRow(title: L("Save position"), divider: false) {
                            Toggle("", isOn: Binding(
                                get: { skinState.savePosition },
                                set: { v in if let running { app.changeSettings(of: running) { $0.savePosition = v } } }
                            ))
                            .toggleStyle(.switch).labelsHidden().disabled(!editable)
                        }
                    }

                    // Metadata
                    let metaRows: [(String, String)] = [
                        ("author", L("Author:")),
                        ("version", L("Version:")),
                        ("license", L("License:")),
                        ("information", L("Information:")),
                    ].compactMap { key, label in
                        guard var val = ManageModel.metadataValue(metadata, key) else { return nil }
                        if key == "information" { val = ManageModel.informationText(val) }
                        return (label, val)
                    }

                    DeskProSettingsGroup(title: L("Metadata")) {
                        if metaRows.isEmpty {
                            let hasSection = fileURL.flatMap(ManageModel.hasMetadataSection)
                            DeskProSettingsRow(
                                title: hasSection == false
                                    ? L("This skin has no [Metadata] section.")
                                    : L("This skin has no metadata values."),
                                divider: false
                            ) {
                                if hasSection == false, let fileURL {
                                    Button(L("Add metadata")) {
                                        _ = try? MetadataEditing.addIfMissing(to: fileURL, app: app)
                                        controller.reload()
                                    }
                                    .controlSize(.small)
                                }
                            }
                        } else {
                            ForEach(Array(metaRows.enumerated()), id: \.offset) { idx, item in
                                DeskProSettingsRow(
                                    title: item.0,
                                    detail: item.1,
                                    divider: idx < metaRows.count - 1
                                ) {
                                    EmptyView()
                                }
                            }
                        }
                    }

                    // Compatibility
                    DeskProSettingsGroup(title: L("Compatibility")) {
                        if issues.isEmpty {
                            DeskProSettingsRow(
                                title: L("No compatibility problems found."),
                                symbol: "checkmark.circle.fill",
                                symbolTint: DeskProPalette.loadedGreen,
                                divider: false
                            ) {
                                EmptyView()
                            }
                        } else {
                            ForEach(Array(issues.prefix(30).enumerated()), id: \.offset) { idx, issue in
                                DeskProSettingsRow(
                                    title: issue,
                                    symbol: "exclamationmark.triangle.fill",
                                    symbolTint: .orange,
                                    divider: idx < min(issues.count, 30) - 1
                                ) {
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
            .background(DeskProPalette.page)
        }
        .frame(width: 560, height: 600)
        .onAppear(perform: syncFields)
    }

    private func syncFields() {
        let s = skinState
        if let running {
            let p = running.topLeftPosition
            xText = String(Int(p.x.rounded()))
            yText = String(Int(p.y.rounded()))
            zoomValue = Int((running.effectiveZoomFactor * 100).rounded())
        } else {
            xText = s.x.map { String(Int($0.rounded())) } ?? ""
            yText = s.y.map { String(Int($0.rounded())) } ?? ""
            zoomValue = app.state.forceDefaultZoom
                ? app.state.defaultZoomPercent
                : (s.zoomOverridePercent ?? app.state.defaultZoomPercent)
        }
        fadeText = String(s.fadeDuration)
        loadOrderText = String(s.loadOrder)
    }

    private func commitCoordinates() {
        guard let x = Int(xText.trimmingCharacters(in: .whitespaces)),
              let y = Int(yText.trimmingCharacters(in: .whitespaces)) else { return }
        controller.selectInLibrary(config: configName, file: chosenFile)
        controller.testTypeCoordinates(x: x, y: y)
    }
}
