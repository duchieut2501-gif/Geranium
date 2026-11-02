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

/// App language (Settings). Default English.
var appIsVietnamese: Bool { UserDefaults.standard.string(forKey: "appLanguage") == "vi" }
/// Picks the Vietnamese or English text.
func L(_ vi: String, _ en: String) -> String { appIsVietnamese ? vi : en }

// MARK: - Model

struct Bookmark: Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var long: Double
    /// timeIntervalSince1970. 0 = unknown.
    var date: Double
    /// Lists (folders) it belongs to — can be several. Bookmarks only.
    var folders: [String] = []
    /// Shown in "Yêu thích" at the top of Bookmarks.
    var favorite: Bool = false

    init(id: String = UUID().uuidString, name: String, lat: Double, long: Double,
         date: Double = Date().timeIntervalSince1970, folders: [String] = [], favorite: Bool = false) {
        self.id = id; self.name = name; self.lat = lat; self.long = long; self.date = date
        self.folders = folders; self.favorite = favorite
    }

    init?(dict: [String: Any]) {
        guard let lat = (dict["lat"] as? NSNumber)?.doubleValue,
              let long = (dict["long"] as? NSNumber)?.doubleValue else { return nil }
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.name = dict["name"] as? String ?? ""
        self.lat = lat
        self.long = long
        self.date = (dict["date"] as? NSNumber)?.doubleValue ?? 0
        if let arr = dict["folders"] as? [String] { self.folders = arr }
        else if let one = dict["folder"] as? String, !one.isEmpty { self.folders = [one] }   // older single-list data
        self.favorite = dict["fav"] as? Bool ?? false
    }

    var dict: [String: Any] {
        ["id": id, "name": name, "lat": lat, "long": long, "date": date, "folders": folders, "fav": favorite]
    }
    var isUnnamed: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayName: String { isUnnamed ? "Unnamed" : name }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: long) }
}

enum LocList: String {
    case history, bookmarks

    /// "bookmarks" key is shared with the Apple Maps "save location" extension.
    var key: String { self == .history ? "history" : "bookmarks" }
    var title: String { self == .history ? L("Lịch sử", "History") : L("Đánh dấu", "Bookmarks") }
    var fileTag: String { self == .history ? "LichSu" : "DanhDau" }
}

// MARK: - Storage

/// All saved places live in ONE file at a fixed path. It does not depend on how iOS registers the app,
/// so renaming / changing the icon + respring (which re-registers the app) can no longer lose data.
final class FileStore {
    static let shared = FileStore()
    private var dict: [String: Any] = [:]
    private let lock = NSLock()
    let url: URL

    private init() {
        let fm = FileManager.default
        let fixed = URL(fileURLWithPath: "/var/mobile/Library/LocationSimulator/data.plist")
        let fallback = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationSimulator/data.plist")
        var chosen = fixed
        do {
            try fm.createDirectory(at: fixed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let probe = fixed.deletingLastPathComponent().appendingPathComponent(".probe")
            try Data().write(to: probe); try? fm.removeItem(at: probe)
        } catch {
            try? fm.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
            chosen = fallback
        }
        url = chosen

        if let data = try? Data(contentsOf: url),
           let p = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            dict = p
        } else if let old = UserDefaults(suiteName: sharedUserDefaultsSuiteName) {
            // First run of this version: copy what the old shared storage had.
            for key in ["bookmarks", "history", "folders", "favFolders"] {
                if let v = old.object(forKey: key) { dict[key] = v }
            }
            write()
        }
    }

    func array(forKey key: String) -> [Any]? {
        lock.lock(); defer { lock.unlock() }
        return dict[key] as? [Any]
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        dict[key] = value
        lock.unlock()
        write()
    }

    func synchronize() {}

    private func write() {
        lock.lock(); let snapshot = dict; lock.unlock()
        if let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private var store: FileStore? { FileStore.shared }

func loadList(_ list: LocList) -> [Bookmark] {
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

/// Saves a place in Bookmarks. If one already exists within 5 m it is updated (name, lists added) instead.
/// Returns false when it already existed.
@discardableResult
func addToBookmarks(name: String, lat: Double, long: Double, folders: [String] = []) -> Bool {
    var items = loadList(.bookmarks)
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let lists = cleanLists(folders)
    lists.forEach { createFolder($0) }
    if let i = items.firstIndex(where: { isNear($0, lat, long) }) {
        if !cleanName.isEmpty { items[i].name = cleanName }
        for f in lists where !items[i].folders.contains(f) { items[i].folders.append(f) }
        saveList(.bookmarks, items)
        return false
    }
    items.append(Bookmark(name: cleanName, lat: lat, long: long, date: Date().timeIntervalSince1970, folders: lists))
    saveList(.bookmarks, items)
    return true
}

func cleanLists(_ names: [String]) -> [String] {
    var out: [String] = []
    for n in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !n.isEmpty && !out.contains(n) { out.append(n) }
    return out
}

func setFavorite(id: String, _ on: Bool) {
    var items = loadList(.bookmarks)
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].favorite = on
    saveList(.bookmarks, items)
}

func updateItem(_ list: LocList, id: String, name: String, lat: Double, long: Double, folders: [String]? = nil) {
    var items = loadList(list)
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    items[i].lat = lat
    items[i].long = long
    if let folders {
        let lists = cleanLists(folders)
        lists.forEach { createFolder($0) }
        items[i].folders = lists
    }
    saveList(list, items)
}

// MARK: - Lists (folders) inside Bookmarks

private let foldersKey = "folders"

private let favFoldersKey = "favFolders"

/// All list names: favourite lists first, then the rest, each A→Z. Includes lists that are still empty.
func loadFolders() -> [String] {
    var names = Set(store?.array(forKey: foldersKey) as? [String] ?? [])
    for b in loadList(.bookmarks) { b.folders.forEach { names.insert($0) } }
    let fav = favouriteFolders()
    let az: (String, String) -> Bool = {
        $0.compare($1, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "vi_VN")) == .orderedAscending
    }
    return names.filter { fav.contains($0) }.sorted(by: az) + names.filter { !fav.contains($0) }.sorted(by: az)
}

func favouriteFolders() -> Set<String> { Set(store?.array(forKey: favFoldersKey) as? [String] ?? []) }

func setFavouriteFolder(_ name: String, _ on: Bool) {
    var fav = favouriteFolders()
    if on { fav.insert(name) } else { fav.remove(name) }
    store?.set(Array(fav), forKey: favFoldersKey)
    store?.synchronize()
    NotificationCenter.default.post(name: .locListChanged, object: LocList.bookmarks.rawValue)
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
    if favouriteFolders().contains(old) { setFavouriteFolder(old, false); setFavouriteFolder(n, true) }
    var names = (store?.array(forKey: foldersKey) as? [String] ?? []).filter { $0 != old }
    if !names.contains(n) { names.append(n) }
    saveFolders(names)
    var items = loadList(.bookmarks)
    for i in items.indices where items[i].folders.contains(old) {
        items[i].folders = cleanLists(items[i].folders.map { $0 == old ? n : $0 })
    }
    saveList(.bookmarks, items)
}

/// Creates or edits a list in one go: optional rename, then the places with `memberIDs` are put in it,
/// and places that were in it but are no longer ticked are moved out (not deleted).
func saveFolder(original: String?, name: String, memberIDs: Set<String>, keepOtherLists: Bool = false) {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { return }
    if let old = original, old != n { renameFolder(old, to: n) } else { createFolder(n) }
    var items = loadList(.bookmarks)
    for i in items.indices {
        if memberIDs.contains(items[i].id) {
            if !items[i].folders.contains(n) {
                // Newly added: moved here, or also kept in its other lists when that box is ticked.
                if keepOtherLists { items[i].folders.append(n) } else { items[i].folders = [n] }
            }
        } else {
            items[i].folders.removeAll { $0 == n }
        }
    }
    saveList(.bookmarks, items)
}

/// Deletes the list. Places inside are kept and moved out of the list.
func deleteFolder(_ name: String) {
    setFavouriteFolder(name, false)
    saveFolders((store?.array(forKey: foldersKey) as? [String] ?? []).filter { $0 != name })
    var items = loadList(.bookmarks)
    for i in items.indices { items[i].folders.removeAll { $0 == name } }
    saveList(.bookmarks, items)
}

/// Removes History entries older than `days` (nil = everything). Returns how many were removed.
@discardableResult
func clearHistory(olderThanDays days: Int?) -> Int {
    let items = loadList(.history)
    let keep: [Bookmark]
    if let days {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        keep = items.filter { $0.date >= cutoff }
    } else {
        keep = []
    }
    saveList(.history, keep)
    return items.count - keep.count
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
        let lists = list == .bookmarks ? cleanLists(n.folders) : []
        lists.forEach { createFolder($0) }
        items.append(Bookmark(name: n.name, lat: n.lat, long: n.long,
                              date: n.date > 0 ? n.date : Date().timeIntervalSince1970,
                              folders: lists, favorite: list == .bookmarks && n.favorite))
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
        case .az: return L("Tên A → Z", "Name A → Z")
        case .za: return L("Tên Z → A", "Name Z → A")
        case .newest: return L("Mới nhất", "Newest")
        case .oldest: return L("Cũ nhất", "Oldest")
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
    f.dateFormat = "dd/MM/yyyy HH:mm:ss"
    return f
}()

/// Older exports have no seconds.
private let lineDateFormatterNoSeconds: DateFormatter = {
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
                 L("# Tên | Vĩ độ, Kinh độ | Thời gian | Danh sách (cách nhau bằng ;) | ★ = Yêu thích", "# Name | Latitude, Longitude | Time | Lists (separated by ;) | ★ = Favourite")]
    let clean: (String) -> String = { $0.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
    if list == .bookmarks {
        let favs = favouriteFolders().filter { f in items.contains { $0.folders.contains(f) } }.sorted()
        if !favs.isEmpty { lines.append("#★ " + favs.map(clean).joined(separator: "; ")) }
    }
    for b in items {
        var line = "\(clean(b.displayName)) | " + String(format: "%.7f, %.7f", b.lat, b.long)
        let time = b.date > 0 ? lineDateFormatter.string(from: Date(timeIntervalSince1970: b.date)) : ""
        let lists = b.folders.map(clean).map { $0.replacingOccurrences(of: ";", with: ",") }.joined(separator: "; ")
        if b.favorite { line += " | \(time) | \(lists) | ★" }
        else if !lists.isEmpty { line += " | \(time) | \(lists)" }
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

/// Favourite list names from a "#★ A; B" line in an exported file.
func parseFavouriteFolders(_ text: String) -> [String] {
    for line in text.components(separatedBy: .newlines) where line.hasPrefix("#★") {
        return cleanLists(String(line.dropFirst(2)).components(separatedBy: ";"))
    }
    return []
}

func parseText(_ text: String) -> [Bookmark] {
    var result: [Bookmark] = []
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var name = "", coordPart = line, date: Double = 0, lists: [String] = [], fav = false
        if parts.count >= 2 {
            name = parts[0]
            coordPart = parts[1]
            if parts.count >= 3, let d = lineDateFormatter.date(from: parts[2]) ?? lineDateFormatterNoSeconds.date(from: parts[2]) {
                date = d.timeIntervalSince1970
            }
            if parts.count >= 4 { lists = cleanLists(parts[3].components(separatedBy: ";")) }
            if parts.count >= 5 { fav = parts[4].contains("★") || foldForSearch(parts[4]).contains("yeu thich") }
        }
        guard let (la, lo) = parseCoord(coordPart) else { continue }
        if name.caseInsensitiveCompare("Unnamed") == .orderedSame { name = "" }
        result.append(Bookmark(name: name, lat: la, long: lo, date: date, folders: lists, favorite: fav))
    }
    return result
}
