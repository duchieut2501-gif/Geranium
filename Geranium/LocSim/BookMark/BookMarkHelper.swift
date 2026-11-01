//
//  BookMarkHelper.swift
//  Location Simulator
//
//  Storage for History (every fake) and Bookmarks, search/sort, text export/import.
//

import Foundation
import SwiftUI
import CoreLocation

let sharedUserDefaultsSuiteName = "group.live.cclerc.geraniumBookmarks"

// MARK: - Model

struct Bookmark: Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var long: Double
    /// timeIntervalSince1970. 0 = unknown.
    var date: Double
    /// Name of the list (folder) it belongs to. "" = not in a list. Bookmarks only.
    var folder: String = ""

    init(id: String = UUID().uuidString, name: String, lat: Double, long: Double,
         date: Double = Date().timeIntervalSince1970, folder: String = "") {
        self.id = id; self.name = name; self.lat = lat; self.long = long; self.date = date; self.folder = folder
    }

    init?(dict: [String: Any]) {
        guard let lat = (dict["lat"] as? NSNumber)?.doubleValue,
              let long = (dict["long"] as? NSNumber)?.doubleValue else { return nil }
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.name = dict["name"] as? String ?? ""
        self.lat = lat
        self.long = long
        self.date = (dict["date"] as? NSNumber)?.doubleValue ?? 0
        self.folder = dict["folder"] as? String ?? ""
    }

    var dict: [String: Any] { ["id": id, "name": name, "lat": lat, "long": long, "date": date, "folder": folder] }
    var isUnnamed: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayName: String { isUnnamed ? "Unnamed" : name }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: long) }
}

enum LocList: String {
    case history, bookmarks

    /// "bookmarks" key is shared with the Apple Maps "save location" extension.
    var key: String { self == .history ? "history" : "bookmarks" }
    var title: String { self == .history ? "Lịch sử" : "Đánh dấu" }
    var fileTag: String { self == .history ? "LichSu" : "DanhDau" }
}

// MARK: - Storage

private var store: UserDefaults? { UserDefaults(suiteName: sharedUserDefaultsSuiteName) }

func loadList(_ list: LocList) -> [Bookmark] {
    migrateIfNeeded()
    let raw = store?.array(forKey: list.key) as? [[String: Any]] ?? []
    let items = raw.compactMap { Bookmark(dict: $0) }
    if raw.contains(where: { $0["id"] == nil }) { saveList(list, items) }   // persist generated ids once
    return items
}

extension Notification.Name {
    static let locListChanged = Notification.Name("locListChanged")
}

func saveList(_ list: LocList, _ items: [Bookmark]) {
    store?.set(items.map { $0.dict }, forKey: list.key)
    store?.synchronize()
    NotificationCenter.default.post(name: .locListChanged, object: list.rawValue)
}

/// v2: everything auto-saved before (date > 0) moves to History; imported/old entries stay in Bookmarks.
private func migrateIfNeeded() {
    guard let s = store, !s.bool(forKey: "migratedV2") else { return }
    s.set(true, forKey: "migratedV2")
    let raw = s.array(forKey: LocList.bookmarks.key) as? [[String: Any]] ?? []
    let all = raw.compactMap { Bookmark(dict: $0) }
    let toHistory = all.filter { $0.date > 0 }
    let keep = all.filter { $0.date <= 0 }
    let oldHistory = (s.array(forKey: LocList.history.key) as? [[String: Any]] ?? []).compactMap { Bookmark(dict: $0) }
    s.set((oldHistory + toHistory).map { $0.dict }, forKey: LocList.history.key)
    s.set(keep.map { $0.dict }, forKey: LocList.bookmarks.key)
    s.synchronize()
}

private func isNear(_ a: Bookmark, _ lat: Double, _ long: Double, _ meters: CLLocationDistance = 5) -> Bool {
    CLLocation(latitude: a.lat, longitude: a.long).distance(from: CLLocation(latitude: lat, longitude: long)) <= meters
}

/// Every fake is logged in History. A location within 5 m is moved to the top instead of duplicated.
func logToHistory(lat: Double, long: Double, name: String = "") {
    // A saved (bookmarked) place keeps its name in History.
    var name = name
    if name.isEmpty, let saved = loadList(.bookmarks).first(where: { isNear($0, lat, long) && !$0.isUnnamed }) {
        name = saved.name
    }
    var items = loadList(.history)
    let now = Date().timeIntervalSince1970
    if let i = items.firstIndex(where: { isNear($0, lat, long) }) {
        items[i].date = now
        if items[i].isUnnamed && !name.isEmpty { items[i].name = name }
    } else {
        items.append(Bookmark(name: name, lat: lat, long: long, date: now))
    }
    saveList(.history, items)
}

/// Saves a place in Bookmarks. If one already exists within 5 m it is updated (name / list) instead.
/// Returns false when it already existed.
@discardableResult
func addToBookmarks(name: String, lat: Double, long: Double, folder: String = "") -> Bool {
    var items = loadList(.bookmarks)
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanFolder.isEmpty { createFolder(cleanFolder) }
    if let i = items.firstIndex(where: { isNear($0, lat, long) }) {
        if !cleanName.isEmpty { items[i].name = cleanName }
        if !cleanFolder.isEmpty { items[i].folder = cleanFolder }
        saveList(.bookmarks, items)
        return false
    }
    items.append(Bookmark(name: cleanName, lat: lat, long: long, date: Date().timeIntervalSince1970, folder: cleanFolder))
    saveList(.bookmarks, items)
    return true
}

func updateItem(_ list: LocList, id: String, name: String, lat: Double, long: Double, folder: String? = nil) {
    var items = loadList(list)
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    items[i].lat = lat
    items[i].long = long
    if let folder {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { createFolder(f) }
        items[i].folder = f
    }
    saveList(list, items)
}

// MARK: - Lists (folders) inside Bookmarks

private let foldersKey = "folders"

/// All list names, A→Z (Vietnamese order). Includes lists that are still empty.
func loadFolders() -> [String] {
    var names = Set(store?.array(forKey: foldersKey) as? [String] ?? [])
    for b in loadList(.bookmarks) where !b.folder.isEmpty { names.insert(b.folder) }
    return names.sorted { $0.compare($1, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "vi_VN")) == .orderedAscending }
}

private func saveFolders(_ names: [String]) {
    store?.set(names, forKey: foldersKey)
    store?.synchronize()
    NotificationCenter.default.post(name: .locListChanged, object: LocList.bookmarks.rawValue)
}

func createFolder(_ name: String) {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { return }
    var names = store?.array(forKey: foldersKey) as? [String] ?? []
    if !names.contains(n) { names.append(n); saveFolders(names) }
}

func renameFolder(_ old: String, to new: String) {
    let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty, n != old else { return }
    var names = (store?.array(forKey: foldersKey) as? [String] ?? []).filter { $0 != old }
    if !names.contains(n) { names.append(n) }
    saveFolders(names)
    var items = loadList(.bookmarks)
    for i in items.indices where items[i].folder == old { items[i].folder = n }
    saveList(.bookmarks, items)
}

/// Deletes the list. Places inside are kept and moved out of the list.
func deleteFolder(_ name: String) {
    saveFolders((store?.array(forKey: foldersKey) as? [String] ?? []).filter { $0 != name })
    var items = loadList(.bookmarks)
    for i in items.indices where items[i].folder == name { items[i].folder = "" }
    saveList(.bookmarks, items)
}

func deleteItem(_ list: LocList, id: String) {
    var items = loadList(list)
    items.removeAll { $0.id == id }
    saveList(list, items)
}

/// Adds items, skipping duplicates (within 5 m). Returns number added.
@discardableResult
func addItems(_ list: LocList, _ new: [Bookmark]) -> Int {
    var items = loadList(list)
    var added = 0
    for n in new where !items.contains(where: { isNear($0, n.lat, n.long) }) {
        let folder = list == .bookmarks ? n.folder : ""
        if !folder.isEmpty { createFolder(folder) }
        items.append(Bookmark(name: n.name, lat: n.lat, long: n.long,
                              date: n.date > 0 ? n.date : Date().timeIntervalSince1970, folder: folder))
        added += 1
    }
    saveList(list, items)
    return added
}

// MARK: - Search & sort

private let vietnameseLocale = Locale(identifier: "vi_VN")

/// "Bến Thành" -> "ben thanh", "Đà Lạt" -> "da lat"
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
        case .newest: return "Mới nhất"
        case .oldest: return "Cũ nhất"
        }
    }
}

/// Words of a name, accent-free: "Bệnh Viện Bạch Mai - Cổng 1" -> ["benh","vien","bach","mai","cong","1"]
private func words(_ text: String) -> [String] {
    foldForSearch(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// Relevance: 0 = name starts with the query, 1 = every query word starts a word in the name
/// (in order), 2 = every query word starts some word. nil = not a match.
/// Only the START of words counts: "nhi" finds "Nhi TW", not "Bệnh viện".
private func relevance(_ item: Bookmark, queryWords: [String], queryText: String, search: String) -> Int? {
    let nameWords = words(item.displayName)
    let joined = nameWords.joined(separator: " ")
    if joined.hasPrefix(queryText) { return 0 }
    // in-order word prefixes
    var i = 0
    for w in nameWords where i < queryWords.count && w.hasPrefix(queryWords[i]) { i += 1 }
    if i == queryWords.count { return 1 }
    if queryWords.allSatisfy({ q in nameWords.contains { $0.hasPrefix(q) } }) { return 2 }
    // coordinates typed as numbers
    // coordinates, only when a decimal number is typed (e.g. "21.02"), so "2" still means "Cổng 2"
    if search.contains("."),
       String(format: "%.6f, %.6f", item.lat, item.long).hasPrefix(search.trimmingCharacters(in: .whitespaces)) { return 3 }
    return nil
}

func filterAndSort(_ items: [Bookmark], search: String, sort: BookmarkSort) -> [Bookmark] {
    func baseOrder(_ a: Bookmark, _ b: Bookmark) -> Bool {
        switch sort {
        case .az, .za:
            if a.isUnnamed != b.isUnnamed { return !a.isUnnamed }   // Unnamed at the bottom
            if a.isUnnamed { return a.date > b.date }
            let r = a.name.compare(b.name, options: [.caseInsensitive, .numeric], range: nil, locale: vietnameseLocale)
            if r == .orderedSame { return a.date > b.date }
            return sort == .az ? r == .orderedAscending : r == .orderedDescending
        case .newest: return a.date > b.date
        case .oldest: return a.date < b.date
        }
    }

    let queryWords = words(search)
    guard !queryWords.isEmpty else { return items.sorted(by: baseOrder) }
    let queryText = queryWords.joined(separator: " ")

    // Most relevant first, then the chosen order inside each group.
    return items
        .compactMap { item in relevance(item, queryWords: queryWords, queryText: queryText, search: search).map { (item, $0) } }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : baseOrder($0.0, $1.0) }
        .map { $0.0 }
}

// MARK: - Text export / import
//
// # Location Simulator - Đánh dấu - 01/11/2026
// # Tên | Vĩ độ, Kinh độ | Thời gian
// Vincom | 21.049102, 105.915230 | 01/11/2026 17:12
// 21.050011, 105.912300            <- coordinates only is fine too

private let lineDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "dd/MM/yyyy HH:mm"
    return f
}()

func exportText(_ list: LocList, _ items: [Bookmark]) -> String {
    let day = DateFormatter()
    day.dateFormat = "dd/MM/yyyy"
    var lines = ["# Location Simulator - \(list.title) - \(day.string(from: Date()))",
                 "# Tên | Vĩ độ, Kinh độ | Thời gian | Danh sách"]
    let clean: (String) -> String = { $0.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
    for b in items {
        var line = "\(clean(b.displayName)) | " + String(format: "%.7f, %.7f", b.lat, b.long)
        let time = b.date > 0 ? lineDateFormatter.string(from: Date(timeIntervalSince1970: b.date)) : ""
        if !b.folder.isEmpty { line += " | \(time) | \(clean(b.folder))" }
        else if !time.isEmpty { line += " | \(time)" }
        lines.append(line)
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Writes the export to a temporary .txt file (ASCII file name) and returns its URL.
func exportFile(_ list: LocList, _ items: [Bookmark]) -> URL? {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmm"
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocationSimulator-\(list.fileTag)-\(stamp.string(from: Date())).txt")
    do {
        try exportText(list, items).write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch { return nil }
}

private let coordRegex = try! NSRegularExpression(pattern: #"(-?\d{1,3}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)"#)

private func parseCoord(_ s: String) -> (Double, Double)? {
    let ns = s as NSString
    guard let m = coordRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
          let la = Double(ns.substring(with: m.range(at: 1))),
          let lo = Double(ns.substring(with: m.range(at: 2))),
          (-90...90).contains(la), (-180...180).contains(lo) else { return nil }
    return (la, lo)
}

func parseText(_ text: String) -> [Bookmark] {
    var result: [Bookmark] = []
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var name = "", coordPart = line, date: Double = 0, folder = ""
        if parts.count >= 2 {
            name = parts[0]
            coordPart = parts[1]
            if parts.count >= 3, let d = lineDateFormatter.date(from: parts[2]) { date = d.timeIntervalSince1970 }
            if parts.count >= 4 { folder = parts[3] }
        }
        guard let (la, lo) = parseCoord(coordPart) else { continue }
        if name.caseInsensitiveCompare("Unnamed") == .orderedSame { name = "" }
        result.append(Bookmark(name: name, lat: la, long: lo, date: date, folder: folder))
    }
    return result
}
