//
//  BookMarkSlider.swift
//  Location Simulator
//
//  Lists used by the Places tab: Bookmarks (with lists/folders) and History.
//

import SwiftUI
import AlertKit
import UniformTypeIdentifiers
import CoreLocation

/// What the edit sheet is doing.
struct PlaceEdit: Identifiable {
    enum Mode { case edit, newBookmark }
    let id = UUID()
    var mode: Mode
    var list: LocList          // list being edited (edit mode)
    var item: Bookmark
}

enum BookmarkViewMode: String { case all, folders }

struct LocationListView: View {
    let list: LocList
    var onStart: (Bookmark) -> Void
    var onShowOnMap: (Bookmark) -> Void

    @State private var items: [Bookmark] = []
    @State private var folders: [String] = []
    @State private var favFolders: Set<String> = []
    @State private var search = ""
    @AppStorage("sort_history") private var sortHistory: String = BookmarkSort.newest.rawValue
    @AppStorage("sort_bookmarks") private var sortBookmarks: String = BookmarkSort.az.rawValue
    @AppStorage("bmViewMode") private var viewModeRaw: String = BookmarkViewMode.all.rawValue
    @AppStorage("collapsedFolders") private var collapsedRaw: String = ""
    @AppStorage("activeLoc") private var activeLoc: String = ""
    @State private var openFolder: String? = nil
    @State private var selected: Bookmark? = nil
    @State private var showMenu = false
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var editing: PlaceEdit? = nil
    @State private var folderEdit: FolderEdit? = nil
    @FocusState private var searchFocused: Bool

    private var sortRaw: Binding<String> { list == .history ? $sortHistory : $sortBookmarks }
    private var sort: BookmarkSort { BookmarkSort(rawValue: sortRaw.wrappedValue) ?? .az }
    private var viewMode: BookmarkViewMode { BookmarkViewMode(rawValue: viewModeRaw) ?? .all }
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var usesFolders: Bool { list == .bookmarks }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let folder = openFolder, usesFolders, !isSearching {
                folderHeader(folder)
            }
            List {
                content
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 36)
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                if searchFocused { searchFocused = false; hideKeyboard() }   // scrolling hides keyboard
            })
            .overlay(emptyState, alignment: .center)
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .locListChanged)) { note in
            if (note.object as? String) == list.rawValue { reload() }
        }
        .confirmationDialog(selected?.displayName ?? "", isPresented: $showMenu, titleVisibility: .visible) {
            if let item = selected {
                Button(L("Giả lập vị trí này", "Simulate this location")) { onStart(item); reload() }
                Button(L("Đặt vị trí này lên bản đồ", "Show on map")) { onShowOnMap(item) }
                Button(L("Sửa vị trí", "Edit location")) { openEdit(PlaceEdit(mode: .edit, list: list, item: item)) }
                if list == .bookmarks {
                    Button(item.favorite ? L("Bỏ khỏi Yêu thích", "Remove from Favourites") : L("Thêm vào Yêu thích", "Add to Favourites")) { setFavorite(id: item.id, !item.favorite) }
                }
                if list == .history {
                    Button(L("Thêm vào Đánh dấu", "Add to Bookmarks")) { openEdit(PlaceEdit(mode: .newBookmark, list: .bookmarks, item: item)) }
                }
                Button(L("Xoá", "Delete"), role: .destructive) { remove(item) }
                Button(L("Huỷ", "Cancel"), role: .cancel) {}
            }
        } message: {
            if let item = selected { Text(coordLine(item)) }
        }
        .sheet(item: $editing) { edit in
            PlaceEditView(edit: edit, folders: loadFolders(), defaultFolder: openFolder ?? "") { result in
                save(edit, result)
            }
        }
        .background(
            EmptyView().sheet(item: $folderEdit) { fe in
                FolderEditView(original: fe.original) { newName in
                    if openFolder != nil, openFolder == fe.original { openFolder = newName }
                    reload()
                }
            }
        )
        .sheet(isPresented: $showPaste) {
            PasteImportView(title: list.title) { text in importText(text) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        if isSearching || !usesFolders {
            // Flat list (search results or History)
            ForEach(filterAndSort(items, search: search, sort: sort)) { item in
                placeRow(item, indent: false, showFolder: usesFolders)
            }
        } else if let folder = openFolder {
            ForEach(sorted(items.filter { $0.folders.contains(folder) })) { item in
                placeRow(item, indent: false, showFolder: false)
            }
        } else {
            // ⭐ Favourites: always on top and always open
            let favs = sorted(items.filter { $0.favorite })
            if !favs.isEmpty {
                favouritesHeader(count: favs.count)
                ForEach(favs) { item in
                    placeRow(item, indent: true, showFolder: false)
                }
            }
            ForEach(folders, id: \.self) { folder in
                folderRow(folder)
                if viewMode == .all && !collapsed.contains(folder) {
                    ForEach(sorted(items.filter { $0.folders.contains(folder) })) { item in
                        placeRow(item, indent: true, showFolder: false)
                    }
                }
            }
            ForEach(sorted(items.filter { $0.folders.allSatisfy { !folders.contains($0) } })) { item in
                placeRow(item, indent: false, showFolder: false)
            }
        }
    }

    private func favouritesHeader(count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundColor(.yellow)
                .frame(width: 26)
            Text(L("Yêu thích", "Favourites"))
                .font(.body.weight(.semibold))
            Text("\(count)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }

    private func sorted(_ arr: [Bookmark]) -> [Bookmark] { filterAndSort(arr, search: "", sort: sort) }

    private func placeRow(_ item: Bookmark, indent: Bool, showFolder: Bool) -> some View {
        HStack(spacing: 12) {
            // Tap the icon = simulate this place right away
            Button {
                searchFocused = false
                hideKeyboard()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStart(item)
                reload()
            } label: {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 20, weight: isActive(item) ? .semibold : .light))
                    .foregroundColor(isActive(item) ? .red : .secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Name: tap does nothing, press and hold opens the menu
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((usesFolders && item.favorite ? "⭐ " : "") + item.displayName)
                        .font(.body)
                        .foregroundColor(item.isUnnamed ? .secondary : .primary)
                        .lineLimit(2)
                    Text(subtitle(item, showFolder: showFolder))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                    if list == .history, item.date > 0 {
                        Text(dateText(item.date))
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35) {
                searchFocused = false
                hideKeyboard()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selected = item
                showMenu = true
            }
        }
        .padding(.leading, indent ? 22 : 0)
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(item) } label: { Label(L("Xoá", "Delete"), systemImage: "trash") }
            Button { openEdit(PlaceEdit(mode: .edit, list: list, item: item)) } label: { Label(L("Sửa", "Edit"), systemImage: "pencil") }
                .tint(.orange)
            if usesFolders {
                Button { setFavorite(id: item.id, !item.favorite) } label: {
                    Label(item.favorite ? L("Bỏ thích", "Unfavourite") : L("Yêu thích", "Favourites"), systemImage: item.favorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
        }
    }

    /// The place currently being simulated (within 5 m).
    private func isActive(_ item: Bookmark) -> Bool {
        let p = activeLoc.split(separator: ",").compactMap { Double($0) }
        guard p.count == 2 else { return false }
        return CLLocation(latitude: p[0], longitude: p[1]).distance(from: CLLocation(latitude: item.lat, longitude: item.long)) <= 5
    }

    private func coordLine(_ item: Bookmark) -> String {
        L("Kinh độ:\(fmt(item.long))  Vĩ độ:\(fmt(item.lat))", "Longitude:\(fmt(item.long))  Latitude:\(fmt(item.lat))")
    }

    private func subtitle(_ item: Bookmark, showFolder: Bool) -> String {
        var s = coordLine(item)
        if showFolder, !item.folders.isEmpty { s = "📁 \(item.folders.joined(separator: ", "))  ·  " + s }
        return s
    }

    /// Up to 7 decimals, trailing zeros removed (like LocSim).
    private func fmt(_ v: Double) -> String {
        var t = String(format: "%.7f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private func dateText(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = appIsVietnamese ? "HH:mm 'ngày' dd/MM/yyyy" : "HH:mm, dd/MM/yyyy"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func folderRow(_ folder: String) -> some View {
        let count = items.filter { $0.folders.contains(folder) }.count
        let isOpen = !collapsed.contains(folder)
        return Button {
            if viewMode == .all { toggle(folder) } else { openFolder = folder }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: favFolders.contains(folder) ? "star.square.on.square.fill" : "folder.fill")
                    .font(.system(size: 18))
                    .foregroundColor(favFolders.contains(folder) ? .yellow : .accentColor)
                    .frame(width: 26)
                Text(folder)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                Image(systemName: viewMode == .all ? (isOpen ? "chevron.down" : "chevron.right") : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { askDeleteFolder(folder) } label: { Label(L("Xoá", "Delete"), systemImage: "trash") }
            Button { askRenameFolder(folder) } label: { Label(L("Sửa", "Edit"), systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            Button { setFavouriteFolder(folder, !favFolders.contains(folder)); reload() } label: {
                Label(favFolders.contains(folder) ? L("Bỏ khỏi Yêu thích", "Remove from Favourites") : L("Thêm vào Yêu thích", "Add to Favourites"),
                      systemImage: favFolders.contains(folder) ? "star.slash" : "star")
            }
            Button { askRenameFolder(folder) } label: { Label(L("Sửa danh sách", "Edit list"), systemImage: "pencil") }
            Button(role: .destructive) { askDeleteFolder(folder) } label: { Label(L("Xoá danh sách", "Delete list"), systemImage: "trash") }
        }
    }

    private func folderHeader(_ folder: String) -> some View {
        HStack {
            Button {
                openFolder = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(L("Tất cả", "All"))
                }
            }
            Spacer()
            Label(folder, systemImage: "folder.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button { askRenameFolder(folder) } label: { Image(systemName: "pencil") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L("Tìm trong \(list.title)", "Search \(list.title)"), text: $search)
                    .disableAutocorrection(true)
                    .focused($searchFocused)
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))

            Menu {
                if usesFolders {
                    Picker(L("Hiển thị", "Show"), selection: $viewModeRaw) {
                        Label(L("Hiện tất cả địa điểm", "Show all places"), systemImage: "list.bullet.indent").tag(BookmarkViewMode.all.rawValue)
                        Label(L("Hiện theo danh sách", "Show by list"), systemImage: "folder").tag(BookmarkViewMode.folders.rawValue)
                    }
                    Divider()
                }
                Picker(L("Sắp xếp", "Sort"), selection: sortRaw) {
                    ForEach(BookmarkSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18))
            }

            Menu {
                if usesFolders {
                    Button { askNewFolder() } label: { Label(L("Tạo danh sách mới", "New list"), systemImage: "folder.badge.plus") }
                    Divider()
                }
                Button { share() } label: { Label(L("Xuất file (.txt)", "Export file (.txt)"), systemImage: "square.and.arrow.up") }
                Button { copyText() } label: { Label(L("Sao chép văn bản", "Copy as text"), systemImage: "doc.on.doc") }
                Divider()
                Button { showImporter = true } label: { Label(L("Nhập từ file", "Import from file"), systemImage: "square.and.arrow.down") }
                Button { showPaste = true } label: { Label(L("Dán văn bản", "Paste text"), systemImage: "doc.on.clipboard") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: viewModeRaw) { _ in openFolder = nil }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty && folders.isEmpty {
            VStack(spacing: 8) {
                Text(list == .history ? L("Chưa có lịch sử", "No history yet") : L("Chưa có đánh dấu", "No bookmarks yet"))
                    .font(.headline).foregroundColor(.secondary)
                Text(list == .history
                     ? L("Mỗi lần bấm ▶ để giả lập trên bản đồ, vị trí sẽ được ghi vào đây.", "Every time you tap ▶ on the map, the location is recorded here.")
                     : L("Bấm ☆ trên bản đồ để lưu vị trí ghim,\nhoặc nhập từ file (nút ⋯).", "In History, press and hold a place → Add to Bookmarks,\nor import a file (⋯ button)."))
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if isSearching && filterAndSort(items, search: search, sort: sort).isEmpty {
            Text(L("Không tìm thấy \"\(search)\"", "No results for \"\(search)\"")).foregroundColor(.secondary).padding()
        }
    }

    // MARK: - Actions

    private func reload() {
        items = loadList(list)
        folders = usesFolders ? loadFolders() : []
        favFolders = usesFolders ? favouriteFolders() : []
        if let f = openFolder, !folders.contains(f) { openFolder = nil }
    }

    private func toggle(_ folder: String) {
        var c = collapsed
        if c.contains(folder) { c.remove(folder) } else { c.insert(folder) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }

    private func remove(_ item: Bookmark) {
        deleteItem(list, id: item.id)
        reload()
    }

    private func openEdit(_ e: PlaceEdit) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { editing = e }
    }

    private func save(_ edit: PlaceEdit, _ r: PlaceEditView.Result) {
        switch edit.mode {
        case .edit:
            updateItem(edit.list, id: edit.item.id, name: r.name, lat: r.lat, long: r.long,
                       folders: edit.list == .bookmarks ? r.folders : nil)
        case .newBookmark:
            let added = addToBookmarks(name: r.name, lat: r.lat, long: r.long, folders: r.folders)
            AlertKitAPI.present(title: added ? L("Đã thêm vào Đánh dấu", "Added to Bookmarks") : L("Đã cập nhật trong Đánh dấu", "Updated in Bookmarks"),
                                icon: .done, style: .iOS17AppleMusic, haptic: .success)
        }
        reload()
    }

    private func askNewFolder() {
        searchFocused = false
        folderEdit = FolderEdit(original: nil)
    }

    private func askRenameFolder(_ folder: String) {
        searchFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { folderEdit = FolderEdit(original: folder) }
    }

    private func askDeleteFolder(_ folder: String) {
        UIApplication.shared.confirmAlert(title: L("Xoá danh sách \"\(folder)\"?", "Delete list \"\(folder)\"?"),
                                          body: L("Các địa điểm bên trong vẫn được giữ lại và chuyển ra ngoài danh sách.", "The places inside are kept and moved out of the list."),
                                          onOK: { deleteFolder(folder); reload() }, noCancel: false)
    }

    private func copyText() {
        guard !items.isEmpty else {
            showResult(L("Trống", "Empty"), L("Chưa có vị trí nào để sao chép.", "There is nothing to copy yet."))
            return
        }
        UIPasteboard.general.string = exportText(list, sorted(items))
        showResult(L("Sao chép thành công", "Copied"), L("Đã sao chép \(items.count) vị trí của \(list.title). Dán vào Zalo hoặc tin nhắn để gửi sang máy khác.", "Copied \(items.count) places from \(list.title). Paste them into a message to send to another phone."))
    }

    private func share() {
        guard !items.isEmpty else {
            showResult(L("Trống", "Empty"), L("Chưa có vị trí nào để xuất.", "There is nothing to export yet."))
            return
        }
        guard let url = exportFile(list, sorted(items)) else {
            showResult(L("Xuất file thất bại", "Export failed"), L("Không tạo được file.", "Could not create the file."))
            return
        }
        let count = items.count
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, error in
            if completed {
                showResult(L("Xuất file thành công", "Export complete"), L("Đã xuất \(count) vị trí của \(list.title) (\(url.lastPathComponent)).", "Exported \(count) places from \(list.title) (\(url.lastPathComponent))."))
            } else if let error {
                showResult(L("Xuất file thất bại", "Export failed"), error.localizedDescription)
            }
        }
        presentTop(vc)
    }

    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            showResult(L("Nhập thất bại", "Import failed"), L("Không đọc được file.", "Could not read the file."))
            return
        }
        importText(text)
    }

    private func importText(_ text: String) {
        var found = parseText(text)
        guard !found.isEmpty else {
            showResult(L("Nhập thất bại", "Import failed"), L("Không có vị trí nào đúng định dạng.", "No locations in the right format."))
            return
        }
        // Importing while a list is open puts places without a list into it.
        if list == .bookmarks, let f = openFolder {
            for i in found.indices where !found[i].folders.contains(f) { found[i].folders.append(f) }
        }
        let added = addItems(list, found)
        if list == .bookmarks { parseFavouriteFolders(text).forEach { setFavouriteFolder($0, true) } }
        reload()
        showResult(added > 0 ? L("Nhập thành công", "Import complete") : L("Không có vị trí mới", "No new locations"),
                   L("Đã thêm \(added) vị trí vào \(list.title)", "Added \(added) places to \(list.title)") + (found.count > added ? L(", bỏ qua \(found.count - added) vị trí trùng.", ", skipped \(found.count - added) duplicates.") : "."))
    }
}

struct FolderEdit: Identifiable {
    let id = UUID()
    var original: String?      // nil = new list
}

/// Create / edit a list: name + tick the places that belong to it.
struct FolderEditView: View {
    @Environment(\.dismiss) var dismiss
    let original: String?
    var onSaved: (String) -> Void

    @State private var name = ""
    @State private var items: [Bookmark] = []
    @State private var picked: Set<String> = []
    @State private var search = ""
    @State private var didLoad = false

    private var shown: [Bookmark] { filterAndSort(items, search: search, sort: .az) }
    private var allShownPicked: Bool { !shown.isEmpty && shown.allSatisfy { picked.contains($0.id) } }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField(L("Tên danh sách", "List name"), text: $name)
                        .font(.body.weight(.semibold))
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField(L("Tìm địa điểm để thêm", "Search places to add"), text: $search).disableAutocorrection(true)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))
                    HStack {
                        Text(L("Đã chọn \(picked.count)", "Selected \(picked.count)")).font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button(allShownPicked ? L("Bỏ chọn tất cả", "Deselect all") : L("Chọn tất cả", "Select all")) {
                            if allShownPicked { shown.forEach { picked.remove($0.id) } }
                            else { shown.forEach { picked.insert($0.id) } }
                        }
                        .font(.footnote.weight(.semibold))
                        .disabled(shown.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                List(shown) { item in
                    Button {
                        if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: picked.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 21))
                                .foregroundColor(picked.contains(item.id) ? .accentColor : Color(.tertiaryLabel))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayName)
                                    .foregroundColor(item.isUnnamed ? .secondary : .primary)
                                    .lineLimit(2)
                                let others = item.folders.filter { $0 != original }
                                if !others.isEmpty {
                                    Text("📁 \(others.joined(separator: ", "))").font(.footnote).foregroundColor(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                }
                .listStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in hideKeyboard() })
                .overlay(Group {
                    if items.isEmpty {
                        Text(L("Chưa có địa điểm nào trong Đánh dấu.", "There are no places in Bookmarks yet.")).foregroundColor(.secondary).padding()
                    }
                })
            }
            .navigationTitle(original == nil ? L("Tạo danh sách", "New list") : L("Sửa danh sách", "Edit list"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Lưu", "Save")) { save() }
                        .font(.body.weight(.semibold))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                items = loadList(.bookmarks)
                name = original ?? ""
                if let o = original { picked = Set(items.filter { $0.folders.contains(o) }.map { $0.id }) }
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveFolder(original: original, name: n, memberIDs: picked, keepOtherLists: true)
        AlertKitAPI.present(title: original == nil ? L("Đã tạo danh sách", "List created") : L("Đã lưu danh sách", "List saved"),
                            icon: .done, style: .iOS17AppleMusic, haptic: .success)
        dismiss()
        onSaved(n)
    }
}

/// Clear "done / failed" message (shown after any sheet has closed).
func showResult(_ title: String, _ message: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        presentTop(a)
    }
}

/// One-field text prompt.
func textPrompt(title: String, placeholder: String, text: String, onSave: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    alert.addTextField { f in
        f.text = text
        f.placeholder = placeholder
        f.clearButtonMode = .whileEditing
        f.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: L("Huỷ", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("Lưu", "Save"), style: .default) { _ in
        let t = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onSave(t) }
    })
    presentTop(alert)
}

// MARK: - Edit / save sheet (name, latitude, longitude, list)

struct PlaceEditView: View {
    struct Result { var name: String; var lat: Double; var long: Double; var folders: [String] }

    @Environment(\.dismiss) var dismiss
    let edit: PlaceEdit
    let folders: [String]
    var defaultFolder: String = ""
    var onSave: (Result) -> Void

    @State private var name = ""
    @State private var lat = ""
    @State private var long = ""
    @State private var chosen: Set<String> = []
    @State private var newFolder = ""
    @State private var didLoad = false

    private var showsFolder: Bool { edit.mode == .newBookmark || edit.list == .bookmarks }

    var body: some View {
        NavigationView {
            Form {
                Section(L("Tên", "Name")) {
                    TextField(L("Tên (để trống = Unnamed)", "Name (empty = Unnamed)"), text: $name)
                }
                Section(L("Toạ độ", "Coordinates")) {
                    TextField(L("Vĩ độ (latitude)", "Latitude"), text: $lat).keyboardType(.numbersAndPunctuation)
                    TextField(L("Kinh độ (longitude)", "Longitude"), text: $long).keyboardType(.numbersAndPunctuation)
                }
                if showsFolder {
                    Section {
                        ForEach(folders, id: \.self) { f in
                            Button {
                                if chosen.contains(f) { chosen.remove(f) } else { chosen.insert(f) }
                            } label: {
                                HStack {
                                    Image(systemName: chosen.contains(f) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(chosen.contains(f) ? .accentColor : Color(.tertiaryLabel))
                                    Text(f).foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                        }
                        TextField(L("Tạo danh sách mới…", "Create a new list…"), text: $newFolder)
                    } header: {
                        Text(L("Danh sách", "Lists"))
                    } footer: {
                        Text(L("Tích các danh sách muốn đưa vị trí vào. Gõ tên mới để tạo thêm danh sách.", "Tick the lists for this place. Type a name to create a new list."))
                    }
                }
            }
            .navigationTitle(edit.mode == .newBookmark ? L("Lưu vào Đánh dấu", "Save to Bookmarks") : L("Sửa vị trí", "Edit location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button(L("Lưu", "Save")) { save() }.font(.body.weight(.semibold)) }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                name = edit.item.name
                lat = String(format: "%.7f", edit.item.lat)
                long = String(format: "%.7f", edit.item.long)
                if edit.mode == .edit { chosen = Set(edit.item.folders) }
                else if !defaultFolder.isEmpty { chosen = [defaultFolder] }
            }
        }
    }

    private func save() {
        let num: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        guard let la = num(lat), let lo = num(long), (-90...90).contains(la), (-180...180).contains(lo) else {
            UIApplication.shared.alert(body: L("Toạ độ không hợp lệ.", "Invalid coordinates."))
            return
        }
        var lists = folders.filter { chosen.contains($0) } + chosen.filter { !folders.contains($0) }.sorted()
        let nf = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nf.isEmpty { lists.append(nf) }
        onSave(Result(name: name, lat: la, long: lo, folders: cleanLists(lists)))
        dismiss()
    }
}

/// Paste exported text (e.g. from a Zalo message) and import it.
struct PasteImportView: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    var onImport: (String) -> Void
    @State private var text = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Dán nội dung đã xuất (mỗi dòng: Tên | Vĩ độ, Kinh độ). Vị trí sẽ được nhập vào \(title).", "Paste exported text (one per line: Name | Latitude, Longitude). Places will be imported into \(title)."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                Button {
                    text = UIPasteboard.general.string ?? ""
                } label: {
                    Label(L("Dán từ bộ nhớ tạm", "Paste from clipboard"), systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle(L("Dán văn bản", "Paste text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Nhập", "Import")) {
                        let t = text
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onImport(t) }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Presents any view controller on top of whatever is showing (works on iPad too).
func presentTop(_ vc: UIViewController) {
    guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
          var top = window.rootViewController else { return }
    while let p = top.presentedViewController { top = p }
    if let pop = vc.popoverPresentationController {
        pop.sourceView = top.view
        pop.sourceRect = CGRect(x: top.view.bounds.midX, y: 80, width: 1, height: 1)
    }
    top.present(vc, animated: true)
}
