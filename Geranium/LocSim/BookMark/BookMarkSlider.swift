//
//  BookMarkSlider.swift
//  Location Simulator
//
//  List used by the History and Bookmarks tabs.
//

import SwiftUI
import AlertKit
import UniformTypeIdentifiers

struct LocationListView: View {
    let list: LocList
    var onStart: (Bookmark) -> Void
    var onShowOnMap: (Bookmark) -> Void

    @State private var items: [Bookmark] = []
    @State private var search = ""
    @AppStorage("sort_history") private var sortHistory: String = BookmarkSort.newest.rawValue
    @AppStorage("sort_bookmarks") private var sortBookmarks: String = BookmarkSort.az.rawValue
    @State private var selected: Bookmark? = nil
    @State private var showMenu = false
    @State private var showImporter = false
    @State private var showPaste = false
    @FocusState private var searchFocused: Bool

    private var sortRaw: Binding<String> { list == .history ? $sortHistory : $sortBookmarks }
    private var sort: BookmarkSort { BookmarkSort(rawValue: sortRaw.wrappedValue) ?? .az }
    private var shown: [Bookmark] { filterAndSort(items, search: search, sort: sort) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            List {
                ForEach(shown) { item in
                    Button {
                        searchFocused = false                       // hide keyboard first
                        hideKeyboard()
                        selected = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showMenu = true }
                    } label: {
                        row(item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove(item) } label: { Label("Xoá", systemImage: "trash") }
                        Button { edit(item) } label: { Label("Sửa", systemImage: "pencil") }.tint(.orange)
                    }
                }
            }
            .listStyle(.plain)
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
                Button("Sửa vị trí") { edit(item) }
                if list == .history {
                    Button("Thêm vào Đánh dấu") {
                        let picked = item
                        DispatchQueue.main.async {
                            let ok = addToBookmarks(picked)
                            let count = loadList(.bookmarks).count
                            AlertKitAPI.present(title: ok ? "Đã thêm vào Đánh dấu (\(count))" : "Đã có trong Đánh dấu",
                                                icon: .done, style: .iOS17AppleMusic, haptic: .success)
                        }
                    }
                }
                Button("Xoá", role: .destructive) { remove(item) }
                Button("Huỷ", role: .cancel) {}
            }
        } message: {
            if let item = selected { Text(String(format: "%.6f, %.6f", item.lat, item.long)) }
        }
        .sheet(isPresented: $showPaste) {
            PasteImportView(title: list.title) { text in importText(text) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    // MARK: Top bar: search, sort, export/import

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
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))

            Menu {
                Picker("Sắp xếp", selection: sortRaw) {
                    ForEach(BookmarkSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 16))
            }

            Menu {
                Button { share() } label: { Label("Xuất file (.txt)", systemImage: "square.and.arrow.up") }
                Button { copyText() } label: { Label("Sao chép văn bản", systemImage: "doc.on.doc") }
                Divider()
                Button { showImporter = true } label: { Label("Nhập từ file", systemImage: "square.and.arrow.down") }
                Button { showPaste = true } label: { Label("Dán văn bản", systemImage: "doc.on.clipboard") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Row

    private func row(_ item: Bookmark) -> some View {
        HStack(spacing: 12) {
            Image(systemName: list == .history ? "clock.arrow.circlepath" : "star.fill")
                .foregroundColor(list == .history ? .secondary : .yellow)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .foregroundColor(item.isUnnamed ? .secondary : .primary)
                    .lineLimit(2)
                Text(String(format: "%.6f, %.6f", item.lat, item.long))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.gray)
                if item.date > 0 {
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.date)))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd/MM/yyyy"
        return f
    }()

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Text(list == .history ? "Chưa có lịch sử" : "Chưa có đánh dấu")
                    .font(.title3).foregroundColor(.secondary)
                Text(list == .history
                     ? "Mỗi lần bấm ▶ để giả lập trên bản đồ, vị trí sẽ được ghi vào đây."
                     : "Chạm vào một vị trí trong Lịch sử → Thêm vào Đánh dấu,\nhoặc nhập từ file (nút ⋯).")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if shown.isEmpty {
            Text("Không tìm thấy \"\(search)\"").foregroundColor(.secondary).padding()
        }
    }

    // MARK: Actions

    private func reload() { items = loadList(list) }

    private func remove(_ item: Bookmark) {
        deleteItem(list, id: item.id)
        reload()
    }

    private func edit(_ item: Bookmark) {
        let alert = UIAlertController(title: "Sửa vị trí", message: nil, preferredStyle: .alert)
        alert.addTextField { f in
            f.text = item.name
            f.placeholder = "Tên (để trống = Unnamed)"
            f.clearButtonMode = .whileEditing
            f.autocapitalizationType = .sentences
        }
        alert.addTextField { f in
            f.text = String(format: "%.6f", item.lat)
            f.placeholder = "Vĩ độ (latitude)"
            f.keyboardType = .numbersAndPunctuation
        }
        alert.addTextField { f in
            f.text = String(format: "%.6f", item.long)
            f.placeholder = "Kinh độ (longitude)"
            f.keyboardType = .numbersAndPunctuation
        }
        alert.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { _ in
            let fields = alert.textFields ?? []
            let num: (Int) -> Double? = { i in
                Double((fields[i].text ?? "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            }
            guard let la = num(1), let lo = num(2), (-90...90).contains(la), (-180...180).contains(lo) else {
                UIApplication.shared.alert(body: "Toạ độ không hợp lệ.")
                return
            }
            updateItem(list, id: item.id, name: fields[0].text ?? "", lat: la, long: lo)
            reload()
        })
        UIApplication.shared.present(alert: alert)
    }

    private func copyText() {
        guard !items.isEmpty else {
            UIApplication.shared.alert(title: "Trống", body: "Chưa có vị trí nào để sao chép.")
            return
        }
        UIPasteboard.general.string = exportText(list, filterAndSort(items, search: "", sort: sort))
        AlertKitAPI.present(title: "Đã sao chép \(items.count) vị trí", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func share() {
        guard !items.isEmpty else {
            UIApplication.shared.alert(title: "Trống", body: "Chưa có vị trí nào để xuất.")
            return
        }
        guard let url = exportFile(list, filterAndSort(items, search: "", sort: sort)) else {
            UIApplication.shared.alert(body: "Không tạo được file.")
            return
        }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        presentTop(vc)
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
        let found = parseText(text)
        guard !found.isEmpty else {
            UIApplication.shared.alert(body: "Không có vị trí nào đúng định dạng.")
            return
        }
        let added = addItems(list, found)
        reload()
        UIApplication.shared.alert(title: "Đã nhập vào \(list.title)",
                                   body: "Thêm \(added) vị trí" + (found.count > added ? ", bỏ qua \(found.count - added) vị trí trùng." : "."))
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
