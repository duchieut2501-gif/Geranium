//
//  BookMarkHelper.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//  Modified: auto-save, rename, search & A-Z sort.
//

import Foundation
import SwiftUI
import CoreLocation

let sharedUserDefaultsSuiteName = "group.live.cclerc.geraniumBookmarks"
private let bookmarksKey = "bookmarks"

// MARK: - Model

struct Bookmark: Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var long: Double
    /// Last time this location was faked/saved (timeIntervalSince1970). 0 = unknown (old bookmarks).
    var date: Double

    init(id: String = UUID().uuidString, name: String, lat: Double, long: Double, date: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.lat = lat
        self.long = long
        self.date = date
    }

    init?(dict: [String: Any]) {
        guard let lat = (dict["lat"] as? NSNumber)?.doubleValue,
              let long = (dict["long"] as? NSNumber)?.doubleValue else { return nil }
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.name = dict["name"] as? String ?? ""
        self.lat = lat
        self.long = long
        self.date = (dict["date"] as? NSNumber)?.doubleValue ?? 0
    }

    var dict: [String: Any] {
        ["id": id, "name": name, "lat": lat, "long": long, "date": date]
    }

    var isUnnamed: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        isUnnamed ? "Unnamed" : name
    }
}

// MARK: - Storage

func loadBookmarks() -> [Bookmark] {
    let raw = BookMarkRetrieve()
    let list = raw.compactMap { Bookmark(dict: $0) }
    // Old bookmarks have no id -> persist the generated ids once so they stay stable.
    if raw.contains(where: { $0["id"] == nil }) {
        saveBookmarks(list)
    }
    return list
}

func saveBookmarks(_ bookmarks: [Bookmark]) {
    let sharedUserDefaults = UserDefaults(suiteName: sharedUserDefaultsSuiteName)
    sharedUserDefaults?.set(bookmarks.map { $0.dict }, forKey: bookmarksKey)
    sharedUserDefaults?.synchronize()
}

/// Called every time a fake location is started from the map.
/// If a saved location already exists within `mergeDistance` meters, it is moved to the top
/// (date refreshed) instead of creating a duplicate. New locations are saved without a name.
@discardableResult
func autoSaveFakedLocation(lat: Double, long: Double, mergeDistance: CLLocationDistance = 5) -> Bookmark {
    var bookmarks = loadBookmarks()
    let target = CLLocation(latitude: lat, longitude: long)
    let now = Date().timeIntervalSince1970

    if let index = bookmarks.firstIndex(where: {
        CLLocation(latitude: $0.lat, longitude: $0.long).distance(from: target) <= mergeDistance
    }) {
        bookmarks[index].date = now
        saveBookmarks(bookmarks)
        return bookmarks[index]
    }

    let new = Bookmark(name: "", lat: lat, long: long, date: now)
    bookmarks.append(new)
    saveBookmarks(bookmarks)
    return new
}

func renameBookmark(id: String, to newName: String) {
    var bookmarks = loadBookmarks()
    guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
    bookmarks[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    saveBookmarks(bookmarks)
}

func deleteBookmark(id: String) {
    var bookmarks = loadBookmarks()
    bookmarks.removeAll { $0.id == id }
    saveBookmarks(bookmarks)
}

/// Kept for compatibility (Mika import / old code paths).
@discardableResult
func BookMarkSave(lat: Double, long: Double, name: String) -> Bool {
    var bookmarks = loadBookmarks()
    bookmarks.append(Bookmark(name: name, lat: lat, long: long))
    saveBookmarks(bookmarks)
    successVibrate()
    return true
}

func BookMarkRetrieve() -> [[String: Any]] {
    let sharedUserDefaults = UserDefaults(suiteName: sharedUserDefaultsSuiteName)
    return sharedUserDefaults?.array(forKey: bookmarksKey) as? [[String: Any]] ?? []
}

// MARK: - Search & sort

private let vietnameseLocale = Locale(identifier: "vi_VN")

/// "Bến Thành" -> "ben thanh", "Đà Lạt" -> "da lat" so searching works without accents.
func foldForSearch(_ text: String) -> String {
    text.replacingOccurrences(of: "đ", with: "d")
        .replacingOccurrences(of: "Đ", with: "D")
        .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: vietnameseLocale)
}

enum BookmarkSort: String, CaseIterable, Identifiable {
    case az, za, newest, oldest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .az: return "Tên A → Z"
        case .za: return "Tên Z → A"
        case .newest: return "Mới dùng gần nhất"
        case .oldest: return "Cũ nhất"
        }
    }

    var icon: String {
        switch self {
        case .az: return "textformat.abc"
        case .za: return "textformat.abc"
        case .newest: return "clock.arrow.circlepath"
        case .oldest: return "clock"
        }
    }
}

func filterAndSort(_ bookmarks: [Bookmark], search: String, sort: BookmarkSort) -> [Bookmark] {
    let query = foldForSearch(search.trimmingCharacters(in: .whitespacesAndNewlines))
    let filtered = query.isEmpty ? bookmarks : bookmarks.filter {
        foldForSearch($0.displayName).contains(query)
    }

    func nameOrder(_ a: Bookmark, _ b: Bookmark) -> ComparisonResult {
        a.name.compare(b.name, options: [.caseInsensitive, .numeric], range: nil, locale: vietnameseLocale)
    }

    switch sort {
    case .az, .za:
        return filtered.sorted { a, b in
            // Unnamed locations always go to the bottom, newest first.
            if a.isUnnamed != b.isUnnamed { return !a.isUnnamed }
            if a.isUnnamed { return a.date > b.date }
            let r = nameOrder(a, b)
            if r == .orderedSame { return a.date > b.date }
            return sort == .az ? r == .orderedAscending : r == .orderedDescending
        }
    case .newest:
        return filtered.sorted { $0.date > $1.date }
    case .oldest:
        return filtered.sorted { $0.date < $1.date }
    }
}

// MARK: - Mika's LocSim import

func isThereAnyMika() -> Bool {
    let plistPath = "/var/mobile/Library/Preferences/com.mika.LocationSimulation.plist"
    guard FileManager.default.fileExists(atPath: plistPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    else { return false }
    return plist["datas"] is [Any]
}

func importMika() {
    let plistPath = "/var/mobile/Library/Preferences/com.mika.LocationSimulation.plist"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let datasArray = plist["datas"] as? [[String: Any]]
    else { return }

    var bookmarks = loadBookmarks()
    for dataDict in datasArray {
        if let la = (dataDict["la"] as? NSNumber)?.doubleValue,
           let lo = (dataDict["lo"] as? NSNumber)?.doubleValue {
            bookmarks.append(Bookmark(name: dataDict["remark"] as? String ?? "", lat: la, long: lo, date: 0))
        }
    }
    saveBookmarks(bookmarks)
    UIApplication.shared.alert(title: "Xong!", body: "Đã nhập các vị trí đã lưu từ LocSim của Mika.")
}
