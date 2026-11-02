//
//  LocSimView.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//  Modified: fixed centre pin + Start button, every fake is auto-saved.
//

import SwiftUI
import CoreLocation
import AlertKit
import PhotosUI
import UIKit

/// Play triangle whose visual centre (centroid) sits exactly in the middle of its frame.
struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let shift = w / 6                       // centroid is 1/3 from the flat side
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + shift, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + shift + w, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + shift, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case map, places
    var id: String { rawValue }
    var title: String { self == .map ? L("Bản đồ", "Map") : L("Danh sách", "List") }
}

enum PlacesTab: String, CaseIterable, Identifiable {
    case bookmarks, history
    var id: String { rawValue }
    var title: String { self == .bookmarks ? L("Đánh dấu", "Bookmarks") : L("Lịch sử", "History") }
    var list: LocList { self == .bookmarks ? .bookmarks : .history }
}

/// App-wide text size (Settings). Default "small" like Mika's LocSim, independent of the iPhone setting.
enum TextSizeOption: String, CaseIterable, Identifiable {
    case small, medium, large, xlarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return L("Nhỏ", "Small")
        case .medium: return L("Vừa", "Medium")
        case .large: return L("Lớn", "Large")
        case .xlarge: return L("Rất lớn", "Extra large")
        }
    }
    var dynamicType: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xlarge: return .xLarge
        }
    }
}

struct LocSimView: View {
    @AppStorage("locAltitude") private var altitude: String = "0"
    @State private var tab: MainTab = .map
    @State private var centerCoordinate: CLLocationCoordinate2D? = nil
    @State private var recenterTick = 0
    @State private var focusCoordinate: EquatableCoordinate? = nil
    @State private var isFaking = false
    @State private var settingsSheet = false
    @State private var placesTab: PlacesTab = .bookmarks
    @State private var zoomLevel: Double = 0.5           // 0 = far out (top), 1 = close in (bottom)
    @State private var zoomRequest: ZoomRequest? = nil
    @State private var savePin: PlaceEdit? = nil
    @AppStorage("textSize") private var textSize: String = TextSizeOption.small.rawValue
    /// "lat,long" of the place being simulated ("" = none). Lists use it to mark that row red.
    @AppStorage("activeLoc") private var activeLoc: String = ""
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @AppStorage("mapType") private var mapType: String = "standard"

    var body: some View {
        NavigationView {
            ZStack {
                mapLayer                                  // kept alive so the map keeps its position
                if tab == .places {
                    VStack(spacing: 0) {
                        Picker("", selection: $placesTab) {
                            ForEach(PlacesTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        LocationListView(list: placesTab.list,
                                         onStart: { item in
                                             fake(wgs: item.coordinate)
                                             focus(CoordTransform.wgs84ToGcj02(item.coordinate))   // map follows, tab stays
                                         },
                                         onShowOnMap: { item in showOnMap(item) })
                            .id(placesTab)
                    }
                    .background(Color(.systemBackground).ignoresSafeArea())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: stop) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 17))
                            .foregroundColor(isFaking ? .red : .secondary)
                            .padding(.leading, 14)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(MainTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { settingsSheet = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 17))
                    }
                }
            }
            .sheet(isPresented: $settingsSheet) {
                CustomizeAppView(onFakeCoordinate: { typed in
                    fake(wgs: CoordTransform.gcj02ToWgs84(typed))
                    focus(typed)
                    tab = .map
                })
            }
        }
        .navigationViewStyle(.stack)
        .id(appLanguage)                                  // rebuild everything when the language changes
        .dynamicTypeSize((TextSizeOption(rawValue: textSize) ?? .small).dynamicType)
        .onChange(of: tab) { newTab in
            if newTab == .places { placesTab = .bookmarks }   // always open on Bookmarks
        }
        .onAppear {
            LocationModel().requestAuthorisation()
            CLLocationManager().requestAlwaysAuthorization()
            AppCustomizer.restoreIconIfNeeded()
            if !activeLoc.isEmpty { isFaking = true }      // simulation keeps running after the app closes
        }
    }

    // MARK: - Map tab

    private var mapLayer: some View {
        mapContent
            .sheet(item: $savePin) { edit in
                PlaceEditView(edit: edit, folders: loadFolders()) { r in
                    let added = addToBookmarks(name: r.name, lat: r.lat, long: r.long, folders: r.folders)
                    AlertKitAPI.present(title: added ? L("Đã lưu vào Đánh dấu", "Saved to Bookmarks") : L("Đã cập nhật trong Đánh dấu", "Updated in Bookmarks"),
                                        icon: .done, style: .iOS17AppleMusic, haptic: .success)
                }
                .dynamicTypeSize((TextSizeOption(rawValue: textSize) ?? .small).dynamicType)
            }
    }

    private var mapContent: some View {
        ZStack {
            CustomMapView(centerCoordinate: $centerCoordinate,
                          recenterTick: recenterTick,
                          focusCoordinate: focusCoordinate,
                          zoomRequest: zoomRequest,
                          onZoomChanged: { zoomLevel = $0 },
                          mapType: mapType)
                .ignoresSafeArea(edges: .bottom)

            CenterPin()

            // Enter coordinates: top-right, under the settings button (away from Play)
            VStack {
                HStack {
                    Spacer()
                    Button(action: enterCoordinates) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    }
                    .padding(.trailing, 10)
                    .padding(.top, 10)
                }
                Spacer()
            }

            // Vertical zoom slider at the right edge: drag down = zoom in, up = zoom out. Centre stays put.
            HStack {
                Spacer()
                ZoomSlider(level: $zoomLevel, onChange: { level in
                    zoomRequest = ZoomRequest(level: level)
                }, onReset: {
                    zoomRequest = ZoomRequest(reset: true)
                })
                .padding(.trailing, 6)
            }

            VStack(spacing: 10) {
                Spacer()
                Text(coordinateText)
                    .font(.footnote.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .onTapGesture {
                        UIPasteboard.general.string = coordinateText
                        AlertKitAPI.present(title: L("Đã sao chép toạ độ", "Coordinates copied"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
                    }
                HStack(alignment: .bottom) {
                    // Play (always available, re-play moves to the new pin) + Stop (grey → red while simulating)
                    HStack(spacing: 14) {
                        Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { startAtPin() } }) {
                            ZStack {
                                Circle().fill(Color(red: 0.96, green: 0.26, blue: 0.21))
                                PlayTriangle()
                                    .fill(Color.white)
                                    .frame(width: 24, height: 27)
                            }
                            .frame(width: 58, height: 58)
                            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        }
                        if isFaking {
                            // Stop pops out to the right of Play, 15% smaller
                            Button(action: stop) {
                                ZStack {
                                    Circle().fill(Color(red: 0.96, green: 0.26, blue: 0.21))
                                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                        .fill(Color.white)
                                        .frame(width: 17, height: 17)
                                }
                                .frame(width: 49, height: 49)
                                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                            }
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.2, anchor: .leading).combined(with: .opacity).combined(with: .offset(x: -30)),
                                removal: .scale(scale: 0.2, anchor: .leading).combined(with: .opacity)))
                        }
                    }
                    Spacer()
                    VStack(spacing: 10) {
                    // Go to my real location
                    Button { recenterTick += 1 } label: {
                        Image(systemName: "location")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var coordinateText: String {
        guard let c = centerCoordinate else { return L("Đang tải bản đồ…", "Loading map…") }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    // MARK: - Actions

    private func startAtPin() {
        guard let center = centerCoordinate, CLLocationCoordinate2DIsValid(center) else {
            UIApplication.shared.alert(body: L("Bản đồ chưa sẵn sàng, thử lại sau giây lát.", "The map is not ready yet, try again in a moment."))
            return
        }
        fake(wgs: CoordTransform.gcj02ToWgs84(center))   // only changes anything inside mainland China
    }

    /// Fakes the location and logs it in History.
    private func fake(wgs: CLLocationCoordinate2D) {
        let location = CLLocation(coordinate: wgs, altitude: Double(altitude) ?? 0,
                                  horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        LocSimManager.startLocSim(location: location)
        isFaking = true
        activeLoc = "\(wgs.latitude),\(wgs.longitude)"
        logToHistory(lat: wgs.latitude, long: wgs.longitude)
        AlertKitAPI.present(title: L("Đã bắt đầu giả lập", "Simulation started"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func enterCoordinates() {
        let alert = UIAlertController(title: L("Giả lập theo toạ độ", "Simulate coordinates"),
                                      message: L("Có thể dán cả cặp \"21.05, 105.91\" vào ô Vĩ độ.", "You can paste a pair like \"21.05, 105.91\" into Latitude."),
                                      preferredStyle: .alert)
        alert.addTextField { f in f.placeholder = L("Vĩ độ (latitude)", "Latitude"); f.keyboardType = .numbersAndPunctuation }
        alert.addTextField { f in f.placeholder = L("Kinh độ (longitude)", "Longitude"); f.keyboardType = .numbersAndPunctuation }
        alert.addAction(UIAlertAction(title: L("Huỷ", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Giả lập", "Simulate"), style: .default) { _ in
            let latText = alert.textFields?[0].text ?? "", longText = alert.textFields?[1].text ?? ""
            let clean: (String) -> String = { $0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces) }
            var la = Double(clean(latText)), lo = Double(clean(longText))
            if lo == nil, let pair = parseText(latText).first { la = pair.lat; lo = pair.long }   // pasted "lat, long"
            guard let la, let lo, (-90...90).contains(la), (-180...180).contains(lo) else {
                UIApplication.shared.alert(body: L("Toạ độ không hợp lệ.", "Invalid coordinates."))
                return
            }
            let typed = CLLocationCoordinate2D(latitude: la, longitude: lo)
            fake(wgs: CoordTransform.gcj02ToWgs84(typed))
            focus(typed)
        })
        presentTop(alert)
    }

    private func savePinToBookmarks() {
        guard let center = centerCoordinate, CLLocationCoordinate2DIsValid(center) else { return }
        let wgs = CoordTransform.gcj02ToWgs84(center)
        savePin = PlaceEdit(mode: .newBookmark, list: .bookmarks, item: Bookmark(name: "", lat: wgs.latitude, long: wgs.longitude))
    }

    private func showOnMap(_ item: Bookmark) {
        focus(CoordTransform.wgs84ToGcj02(item.coordinate))
        tab = .map
    }

    /// Moves the map (resets first so the same spot can be shown again).
    private func focus(_ c: CLLocationCoordinate2D) {
        focusCoordinate = nil
        DispatchQueue.main.async { focusCoordinate = EquatableCoordinate(coordinate: c) }
    }

    private func stop() {
        LocSimManager.stopLocSim()
        withAnimation(.easeInOut(duration: 0.2)) { isFaking = false }
        activeLoc = ""
        AlertKitAPI.present(title: L("Đã dừng giả lập", "Simulation stopped"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }
}

// ===== App customization (icon & name) =====
//
//  AppCustomizer.swift
//  Location Simulator
//
//  Change the home-screen icon (3 built-in icons or a photo) and the display name.
//


enum AppIconChoice: String, CaseIterable, Identifiable {
    case e, i, dColor, eColor, d, h, g, custom   // display order
    var id: String { rawValue }

    /// Alternate icon name in Info.plist (files Icons/<name>.png).
    var alternateName: String? {
        switch self {
        case .e: return "Flore"
        case .i: return "Beta"
        case .dColor: return "PinsColor"
        case .eColor: return "MapColor"
        case .d: return "Bouquet"
        case .h: return "Pin"
        case .g: return "Outline"
        case .custom: return nil
        }
    }

    var title: String {
        switch self {
        case .e: return L("Bản đồ", "Map")
        case .i: return L("Vòng ngắm", "Target")
        case .dColor: return L("Ghim đôi màu", "Two pins (colour)")
        case .eColor: return L("Bản đồ màu", "Map (colour)")
        case .d: return L("Ghim đôi", "Two pins")
        case .h: return L("Ghim đặc", "Solid pin")
        case .g: return L("Ghim nét", "Outline pin")
        case .custom: return L("Ảnh của bạn", "Your photo")
        }
    }

    var preview: UIImage? {
        alternateName.flatMap { UIImage(named: $0) }
    }

    static var builtIn: [AppIconChoice] { [.e, .i, .dColor, .eColor, .d, .h, .g] }
}

enum AppCustomizer {
    static var storedChoice: String {
        get { UserDefaults.standard.string(forKey: "iconChoice") ?? AppIconChoice.e.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "iconChoice") }
    }

    /// Changes saved but not visible until a respring.
    static var pendingRespring: Bool {
        get { UserDefaults.standard.bool(forKey: "pendingRespring") }
        set { UserDefaults.standard.set(newValue, forKey: "pendingRespring") }
    }

    static func respringNow() {
        pendingRespring = false
        DispatchQueue.global().async { _ = RootHelper.rebuildIconCache() }
    }

    /// "Respring now / Later" question.
    static func askRespring(onLater: (() -> Void)? = nil) {
        let alert = UIAlertController(title: L("Cần respring để áp dụng", "Respring needed"),
                                      message: L("Đã lưu thay đổi. Màn hình chính cần khởi động lại (respring) thì tên / biểu tượng mới hiện ra.", "Changes saved. The home screen needs to restart (respring) to show the new name / icon."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Để sau", "Later"), style: .cancel) { _ in onLater?() })
        alert.addAction(UIAlertAction(title: L("Respring ngay", "Respring now"), style: .default) { _ in respringNow() })
        presentTop(alert)
    }

    private static var customIconURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CustomIcon.png")
    }

    static func saveCustomIconCopy(_ image: UIImage) {
        try? resized(image, to: 1024).pngData()?.write(to: customIconURL)
    }

    static func savedCustomIcon() -> UIImage? {
        UIImage(contentsOfFile: customIconURL.path)
    }

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var infoURL: URL { bundleURL.appendingPathComponent("Info.plist") }
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var backupURL: URL { docs.appendingPathComponent("OriginalInfo.plist") }

    static var currentDisplayName: String {
        (readInfo()?["CFBundleDisplayName"] as? String) ?? "Location Simulator"
    }

    // MARK: Built-in icons (no root needed, like Mika's LocSim)

    static func setBuiltIn(_ choice: AppIconChoice, completion: ((Bool) -> Void)? = nil) {
        guard let name = choice.alternateName, UIApplication.shared.supportsAlternateIcons else {
            completion?(false); return
        }
        UIApplication.shared.setAlternateIconName(name) { error in
            DispatchQueue.main.async {
                if error == nil { storedChoice = choice.rawValue }
                completion?(error == nil)
            }
        }
    }

    /// After a respring the system may forget the alternate icon -> put it back.
    static func restoreIconIfNeeded() {
        guard UserDefaults.standard.string(forKey: "iconChoice") != nil else { return }   // user never picked one
        guard let choice = AppIconChoice(rawValue: storedChoice), let name = choice.alternateName else { return }
        if UIApplication.shared.alternateIconName != name {
            UIApplication.shared.setAlternateIconName(name, completionHandler: nil)
        }
    }

    // MARK: Photo icon + display name (needs TrollStore root helper, then respring)

    enum Failure: LocalizedError {
        case readInfo, writeTemp, rootWrite
        var errorDescription: String? {
            switch self {
            case .readInfo: return L("Không đọc được thông tin app.", "Could not read the app info.")
            case .writeTemp: return L("Không ghi được file tạm.", "Could not write a temporary file.")
            case .rootWrite: return L("Không ghi được vào app. App phải được cài bằng TrollStore.", "Could not write into the app. It must be installed with TrollStore.")
            }
        }
    }

    /// Writes the new name and/or photo icon into the app bundle, then resprings.
    static func apply(displayName: String?, photoIcon: UIImage?, completion: @escaping (Error?) -> Void) {
        let work = {
            do {
                try applyNow(displayName: displayName, photoIcon: photoIcon)
                pendingRespring = true
                completion(nil)
            } catch {
                completion(error)
            }
        }
        if photoIcon != nil {
            // The primary icon is only shown when no alternate icon is active.
            if UIApplication.shared.alternateIconName != nil {
                UIApplication.shared.setAlternateIconName(nil) { _ in DispatchQueue.main.async(execute: work) }
            } else {
                work()
            }
        } else {
            work()
        }
    }

    private static func applyNow(displayName: String?, photoIcon: UIImage?) throws {
        guard var info = readInfo() else { throw Failure.readInfo }
        let fm = FileManager.default

        if !fm.fileExists(atPath: backupURL.path), let original = try? Data(contentsOf: infoURL) {
            try? original.write(to: backupURL)
        }

        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            info["CFBundleDisplayName"] = name
        }

        if let image = photoIcon {
            // New file name each time so SpringBoard does not keep the old cached icon.
            let base = "UserIcon\(Int(Date().timeIntervalSince1970))"
            let sizes: [(suffix: String, px: CGFloat)] = [
                ("60x60@2x.png", 120), ("60x60@3x.png", 180),
                ("76x76@2x~ipad.png", 152), ("83.5x83.5@2x~ipad.png", 167),
            ]
            for s in sizes {
                guard let data = resized(image, to: s.px).pngData() else { throw Failure.writeTemp }
                let tmp = fm.temporaryDirectory.appendingPathComponent(base + s.suffix)
                do { try data.write(to: tmp) } catch { throw Failure.writeTemp }
                let dest = bundleURL.appendingPathComponent(base + s.suffix)
                _ = RootHelper.copy(from: tmp, to: dest)
                guard fm.fileExists(atPath: dest.path) else { throw Failure.rootWrite }
            }
            let primary: [String: Any] = [
                "CFBundleIconFiles": [base + "60x60", base + "76x76", base + "83.5x83.5"],
                "UIPrerenderedIcon": false,
            ]
            for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
                var icons = info[key] as? [String: Any] ?? [:]
                icons["CFBundlePrimaryIcon"] = primary   // drops CFBundleIconName (asset catalog)
                info[key] = icons
            }
            storedChoice = AppIconChoice.custom.rawValue
        }

        try writeInfo(info)
    }

    /// Puts back the original Info.plist (original name + icon D), then resprings.
    static func resetToDefault(completion: @escaping (Error?) -> Void) {
        guard let original = try? Data(contentsOf: backupURL) else {
            setBuiltIn(.e) { _ in completion(nil) }
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Info.plist")
            try original.write(to: tmp)
            _ = RootHelper.removeItem(at: infoURL)
            _ = RootHelper.copy(from: tmp, to: infoURL)
            guard FileManager.default.fileExists(atPath: infoURL.path) else { throw Failure.rootWrite }
            storedChoice = AppIconChoice.e.rawValue
            pendingRespring = true
            completion(nil)
        } catch {
            completion(error)
        }
    }

    // MARK: Helpers

    private static func readInfo() -> [String: Any]? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private static func writeInfo(_ info: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Info.plist")
        do { try data.write(to: tmp) } catch { throw Failure.writeTemp }
        _ = RootHelper.removeItem(at: infoURL)
        _ = RootHelper.copy(from: tmp, to: infoURL)
        guard let written = try? Data(contentsOf: infoURL), written == data else { throw Failure.rootWrite }
    }

    static func resized(_ image: UIImage, to px: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        }
    }
}


// MARK: - Customize screen (icon + name)


struct CustomizeAppView: View {
    @Environment(\.dismiss) var dismiss
    var onFakeCoordinate: ((CLLocationCoordinate2D) -> Void)? = nil
    @AppStorage("locAltitude") private var altitude: String = "0"
    @AppStorage("textSize") private var textSize: String = TextSizeOption.small.rawValue
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @AppStorage("mapType") private var mapType: String = "standard"
    @State private var manualLat = ""
    @State private var manualLong = ""
    @State private var choice = AppIconChoice(rawValue: AppCustomizer.storedChoice) ?? .e
    @State private var name = AppCustomizer.currentDisplayName
    @State private var originalName = AppCustomizer.currentDisplayName
    @State private var cropPhoto: PickedPhoto? = nil    // photo waiting to be cropped
    @State private var croppedIcon: UIImage? = nil      // final square icon (not applied yet)
    @State private var savedCustom: UIImage? = AppCustomizer.savedCustomIcon()   // kept in the app, even if the photo is deleted
    @State private var showPicker = false
    @State private var busy = false
    @State private var pending = AppCustomizer.pendingRespring

    private var nameChanged: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && n != originalName
    }

    var body: some View {
        NavigationView {
            Form {
                if pending {
                    Section {
                        Button {
                            AppCustomizer.respringNow()
                        } label: {
                            Label(L("Respring ngay để áp dụng", "Respring now to apply"), systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text(L("Có thay đổi tên / biểu tượng chưa áp dụng. Bấm để respring, hoặc để sau: thay đổi sẽ hiện ra lần respring hoặc khởi động lại máy tiếp theo.", "Name / icon changes are waiting. Tap to respring, or later: they will appear after the next respring or restart."))
                    }
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(AppIconChoice.builtIn) { option in
                            iconTile(image: option.preview, title: option.title, selected: choice == option && croppedIcon == nil) {
                                croppedIcon = nil
                                AppCustomizer.setBuiltIn(option) { ok in
                                    if ok { choice = option }
                                    else { UIApplication.shared.alert(body: L("Không đổi được biểu tượng.", "Could not change the icon.")) }
                                }
                            }
                        }
                        iconTile(image: croppedIcon ?? savedCustom, title: L("Ảnh của bạn", "Your photo"), selected: croppedIcon != nil || choice == .custom, placeholder: "photo.badge.plus") {
                            showPicker = true
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(L("Biểu tượng", "Icon"))
                } footer: {
                    Text(L("7 mẫu có sẵn đổi ngay. \"Ảnh của bạn\": chọn ảnh, cắt cho vừa khung rồi bấm Áp dụng ở dưới.", "Built-in icons change instantly. \"Your photo\": pick a photo, crop it, then tap Apply below."))
                }

                Section {
                    TextField(L("Tên hiển thị", "Display name"), text: $name)
                        .disableAutocorrection(true)
                } header: {
                    Text(L("Tên dưới biểu tượng", "Name under the icon"))
                } footer: {
                    Text(L("Tên ngắn (khoảng 12 ký tự) sẽ hiện đầy đủ, tên dài sẽ bị cắt bớt.", "Short names (about 12 characters) show in full; longer names get cut off."))
                }

                Section {
                    Button {
                        applyChanges()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(L("Áp dụng", "Apply")).bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || (!nameChanged && croppedIcon == nil))
                } footer: {
                    Text(L("Đổi tên hoặc dùng ảnh riêng cần respring mới hiện ra. App sẽ hỏi bạn respring ngay hay để sau.", "A new name or photo icon needs a respring to show. The app will ask: now or later."))
                }

                Section {
                    Picker("Language", selection: $appLanguage) {
                        Text("English").tag("en")
                        Text("Tiếng Việt").tag("vi")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L("Ngôn ngữ / Language", "Language / Ngôn ngữ"))
                }

                Section {
                    Picker(L("Kiểu bản đồ", "Map type"), selection: $mapType) {
                        Text(L("Thường", "Standard")).tag("standard")
                        Text(L("Vệ tinh", "Satellite")).tag("satellite")
                        Text(L("Lai", "Hybrid")).tag("hybrid")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L("Bản đồ (Apple Maps)", "Map (Apple Maps)"))
                } footer: {
                    Text(L("Lai = ảnh vệ tinh có tên đường.", "Hybrid = satellite imagery with street names."))
                }

                Section {
                    Picker(L("Cỡ chữ", "Text size"), selection: $textSize) {
                        ForEach(TextSizeOption.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L("Cỡ chữ", "Text size"))
                }

                Section {
                    HStack {
                        Text(L("Độ cao (m)", "Altitude (m)"))
                        Spacer()
                        TextField("0", text: $altitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                } header: {
                    Text(L("Độ cao", "Altitude"))
                }

                Section {
                    Button(L("Khôi phục mặc định", "Restore defaults"), role: .destructive) {
                        UIApplication.shared.confirmAlert(title: L("Khôi phục mặc định?", "Restore defaults?"),
                                                          body: L("Tên về \"Location Simulator\", biểu tượng về mẫu Bản đồ.", "Name back to \"Location Simulator\", icon back to Map."),
                                                          onOK: {
                            AppCustomizer.resetToDefault { error in
                                if let error { UIApplication.shared.alert(body: error.localizedDescription) }
                                else if AppCustomizer.pendingRespring { pending = true; AppCustomizer.askRespring() }
                            }
                        }, noCancel: false)
                    }
                }
            }
            .navigationTitle(L("Cài đặt", "Settings"))
            .dynamicTypeSize((TextSizeOption(rawValue: textSize) ?? .small).dynamicType)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Đóng", "Close")) { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { image in
                    showPicker = false
                    guard let image else { return }
                    // Shrink big camera photos first (keeps the crop screen fast), then open the crop screen
                    DispatchQueue.global(qos: .userInitiated).async {
                        let small = downscaled(image, maxSide: 2000)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cropPhoto = PickedPhoto(image: small) }
                    }
                }
            }
            .fullScreenCover(item: $cropPhoto) { photo in
                IconCropView(image: photo.image) { result in
                    cropPhoto = nil
                    if let result { croppedIcon = result }
                }
            }
        }
    }

    private func fakeManual() {
        let clean: (String) -> String = { $0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces) }
        var la = Double(clean(manualLat)), lo = Double(clean(manualLong))
        if lo == nil, let pair = parseText(manualLat).first { la = pair.lat; lo = pair.long }   // pasted "lat, long"
        guard let la, let lo, (-90...90).contains(la), (-180...180).contains(lo) else {
            UIApplication.shared.alert(body: L("Toạ độ không hợp lệ.", "Invalid coordinates."))
            return
        }
        dismiss()
        onFakeCoordinate?(CLLocationCoordinate2D(latitude: la, longitude: lo))
    }

    private func applyChanges() {
        busy = true
        AppCustomizer.apply(displayName: nameChanged ? name : nil, photoIcon: croppedIcon) { error in
            DispatchQueue.main.async {
                busy = false
                if let error {
                    UIApplication.shared.alert(body: error.localizedDescription)
                } else {
                    if let icon = croppedIcon {
                        AppCustomizer.saveCustomIconCopy(icon)   // own copy, independent of the photo library
                        savedCustom = icon
                    }
                    pending = true
                    AppCustomizer.askRespring()
                }
            }
        }
    }

    @ViewBuilder
    private func iconTile(image: UIImage?, title: String, selected: Bool, placeholder: String = "app",
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemFill)
                        Image(systemName: placeholder).font(.title2).foregroundColor(.accentColor)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
                        .padding(-4)
                )
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

struct PickedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Upright copy with the longest side at most `maxSide` pixels.
func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
    let w = image.size.width * image.scale, h = image.size.height * image.scale
    let k = min(1, maxSide / max(w, h))
    let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}

// MARK: - Photo picker

struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil); return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.onPick(object as? UIImage) }
            }
        }
    }
}

// MARK: - Crop (square, rounded preview)

struct IconCropView: View {
    let image: UIImage
    var onDone: (UIImage?) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, 340)
            let base = side / min(image.size.width, image.size.height)   // fill the square at scale 1
            VStack(spacing: 24) {
                Spacer()
                Text(L("Kéo và chụm 2 ngón để cắt ảnh", "Drag and pinch to crop"))
                    .foregroundColor(.white.opacity(0.8))
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: image.size.width * base * scale, height: image.size.height * base * scale)
                        .offset(offset)
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = clamp(CGSize(width: lastOffset.width + v.translation.width,
                                                  height: lastOffset.height + v.translation.height),
                                           side: side, base: base)
                        }
                        .onEnded { _ in lastOffset = offset }
                        .simultaneously(with:
                            MagnificationGesture()
                                .onChanged { m in
                                    scale = min(max(lastScale * m, 1), 6)
                                    offset = clamp(offset, side: side, base: base)
                                }
                                .onEnded { _ in lastScale = scale; lastOffset = offset }
                        )
                )

                // Small home-screen-size preview
                HStack(spacing: 14) {
                    Text(L("Xem trước:", "Preview:")).foregroundColor(.white.opacity(0.8)).font(.footnote)
                    Image(uiImage: render(side: side, base: base, px: 180))
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                }
                Spacer()
                HStack {
                    Button(L("Huỷ", "Cancel")) { onDone(nil) }
                        .foregroundColor(.white)
                    Spacer()
                    Button(L("Dùng ảnh này", "Use this photo")) { onDone(render(side: side, base: base, px: 1024)) }
                        .font(.headline)
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func clamp(_ o: CGSize, side: CGFloat, base: CGFloat) -> CGSize {
        let w = image.size.width * base * scale, h = image.size.height * base * scale
        let mx = max(0, (w - side) / 2), my = max(0, (h - side) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    /// Renders exactly what is inside the square into a px×px opaque image.
    /// (iOS rounds the corners of home-screen icons itself.)
    private func render(side: CGFloat, base: CGFloat, px: CGFloat) -> UIImage {
        let k = base * scale                                   // display points per image point
        let cropSize = side / k                                // in image points
        let cx = image.size.width / 2 - offset.width / k
        let cy = image.size.height / 2 - offset.height / k
        let origin = CGPoint(x: cx - cropSize / 2, y: cy - cropSize / 2)
        let f = px / cropSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
            image.draw(in: CGRect(x: -origin.x * f, y: -origin.y * f,
                                  width: image.size.width * f, height: image.size.height * f))
        }
    }
}
