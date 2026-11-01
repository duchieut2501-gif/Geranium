//
//  BookMarkSlider.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//  Modified: search, A-Z sort, rename, unnamed locations.
//

import SwiftUI
import AlertKit

struct BookMarkSlider: View {
    @Environment(\.dismiss) var dismiss
    /// Called when the user taps a saved location to fake it.
    var onStart: (Bookmark) -> Void

    @State private var bookmarks: [Bookmark] = loadBookmarks()
    @State private var searchText = ""
    @AppStorage("bookmarkSort") private var sortRaw: String = BookmarkSort.az.rawValue
    @AppStorage("isMika") var isMika: Bool = false

    private var sort: BookmarkSort { BookmarkSort(rawValue: sortRaw) ?? .az }
    private var shown: [Bookmark] { filterAndSort(bookmarks, search: searchText, sort: sort) }

    var body: some View {
        NavigationView {
            List {
                ForEach(shown) { bookmark in
                    Button {
                        dismiss()
                        onStart(bookmark)
                    } label: {
                        row(bookmark)
                    }
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            remove(bookmark)
                        } label: {
                            Label("Xoá", systemImage: "trash")
                        }
                        Button {
                            askRename(bookmark)
                        } label: {
                            Label("Đổi tên", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button {
                            askRename(bookmark)
                        } label: {
                            Label("Đổi tên", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            remove(bookmark)
                        } label: {
                            Label("Xoá", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Tìm vị trí đã lưu")
            .navigationTitle("Vị trí đã lưu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sắp xếp", selection: $sortRaw) {
                            ForEach(BookmarkSort.allCases) { option in
                                Label(option.label, systemImage: option.icon).tag(option.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.title3)
                    }
                }
            }
            .overlay(emptyState, alignment: .center)
            .onAppear {
                bookmarks = loadBookmarks()
                if isThereAnyMika(), !isMika {
                    UIApplication.shared.confirmAlert(title: "Phát hiện vị trí đã lưu của LocSim (Mika)",
                                                      body: "Bạn có muốn nhập chúng vào không?",
                                                      onOK: {
                        importMika()
                        bookmarks = loadBookmarks()
                        isMika = true
                    }, noCancel: false, onCancel: {
                        isMika = true
                    }, yes: true)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bookmark.displayName)
                .font(.headline)
                .italicIf(bookmark.isUnnamed)
                .foregroundColor(bookmark.isUnnamed ? .secondary : .primary)
                .lineLimit(2)
            Text(String(format: "%.6f, %.6f", bookmark.lat, bookmark.long))
                .font(.caption.monospacedDigit())
                .foregroundColor(.gray)
            if bookmark.date > 0 {
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: bookmark.date)))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 2)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm dd/MM/yyyy"
        return f
    }()

    @ViewBuilder
    private var emptyState: some View {
        if bookmarks.isEmpty {
            VStack(spacing: 8) {
                Text("Chưa có vị trí nào")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Kéo bản đồ cho ghim vào đúng chỗ rồi bấm Bắt đầu.\nMỗi lần fake sẽ được lưu tự động ở đây.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if shown.isEmpty {
            Text("Không tìm thấy \"\(searchText)\"")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    // MARK: - Actions

    private func remove(_ bookmark: Bookmark) {
        deleteBookmark(id: bookmark.id)
        bookmarks = loadBookmarks()
        AlertKitAPI.present(title: "Đã xoá", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func askRename(_ bookmark: Bookmark) {
        let alert = UIAlertController(title: "Đổi tên vị trí", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = bookmark.name
            field.placeholder = "Tên vị trí (để trống = Unnamed)"
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { _ in
            renameBookmark(id: bookmark.id, to: alert.textFields?.first?.text ?? "")
            bookmarks = loadBookmarks()
        })
        UIApplication.shared.present(alert: alert)
    }
}

private extension Text {
    func italicIf(_ on: Bool) -> Text { on ? self.italic() : self }
}
