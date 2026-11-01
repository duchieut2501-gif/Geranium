//
//  BookMarkSlider.swift
//  Location Simulator
//
//  Lists used by the Places tab: Bookmarks (with lists/folders) and History.
//

import SwiftUI
import AlertKit
import UniformTypeIdentifiers

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
    @State private var search = ""
    @AppStorage("sort_history") private var sortHistory: String = BookmarkSort.newest.rawValue
    @AppStorage("sort_bookmarks") private var sortBookmarks: String = BookmarkSort.az.rawValue
    @AppStorage("bmViewMode") private var viewModeRaw: String = BookmarkViewMode.all.rawValue
    @AppStorage("collapsedFolders") private var collapsedRaw: String = ""
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
                Button("Giả lập vị trí này") { onStart(item); reload() }
                Button("Đặt vị trí này lên bản đồ") { onShowOnMap(item) }
                Button("Sửa vị trí") { openEdit(PlaceEdit(mode: .edit, list: list, item: item)) }
                if list == .history {
                    Button("Thêm vào Đánh dấu") { openEdit(PlaceEdit(mode: .newBookmark, list: .bookmarks, item: item)) }
                }
                Button("Xoá", role: .destructive) { remove(item) }
                Button("Huỷ", role: .cancel) {}
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
            ForEach(sorted(items.filter { $0.folder == folder })) { item in
                placeRow(item, indent: false, showFolder: false)
            }
        } else {
            ForEach(folders, id: \.self) { folder in
                folderRow(folder)
                if viewMode == .all && !collapsed.contains(folder) {
                    ForEach(sorted(items.filter { $0.folder == folder })) { item in
                        placeRow(item, indent: true, showFolder: false)
                    }
                }
            }
            ForEach(sorted(items.filter { $0.folder.isEmpty || !folders.contains($0.folder) })) { item in
                placeRow(item, indent: false, showFolder: false)
            }
        }
    }

    private func sorted(_ arr: [Bookmark]) -> [Bookmark] { filterAndSort(arr, search: "", sort: sort) }

    private func placeRow(_ item: Bookmark, indent: Bool, showFolder: Bool) -> some View {
        Button {
            searchFocused = false
            hideKeyboard()
            selected = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showMenu = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.body)
                        .foregroundColor(item.isUnnamed ? .secondary : .primary)
                        .lineLimit(2)
                    Text(subtitle(item, showFolder: showFolder))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.leading, indent ? 22 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(item) } label: { Label("Xoá", systemImage: "trash") }
            Button { openEdit(PlaceEdit(mode: .edit, list: list, item: item)) } label: { Label("Sửa", systemImage: "pencil") }
                .tint(.orange)
        }
    }

    private func coordLine(_ item: Bookmark) -> String {
        "Kinh độ:\(fmt(item.long))  Vĩ độ:\(fmt(item.lat))"
    }

    private func subtitle(_ item: Bookmark, showFolder: Bool) -> String {
        var s = coordLine(item)
        if list == .history, item.date > 0 {
            s += "  ·  " + Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.date))
        }
        if showFolder, !item.folder.isEmpty { s = "📁 \(item.folder)  ·  " + s }
        return s
    }

    /// Up to 7 decimals, trailing zeros removed (like LocSim).
    private func fmt(_ v: Double) -> String {
        var t = String(format: "%.7f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd/MM"
        return f
    }()

    private func folderRow(_ folder: String) -> some View {
        let count = items.filter { $0.folder == folder }.count
        let isOpen = !collapsed.contains(folder)
        return Button {
            if viewMode == .all { toggle(folder) } else { openFolder = folder }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
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
            Button(role: .destructive) { askDeleteFolder(folder) } label: { Label("Xoá", systemImage: "trash") }
            Button { askRenameFolder(folder) } label: { Label("Sửa", systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            Button { askRenameFolder(folder) } label: { Label("Sửa danh sách", systemImage: "pencil") }
            Button(role: .destructive) { askDeleteFolder(folder) } label: { Label("Xoá danh sách", systemImage: "trash") }
        }
    }

    private func folderHeader(_ folder: String) -> some View {
        HStack {
            Button {
                openFolder = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Tất cả")
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
                TextField("Tìm trong \(list.title)", text: $search)
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
                    Picker("Hiển thị", selection: $viewModeRaw) {
                        Label("Hiện tất cả địa điểm", systemImage: "list.bullet.indent").tag(BookmarkViewMode.all.rawValue)
                        Label("Hiện theo danh sách", systemImage: "folder").tag(BookmarkViewMode.folders.rawValue)
                    }
                    Divider()
                }
                Picker("Sắp xếp", selection: sortRaw) {
                    ForEach(BookmarkSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18))
            }

            Menu {
                if usesFolders {
                    Button { askNewFolder() } label: { Label("Tạo danh sách mới", systemImage: "folder.badge.plus") }
                    Divider()
                }
                Button { share() } label: { Label("Xuất file (.txt)", systemImage: "square.and.arrow.up") }
                Button { copyText() } label: { Label("Sao chép văn bản", systemImage: "doc.on.doc") }
                Divider()
                Button { showImporter = true } label: { Label("Nhập từ file", systemImage: "square.and.arrow.down") }
                Button { showPaste = true } label: { Label("Dán văn bản", systemImage: "doc.on.clipboard") }
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
                Text(list == .history ? "Chưa có lịch sử" : "Chưa có đánh dấu")
                    .font(.headline).foregroundColor(.secondary)
                Text(list == .history
                     ? "Mỗi lần bấm ▶ để giả lập trên bản đồ, vị trí sẽ được ghi vào đây."
                     : "Bấm ☆ trên bản đồ để lưu vị trí ghim,\nhoặc nhập từ file (nút ⋯).")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if isSearching && filterAndSort(items, search: search, sort: sort).isEmpty {
            Text("Không tìm thấy \"\(search)\"").foregroundColor(.secondary).padding()
        }
    }

    // MARK: - Actions

    private func reload() {
        items = loadList(list)
        folders = usesFolders ? loadFolders() : []
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
                       folder: edit.list == .bookmarks ? r.folder : nil)
        case .newBookmark:
            let added = addToBookmarks(name: r.name, lat: r.lat, long: r.long, folder: r.folder)
            AlertKitAPI.present(title: added ? "Đã thêm vào Đánh dấu" : "Đã cập nhật trong Đánh dấu",
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
        UIApplication.shared.confirmAlert(title: "Xoá danh sách \"\(folder)\"?",
                                          body: "Các địa điểm bên trong vẫn được giữ lại và chuyển ra ngoài danh sách.",
                                          onOK: { deleteFolder(folder); reload() }, noCancel: false)
    }

    private func copyText() {
        guard !items.isEmpty else {
            UIApplication.shared.alert(title: "Trống", body: "Chưa có vị trí nào để sao chép.")
            return
        }
        UIPasteboard.general.string = exportText(list, sorted(items))
        AlertKitAPI.present(title: "Đã sao chép \(items.count) vị trí", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func share() {
        guard !items.isEmpty else {
            UIApplication.shared.alert(title: "Trống", body: "Chưa có vị trí nào để xuất.")
            return
        }
        guard let url = exportFile(list, sorted(items)) else {
            UIApplication.shared.alert(body: "Không tạo được file.")
            return
        }
        presentTop(UIActivityViewController(activityItems: [url], applicationActivities: nil))
    }

    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            UIApplication.shared.alert(body: "Không đọc được file.")
            return
        }
        importText(text)
    }

    private func importText(_ text: String) {
        var found = parseText(text)
        guard !found.isEmpty else {
            UIApplication.shared.alert(body: "Không có vị trí nào đúng định dạng.")
            return
        }
        // Importing while a list is open puts places without a list into it.
        if list == .bookmarks, let f = openFolder {
            for i in found.indices where found[i].folder.isEmpty { found[i].folder = f }
        }
        let added = addItems(list, found)
        reload()
        UIApplication.shared.alert(title: "Đã nhập vào \(list.title)",
                                   body: "Thêm \(added) vị trí" + (found.count > added ? ", bỏ qua \(found.count - added) vị trí trùng." : "."))
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
                    TextField("Tên danh sách", text: $name)
                        .font(.body.weight(.semibold))
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Tìm địa điểm để thêm", text: $search).disableAutocorrection(true)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))
                    HStack {
                        Text("Đã chọn \(picked.count)").font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button(allShownPicked ? "Bỏ chọn tất cả" : "Chọn tất cả") {
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
                                if !item.folder.isEmpty && item.folder != original {
                                    Text("📁 \(item.folder)").font(.footnote).foregroundColor(.secondary)
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
                        Text("Chưa có địa điểm nào trong Đánh dấu.").foregroundColor(.secondary).padding()
                    }
                })
            }
            .navigationTitle(original == nil ? "Tạo danh sách" : "Sửa danh sách")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Lưu") { save() }
                        .font(.body.weight(.semibold))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                items = loadList(.bookmarks)
                name = original ?? ""
                if let o = original { picked = Set(items.filter { $0.folder == o }.map { $0.id }) }
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveFolder(original: original, name: n, memberIDs: picked)
        AlertKitAPI.present(title: original == nil ? "Đã tạo danh sách" : "Đã lưu danh sách",
                            icon: .done, style: .iOS17AppleMusic, haptic: .success)
        dismiss()
        onSaved(n)
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
    alert.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
    alert.addAction(UIAlertAction(title: "Lưu", style: .default) { _ in
        let t = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onSave(t) }
    })
    presentTop(alert)
}

// MARK: - Edit / save sheet (name, latitude, longitude, list)

struct PlaceEditView: View {
    struct Result { var name: String; var lat: Double; var long: Double; var folder: String }

    @Environment(\.dismiss) var dismiss
    let edit: PlaceEdit
    let folders: [String]
    var defaultFolder: String = ""
    var onSave: (Result) -> Void

    @State private var name = ""
    @State private var lat = ""
    @State private var long = ""
    @State private var folder = ""
    @State private var newFolder = ""
    @State private var didLoad = false

    private var showsFolder: Bool { edit.mode == .newBookmark || edit.list == .bookmarks }

    var body: some View {
        NavigationView {
            Form {
                Section("Tên") {
                    TextField("Tên (để trống = Unnamed)", text: $name)
                }
                Section("Toạ độ") {
                    TextField("Vĩ độ (latitude)", text: $lat).keyboardType(.numbersAndPunctuation)
                    TextField("Kinh độ (longitude)", text: $long).keyboardType(.numbersAndPunctuation)
                }
                if showsFolder {
                    Section {
                        Picker("Danh sách", selection: $folder) {
                            Text("Không thuộc danh sách").tag("")
                            ForEach(folders, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Hoặc tạo danh sách mới…", text: $newFolder)
                    } header: {
                        Text("Danh sách")
                    } footer: {
                        Text("Nếu gõ tên danh sách mới, vị trí sẽ được đưa vào danh sách đó.")
                    }
                }
            }
            .navigationTitle(edit.mode == .newBookmark ? "Lưu vào Đánh dấu" : "Sửa vị trí")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Lưu") { save() }.font(.body.weight(.semibold)) }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                name = edit.item.name
                lat = String(format: "%.7f", edit.item.lat)
                long = String(format: "%.7f", edit.item.long)
                folder = edit.mode == .edit ? edit.item.folder : defaultFolder
                if !folder.isEmpty && !folders.contains(folder) { newFolder = folder; folder = "" }
            }
        }
    }

    private func save() {
        let num: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        guard let la = num(lat), let lo = num(long), (-90...90).contains(la), (-180...180).contains(lo) else {
            UIApplication.shared.alert(body: "Toạ độ không hợp lệ.")
            return
        }
        let nf = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(Result(name: name, lat: la, long: lo, folder: nf.isEmpty ? folder : nf))
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
                Text("Dán nội dung đã xuất (mỗi dòng: Tên | Vĩ độ, Kinh độ). Vị trí sẽ được nhập vào \(title).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                Button {
                    text = UIPasteboard.general.string ?? ""
                } label: {
                    Label("Dán từ bộ nhớ tạm", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Dán văn bản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Nhập") {
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
