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
import MapKit

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
    @State private var northTick = 0
    @State private var mapHeading: Double = 0
    /// Compass shows only while the map is turned away from north.
    private var mapRotated: Bool { let h = mapHeading.truncatingRemainder(dividingBy: 360); return min(abs(h), 360 - abs(h)) > 0.5 }
    @State private var focusCoordinate: EquatableCoordinate? = nil
    @State private var isFaking = false
    @State private var settingsSheet = false
    @State private var placesTab: PlacesTab = .bookmarks
    @State private var zoomLevel: Double = 0.5           // 0 = far out (top), 1 = close in (bottom)
    @State private var zoomRequest: ZoomRequest? = nil
    @State private var savePin: PlaceEdit? = nil
    @State private var hopSheet = false
    @State private var routeSheet = false
    @State private var addNextSheet = false
    @ObservedObject private var route = RouteRunner.shared
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
            .sheet(isPresented: $hopSheet) {
                HopSetupView(pinCoordinate: centerCoordinate.map { CoordTransform.gcj02ToWgs84($0) }) { points, ms, random in
                    RouteRunner.shared.stop()
                    HopRunner.shared.start(points: points, intervalMs: ms, random: random)
                    withAnimation(.easeInOut(duration: 0.2)) { isFaking = true }
                    AlertKitAPI.present(title: L("Bắt đầu nhảy cóc", "Hopping started"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
                }
            }
            .sheet(isPresented: $addNextSheet) {
                AddNextPointsView(pinCoordinate: centerCoordinate.map { CoordTransform.gcj02ToWgs84($0) }) { pts in
                    appendToTrip(pts)
                }
            }
            .sheet(isPresented: $routeSheet) {
                RouteSetupView(pinCoordinate: centerCoordinate.map { CoordTransform.gcj02ToWgs84($0) }) { path, marks, kmh, vary, wait, end in
                    HopRunner.shared.stop()
                    RouteRunner.shared.start(path: path, stopMarks: marks, speedKmh: kmh, vary: vary, stopSeconds: wait, end: end)
                    if let first = path.first { focus(CoordTransform.wgs84ToGcj02(first)) }
                    withAnimation(.easeInOut(duration: 0.2)) { isFaking = true }
                    AlertKitAPI.present(title: L("Bắt đầu di chuyển", "Trip started"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
                }
            }
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
                          mapType: mapType,
                          northTick: northTick,
                          onHeadingChanged: { mapHeading = $0 },
                          routePath: route.displayPath,
                          routeID: route.pathID)
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
                // Hop between several points: under the keyboard button
                HStack {
                    Spacer()
                    Button { hopSheet = true } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    }
                    .padding(.trailing, 10)
                }
                // Follow roads A → stops → B: under the hop button
                HStack {
                    Spacer()
                    Button { routeSheet = true } label: {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    }
                    .padding(.trailing, 10)
                }
                HopBanner(onStop: stop)
                    .padding(.horizontal, 12)
                RouteBanner(onStop: stop, onAddPin: addPinToTrip, onAddFromList: { addNextSheet = true })
                    .padding(.horizontal, 12)
                Spacer()
            }

            // Search Apple Maps: top-left, left of the keyboard button
            VStack {
                MapSearchBar(near: centerCoordinate) { c, _ in focus(c) }
                    .padding(.leading, 10)
                    .padding(.trailing, 64)
                    .padding(.top, 10)
                Spacer()
            }
            .zIndex(2)

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
                    if !route.isActive {
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
                    }
                    Spacer()
                    VStack(spacing: 10) {
                    // Compass: appears when the map is rotated, turns with it; tap = north up
                    if mapRotated {
                        Button { northTick += 1 } label: {
                            CompassFace(heading: mapHeading)
                                .frame(width: 48, height: 48)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        }
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                    // Go to my real location
                    Button {
                        if route.isActive, let p = route.displayPosition { focus(p) } else { recenterTick += 1 }
                    } label: {
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
                .animation(.easeInOut(duration: 0.2), value: mapRotated)
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
        HopRunner.shared.stop()
        RouteRunner.shared.stop()
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

    private func addPinToTrip() {
        guard let c = centerCoordinate, CLLocationCoordinate2DIsValid(c) else { return }
        let w = CoordTransform.gcj02ToWgs84(c)
        appendToTrip([Bookmark(name: L("Điểm ghim trên bản đồ", "Map pin"), lat: w.latitude, long: w.longitude)])
    }

    private func appendToTrip(_ pts: [Bookmark]) {
        RouteRunner.shared.append(pts) { err in
            if let err {
                UIApplication.shared.alert(body: L("Không tìm được đường: ", "Could not find a route: ") + err)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { isFaking = true }
                AlertKitAPI.present(title: L("Đã thêm vào hành trình", "Added to the trip"), icon: .done, style: .iOS17AppleMusic, haptic: .success)
            }
        }
    }

    private func stop() {
        HopRunner.shared.stop()
        RouteRunner.shared.stop()
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


/// Compass needle (red = north). Turns opposite to the map heading so it always points to real north.
struct CompassFace: View {
    var heading: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiaryLabel), lineWidth: 1).padding(6)
            VStack(spacing: 0) {
                Text("N").font(.system(size: 9, weight: .bold)).foregroundColor(.red)
                Triangle().fill(Color.red).frame(width: 8, height: 12)
                Triangle().fill(Color(.secondaryLabel)).frame(width: 8, height: 12).rotationEffect(.degrees(180))
                Text("S").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            }
        }
        .rotationEffect(.degrees(-heading))
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Hop between coordinates (nhảy cóc)

/// Jumps the simulated location through several points, every `intervalMs` milliseconds,
/// in order (looping) or at random. Runs while the app is open.
final class HopRunner: ObservableObject {
    static let shared = HopRunner()
    @Published private(set) var isRunning = false
    @Published private(set) var step = 0          // jumps done
    @Published private(set) var currentIndex = 0
    @Published var points: [Bookmark] = []        // last chosen points (kept for next time)
    private(set) var intervalMs = 1000
    private(set) var random = false
    private var timer: Timer?

    func start(points: [Bookmark], intervalMs: Int, random: Bool) {
        stop()
        guard points.count >= 2 else { return }
        self.points = points
        self.intervalMs = max(intervalMs, 100)
        self.random = random
        step = 0
        currentIndex = random ? Int.random(in: 0..<points.count) : 0
        isRunning = true
        jump()
        BackgroundKeeper.shared.update()
        let t = Timer(timeInterval: Double(self.intervalMs) / 1000, repeats: true) { [weak self] _ in self?.next() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isRunning { isRunning = false; BackgroundKeeper.shared.update() }
    }

    private func next() {
        guard isRunning, points.count >= 2 else { stop(); return }
        if random {
            var i = Int.random(in: 0..<points.count - 1)
            if i >= currentIndex { i += 1 }        // never the same point twice in a row
            currentIndex = i
        } else {
            currentIndex = (currentIndex + 1) % points.count
        }
        jump()
    }

    private func jump() {
        let p = points[currentIndex]
        let alt = Double(UserDefaults.standard.string(forKey: "locAltitude") ?? "0") ?? 0
        LocSimManager.startLocSim(location: CLLocation(coordinate: p.coordinate, altitude: alt,
                                                       horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()))
        UserDefaults.standard.set("\(p.lat),\(p.long)", forKey: "activeLoc")
        step += 1
    }
}

/// Banner on the map while hopping: progress + stop.
struct HopBanner: View {
    @ObservedObject var runner = HopRunner.shared
    var onStop: () -> Void
    var body: some View {
        if runner.isRunning, runner.points.indices.contains(runner.currentIndex) {
            HStack(spacing: 10) {
                Image(systemName: runner.random ? "shuffle" : "arrow.right")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Nhảy cóc: điểm \(runner.currentIndex + 1)/\(runner.points.count)",
                           "Hopping: point \(runner.currentIndex + 1)/\(runner.points.count)"))
                        .font(.footnote.weight(.semibold))
                    Text("\(runner.points[runner.currentIndex].displayName) • \(runner.intervalMs) ms")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 32, height: 32).background(Circle().fill(Color.red))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        }
    }
}

/// Choose the points (from Bookmarks / History / the map pin), the interval in ms and the order.
struct HopSetupView: View {
    var pinCoordinate: CLLocationCoordinate2D?   // WGS-84 of the map pin
    var onStart: ([Bookmark], Int, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hopIntervalMs") private var intervalText: String = "1000"
    @AppStorage("hopRandom") private var random = false
    @State private var source: LocList = .bookmarks
    @State private var search = ""
    @State private var picked: [Bookmark] = HopRunner.shared.points
    @State private var items: [Bookmark] = []

    private func key(_ b: Bookmark) -> String { String(format: "%.6f,%.6f", b.lat, b.long) }
    private func order(_ b: Bookmark) -> Int? { picked.firstIndex { key($0) == key(b) } }
    private var shown: [Bookmark] { filterAndSort(items, search: search, sort: source == .history ? .newest : .az) }
    private var interval: Int? { Int(intervalText.trimmingCharacters(in: .whitespaces)) }
    private var canStart: Bool { picked.count >= 2 && (interval ?? 0) >= 100 }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text(L("Thời gian mỗi lần nhảy", "Time between jumps"))
                        Spacer()
                        TextField("1000", text: $intervalText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("ms").foregroundColor(.secondary)
                    }
                    Picker(L("Thứ tự", "Order"), selection: $random) {
                        Text(L("Theo thứ tự", "In order")).tag(false)
                        Text(L("Ngẫu nhiên", "Random")).tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(L("1000 ms = 1 giây. Tối thiểu 100 ms. Theo thứ tự: nhảy lần lượt theo số thứ tự đã chọn rồi lặp lại. App cần đang mở thì mới nhảy tiếp.",
                           "1000 ms = 1 second. Minimum 100 ms. In order: follows the numbers you picked, then loops. The app must stay open to keep hopping."))
                }

                Section {
                    if let pin = pinCoordinate {
                        Button {
                            let b = Bookmark(name: L("Điểm ghim trên bản đồ", "Map pin"), lat: pin.latitude, long: pin.longitude)
                            if order(b) == nil { picked.append(b) }
                        } label: {
                            Label(L("Thêm điểm ghim hiện tại trên bản đồ", "Add the current map pin"), systemImage: "mappin.and.ellipse")
                        }
                    }
                    ForEach(Array(picked.enumerated()), id: \.offset) { i, b in
                        HStack {
                            Text("\(i + 1)").font(.footnote.weight(.bold)).foregroundColor(.white)
                                .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
                            Text(b.displayName).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.5f, %.5f", b.lat, b.long)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { picked.remove(atOffsets: $0) }
                } header: {
                    HStack {
                        Text(L("Đã chọn \(picked.count) điểm", "\(picked.count) points selected"))
                        Spacer()
                        if !picked.isEmpty {
                            Button(L("Bỏ chọn hết", "Clear")) { picked = [] }.font(.footnote)
                        }
                    }
                }

                Section {
                    Picker("", selection: $source) {
                        Text(LocList.bookmarks.title).tag(LocList.bookmarks)
                        Text(LocList.history.title).tag(LocList.history)
                    }
                    .pickerStyle(.segmented)
                    TextField(L("Tìm…", "Search…"), text: $search).disableAutocorrection(true)
                    if !shown.isEmpty {
                        Button(L("Chọn tất cả \(shown.count) điểm đang hiện", "Select all \(shown.count) shown")) {
                            for b in shown where order(b) == nil { picked.append(b) }
                        }
                    }
                    ForEach(shown) { b in
                        Button {
                            if let i = order(b) { picked.remove(at: i) } else { picked.append(b) }
                        } label: {
                            HStack {
                                if let i = order(b) {
                                    Text("\(i + 1)").font(.footnote.weight(.bold)).foregroundColor(.white)
                                        .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
                                } else {
                                    Image(systemName: "circle").font(.system(size: 22)).foregroundColor(Color(.tertiaryLabel))
                                        .frame(width: 24, height: 24)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.displayName).foregroundColor(.primary).lineLimit(1)
                                    Text(String(format: "%.6f, %.6f", b.lat, b.long)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text(L("Chọn điểm (bấm theo thứ tự muốn nhảy)", "Pick points (tap in the order to hop)"))
                }
            }
            .navigationTitle(L("Nhảy cóc", "Hop"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Bắt đầu", "Start")) {
                        hideKeyboard()
                        onStart(picked, interval ?? 1000, random)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(!canStart)
                }
            }
            .onAppear { items = loadList(source) }
            .onChange(of: source) { items = loadList($0) }
        }
    }
}

// MARK: - Drive / walk along a real road route (A → stops → B)

enum RouteEnd: String, CaseIterable, Identifiable {
    case stop, back, loop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stop: return L("Dừng ở điểm cuối", "Stop at the end")
        case .back: return L("Đi ngược về điểm đầu", "Go back to the start")
        case .loop: return L("Đi đi về về liên tục", "Back and forth forever")
        }
    }
}

final class RouteRunner: ObservableObject {
    static let shared = RouteRunner()
    enum State { case idle, running, paused, waiting, arrived }
    struct Sample { var c: CLLocationCoordinate2D; var course: Double; var speed: Double; var dist: Double; var wait: Bool; var pathD: Double = 0 }

    @Published private(set) var state: State = .idle
    @Published private(set) var distance: Double = 0          // metres travelled (whole trip)
    @Published private(set) var total: Double = 0
    @Published private(set) var currentSpeedKmh: Double = 0
    @Published private(set) var waitLeft: Int = 0
    /// Path in map (display) coordinates, for the blue line.
    @Published private(set) var displayPath: [CLLocationCoordinate2D] = []
    @Published private(set) var pathID = UUID()
    @Published var points: [Bookmark] = []                   // last chosen points (kept for next time)
    @Published private(set) var extending = false             // finding the road to an added point

    /// true = hand the whole trip to iOS (keeps going even if the app is closed). Settings: "routeSystemPlayback".
    private var systemPlayback: Bool { UserDefaults.standard.object(forKey: "routeSystemPlayback") as? Bool ?? true }
    private var usingSystem = false
    private var samples: [Sample] = []                        // one per second
    private var loopStart: Int? = nil                         // "back and forth": samples[loopStart...] repeat
    private var path: [CLLocationCoordinate2D] = []           // WGS-84 road path
    private var marks: [Double] = []                          // path distances of the stops
    private var speedKmh: Double = 40
    private var vary = true
    private var stopSeconds = 0
    private var end: RouteEnd = .stop
    private var elapsedBase: Double = 0
    private var runStart: Date?
    private var lastIndex = -1
    private var timer: Timer?

    var isActive: Bool { state != .idle }
    /// Map coordinate of where the trip is now.
    var displayPosition: CLLocationCoordinate2D? {
        let s = samples.indices.contains(lastIndex) ? samples[lastIndex] : samples.first
        return s.map { CoordTransform.wgs84ToGcj02($0.c) }
    }

    /// Asks Apple Maps for the route leg by leg. Calls back on the main thread.
    static func buildRoute(points: [Bookmark], walking: Bool,
                           progress: @escaping (Int, Int) -> Void,
                           done: @escaping (Result<([CLLocationCoordinate2D], [Double]), Error>) -> Void) {
        Task {
            var all: [CLLocationCoordinate2D] = []
            var marks: [Double] = []
            var run: Double = 0
            let legs = points.count - 1
            for i in 0..<legs {
                await MainActor.run { progress(i + 1, legs) }
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: CoordTransform.wgs84ToGcj02(points[i].coordinate)))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CoordTransform.wgs84ToGcj02(points[i + 1].coordinate)))
                req.transportType = walking ? .walking : .automobile
                var response: MKDirections.Response?
                for attempt in 0..<4 {
                    do { response = try await MKDirections(request: req).calculate(); break }
                    catch {
                        if attempt == 3 { await MainActor.run { done(.failure(error)) }; return }
                        try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * (attempt + 1)))   // Apple limits fast requests
                    }
                }
                guard let r = response?.routes.first else {
                    await MainActor.run { done(.failure(NSError(domain: "route", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        L("Không tìm được đường từ điểm \(i + 1) đến điểm \(i + 2).", "No route from point \(i + 1) to point \(i + 2).")]))) }
                    return
                }
                let poly = r.polyline
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
                poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                var wgs = coords.map { CoordTransform.gcj02ToWgs84($0) }
                if !all.isEmpty, !wgs.isEmpty { wgs.removeFirst() }
                for c in wgs {
                    if let last = all.last { run += CLLocation(latitude: last.latitude, longitude: last.longitude)
                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) }
                    all.append(c)
                }
                if i < legs - 1 { marks.append(run) }
                if legs > 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            await MainActor.run { done(.success((all, marks))) }
        }
    }

    func start(path: [CLLocationCoordinate2D], stopMarks: [Double], speedKmh: Double, vary: Bool, stopSeconds: Int, end: RouteEnd) {
        stop()
        guard path.count >= 2 else { return }
        self.path = path
        marks = stopMarks
        self.speedKmh = max(speedKmh, 1)
        self.vary = vary
        self.stopSeconds = max(stopSeconds, 0)
        self.end = end
        let plan = makePlan(from: 0, travelled: 0, first: true)
        samples = plan.0
        loopStart = plan.1
        guard !samples.isEmpty else { return }
        total = samples.last?.dist ?? 0
        displayPath = path.map { CoordTransform.wgs84ToGcj02($0) }
        pathID = UUID()
        elapsedBase = 0
        runStart = Date()
        lastIndex = -1
        usingSystem = systemPlayback
        state = .running
        if usingSystem { upload(from: 0) }
        BackgroundKeeper.shared.update()
        tick()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Adds more points after the current end (B). The trip goes on, or starts again if it had arrived.
    func append(_ newPoints: [Bookmark], done: @escaping (String?) -> Void) {
        guard state != .idle, let last = path.last, !newPoints.isEmpty, !extending else { done(nil); return }
        extending = true
        let walking = UserDefaults.standard.bool(forKey: "routeWalking")
        let from = Bookmark(name: "", lat: last.latitude, long: last.longitude)
        Self.buildRoute(points: [from] + newPoints, walking: walking, progress: { _, _ in }, done: { [weak self] result in
            guard let self else { return }
            self.extending = false
            guard self.state != .idle else { done(nil); return }
            switch result {
            case .failure(let e):
                done(e.localizedDescription)
            case .success(let (leg, legMarks)):
                let oldTotal = self.pathLength
                self.path += leg.dropFirst()
                self.marks.append(oldTotal)
                self.marks += legMarks.map { $0 + oldTotal }
                self.points += newPoints
                let keep = max(self.lastIndex, 0)
                let cur = self.samples.indices.contains(keep) ? self.samples[keep] : self.samples.last
                let prefix = Array(self.samples[...min(keep, self.samples.count - 1)])
                let plan = self.makePlan(from: cur?.pathD ?? oldTotal, travelled: cur?.dist ?? 0, first: false)
                self.samples = prefix + plan.0
                self.loopStart = plan.1.map { prefix.count + $0 }
                self.total = self.samples.last?.dist ?? 0
                self.displayPath = self.path.map { CoordTransform.wgs84ToGcj02($0) }
                self.pathID = UUID()
                if self.state == .arrived {
                    self.elapsedBase = Double(keep); self.runStart = Date()
                    self.state = .running
                    self.startTimer()
                    BackgroundKeeper.shared.update()
                }
                if self.usingSystem && self.state != .paused { self.upload(from: keep) }
                done(nil)
            }
        })
    }

    func togglePause() {
        if state == .running || state == .waiting {
            elapsedBase = elapsed; runStart = nil
            state = .paused; currentSpeedKmh = 0
            if let s = current { send(s, speed: 0) }               // freeze here (also stops iOS playback)
        } else if state == .paused {
            runStart = Date(); state = .running
            if usingSystem { upload(from: max(lastIndex, 0)) }
        }
    }

    /// Ends the trip and removes the line. The caller sets / stops the location afterwards.
    func stop() {
        timer?.invalidate(); timer = nil
        state = .idle
        currentSpeedKmh = 0
        samples = []
        if !displayPath.isEmpty { displayPath = []; pathID = UUID() }
        BackgroundKeeper.shared.update()
    }

    private var elapsed: Double { elapsedBase + (runStart.map { Date().timeIntervalSince($0) } ?? 0) }
    private var current: Sample? { samples.indices.contains(lastIndex) ? samples[lastIndex] : samples.first }

    private func tick() {
        guard state != .idle, state != .paused, state != .arrived, !samples.isEmpty else { return }
        var i = Int(elapsed)
        if let ls = loopStart, samples.count > ls {
            if i >= samples.count { i = ls + (i - ls) % (samples.count - ls) }
        } else if i >= samples.count - 1 {
            i = samples.count - 1
            show(i)
            if !usingSystem { send(samples[i], speed: 0) }
            timer?.invalidate(); timer = nil
            currentSpeedKmh = 0
            state = .arrived
            BackgroundKeeper.shared.update()
            return
        }
        guard i != lastIndex else { return }
        show(i)
        if !usingSystem { send(samples[i], speed: samples[i].speed) }
    }

    private func show(_ i: Int) {
        lastIndex = i
        let s = samples[i]
        distance = s.dist
        currentSpeedKmh = s.speed * 3.6
        if s.wait {
            var n = 0
            var j = i
            while j < samples.count, samples[j].wait { n += 1; j += 1 }
            waitLeft = n
            state = .waiting
        } else {
            state = .running
        }
    }

    private func location(_ s: Sample, speed: Double, at date: Date) -> CLLocation {
        let alt = Double(UserDefaults.standard.string(forKey: "locAltitude") ?? "0") ?? 0
        return CLLocation(coordinate: s.c, altitude: alt, horizontalAccuracy: 5, verticalAccuracy: 5,
                          course: s.course, speed: speed, timestamp: date)
    }

    private func send(_ s: Sample, speed: Double) {
        LocSimManager.startLocSim(location: location(s, speed: speed, at: Date()))
        UserDefaults.standard.set("\(s.c.latitude),\(s.c.longitude)", forKey: "activeLoc")
    }

    /// Hands samples[from...] to iOS, one per second; iOS plays them on its own (app may be closed).
    private func upload(from: Int) {
        var rest = Array(samples[min(from, samples.count - 1)...])
        if let ls = loopStart, samples.count > ls {
            let cycle = samples[ls...]
            while rest.count < 21_600 { rest += cycle }         // about 6 hours ahead, then iOS repeats
        }
        let now = Date()
        LocSimManager.playRoute(rest.enumerated().map { location($0.element, speed: $0.element.speed, at: now.addingTimeInterval(Double($0.offset))) },
                                interval: 1, loop: loopStart != nil)
        if let last = samples.last { UserDefaults.standard.set("\(last.c.latitude),\(last.c.longitude)", forKey: "activeLoc") }
    }

    // MARK: Build the per-second plan

    private var pathLength: Double {
        var d: Double = 0
        for i in 1..<max(path.count, 1) {
            d += CLLocation(latitude: path[i - 1].latitude, longitude: path[i - 1].longitude)
                .distance(from: CLLocation(latitude: path[i].latitude, longitude: path[i].longitude))
        }
        return d
    }

    /// Per-second plan from path distance `from` forward to the end, then back / back-and-forth.
    /// Returns the samples and, for back-and-forth, where the repeating part starts.
    private func makePlan(from start: Double, travelled t0: Double, first: Bool) -> ([Sample], Int?) {
        let path = self.path, stopMarks = marks, speedKmh = self.speedKmh, vary = self.vary, stopSeconds = self.stopSeconds
        guard path.count >= 2 else { return ([], nil) }
        var cum: [Double] = [0]
        for i in 1..<path.count {
            cum.append(cum[i - 1] + CLLocation(latitude: path[i - 1].latitude, longitude: path[i - 1].longitude)
                .distance(from: CLLocation(latitude: path[i].latitude, longitude: path[i].longitude)))
        }
        let total = cum.last ?? 0
        func pos(_ d: Double, _ dir: Double) -> (CLLocationCoordinate2D, Double) {
            var i = cum.firstIndex { $0 >= d } ?? cum.count - 1
            i = max(i, 1)
            let a = path[i - 1], b = path[i]
            let seg = cum[i] - cum[i - 1]
            let t = seg > 0 ? (d - cum[i - 1]) / seg : 0
            let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t)
            var course = Self.bearing(a, b)
            if dir < 0 { course = (course + 180).truncatingRemainder(dividingBy: 360) }
            return (c, course)
        }
        var out: [Sample] = []
        var travelled = t0
        var factor: Double = 1
        var lastD = start
        func wait() {
            guard stopSeconds > 0, let l = out.last else { return }
            for _ in 0..<stopSeconds { out.append(Sample(c: l.c, course: l.course, speed: 0, dist: travelled, wait: true, pathD: lastD)) }
        }
        func leg(from: Double, to: Double) {
            let dir: Double = to >= from ? 1 : -1
            let ms = (dir > 0 ? stopMarks.sorted() : stopMarks.sorted(by: >))
                .filter { dir > 0 ? ($0 > from + 0.5 && $0 < to - 0.5) : ($0 < from - 0.5 && $0 > to + 0.5) }
            var d = from
            var next = 0
            while dir > 0 ? d < to : d > to {
                if vary { factor = min(max(factor + Double.random(in: -0.08...0.08), 0.8), 1.2) } else { factor = 1 }
                let v = speedKmh * factor / 3.6
                var nd = d + dir * v
                var atStop = false
                if next < ms.count, dir > 0 ? nd >= ms[next] : nd <= ms[next] { nd = ms[next]; next += 1; atStop = true }
                if dir > 0 ? nd >= to : nd <= to { nd = to }
                travelled += abs(nd - d)
                d = nd
                lastD = d
                let (c, k) = pos(d, dir)
                out.append(Sample(c: c, course: k, speed: v, dist: travelled, wait: false, pathD: d))
                if atStop { wait() }
                if out.count > 200_000 { return }
            }
        }
        if first {
            let (c0, k0) = pos(start, 1)
            out.append(Sample(c: c0, course: k0, speed: 0, dist: travelled, wait: false, pathD: start))
        }
        leg(from: start, to: total)
        switch end {
        case .stop:
            return (out, nil)
        case .back:
            wait(); leg(from: total, to: 0)
            return (out, nil)
        case .loop:
            let ls = out.count
            wait(); leg(from: total, to: 0); wait(); leg(from: 0, to: total)
            return (out, out.count > ls ? ls : nil)
        }
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLo = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLo) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLo)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Keeps the app running in the background (like a navigation app) while a trip or hopping is active.
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()
    private let manager = CLLocationManager()
    private var on = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func update() {
        let needed = HopRunner.shared.isRunning || [.running, .waiting, .paused].contains(RouteRunner.shared.state)
        guard needed != on else { return }
        on = needed
        if needed {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Banner on the map during a trip: distance, time left, speed, pause / stop.
struct RouteBanner: View {
    @ObservedObject var runner = RouteRunner.shared
    var onStop: () -> Void
    var onAddPin: () -> Void = {}
    var onAddFromList: () -> Void = {}
    var body: some View {
        if runner.isActive {
            VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 18)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption.monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if runner.state != .arrived {
                    Button { runner.togglePause() } label: {
                        Image(systemName: runner.state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .frame(width: 32, height: 32).background(Circle().fill(Color.accentColor))
                    }
                }
                Button(action: { runner.state == .arrived ? runner.stop() : onStop() }) {
                    Image(systemName: runner.state == .arrived ? "xmark" : "stop.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 32, height: 32).background(Circle().fill(runner.state == .arrived ? Color.gray : Color.red))
                }
            }
            // Add the next point: continues the trip (or restarts it after arriving)
            Menu {
                Button(action: onAddPin) {
                    Label(L("Điểm ghim giữa bản đồ", "The pin in the map centre"), systemImage: "mappin.and.ellipse")
                }
                Button(action: onAddFromList) {
                    Label(L("Chọn từ Đánh dấu / Lịch sử / bản đồ…", "From Bookmarks / History / map…"), systemImage: "list.bullet")
                }
            } label: {
                HStack(spacing: 6) {
                    if runner.extending { ProgressView().scaleEffect(0.8) } else { Image(systemName: "plus.circle.fill") }
                    Text(runner.extending ? L("Đang tìm đường…", "Finding the road…") : L("Thêm điểm tiếp theo", "Add next point"))
                        .font(.footnote.weight(.semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor))
            }
            .disabled(runner.extending)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        }
    }

    private var title: String {
        switch runner.state {
        case .paused: return L("Đã tạm dừng", "Paused")
        case .waiting: return L("Đang dừng ở điểm dừng (\(runner.waitLeft) giây)", "Waiting at a stop (\(runner.waitLeft) s)")
        case .arrived: return L("Đã đến nơi", "Arrived")
        default: return L("Đang di chuyển • \(Int(runner.currentSpeedKmh.rounded())) km/h", "Moving • \(Int(runner.currentSpeedKmh.rounded())) km/h")
        }
    }

    private var detail: String {
        let done = runner.distance / 1000, all = runner.total / 1000
        return String(format: "%.2f / %.2f km", done, all)
    }
}

/// Picks an ordered list of points (Bookmarks / History / the map pin).
struct PointPickerSections: View {
    @Binding var picked: [Bookmark]
    var pinCoordinate: CLLocationCoordinate2D?
    var numberLabel: (Int, Int) -> String = { i, _ in "\(i + 1)" }
    @State private var source: LocList = .bookmarks
    @State private var search = ""
    @State private var items: [Bookmark] = []
    @State private var mapPicker = false

    private func key(_ b: Bookmark) -> String { String(format: "%.6f,%.6f", b.lat, b.long) }
    private func order(_ b: Bookmark) -> Int? { picked.firstIndex { key($0) == key(b) } }
    private var shown: [Bookmark] { filterAndSort(items, search: search, sort: source == .history ? .newest : .az) }

    var body: some View {
        Section {
            Button { hideKeyboard(); mapPicker = true } label: {
                Label(L("Chọn điểm trên bản đồ", "Pick points on the map"), systemImage: "map")
            }
            .fullScreenCover(isPresented: $mapPicker) {
                MapPointPicker(picked: $picked,
                               start: (picked.last?.coordinate ?? pinCoordinate).map { CoordTransform.wgs84ToGcj02($0) },
                               numberLabel: numberLabel)
            }
            if let pin = pinCoordinate {
                Button {
                    picked.append(Bookmark(name: L("Điểm ghim trên bản đồ", "Map pin"), lat: pin.latitude, long: pin.longitude))
                } label: {
                    Label(L("Thêm điểm ghim hiện tại trên bản đồ", "Add the current map pin"), systemImage: "mappin.and.ellipse")
                }
            }
            ForEach(Array(picked.enumerated()), id: \.offset) { i, b in
                HStack {
                    Text(numberLabel(i, picked.count)).font(.footnote.weight(.bold)).foregroundColor(.white)
                        .frame(minWidth: 24, minHeight: 24).padding(.horizontal, 2).background(Capsule().fill(Color.accentColor))
                    Text(b.displayName).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.5f, %.5f", b.lat, b.long)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            }
            .onDelete { picked.remove(atOffsets: $0) }
            .onMove { picked.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            HStack {
                Text(L("Đã chọn \(picked.count) điểm", "\(picked.count) points selected"))
                Spacer()
                if picked.count > 1 { EditButton().font(.footnote) }
                if !picked.isEmpty { Button(L("Bỏ chọn hết", "Clear")) { picked = [] }.font(.footnote) }
            }
        } footer: {
            Text(L("Vuốt trái để bỏ một điểm, bấm Sửa để kéo đổi thứ tự.", "Swipe left to remove a point, tap Edit to drag and reorder."))
        }

        Section {
            Picker("", selection: $source) {
                Text(LocList.bookmarks.title).tag(LocList.bookmarks)
                Text(LocList.history.title).tag(LocList.history)
            }
            .pickerStyle(.segmented)
            TextField(L("Tìm…", "Search…"), text: $search).disableAutocorrection(true)
            ForEach(shown) { b in
                Button {
                    if let i = order(b) { picked.remove(at: i) } else { picked.append(b) }
                } label: {
                    HStack {
                        if let i = order(b) {
                            Text(numberLabel(i, picked.count)).font(.footnote.weight(.bold)).foregroundColor(.white)
                                .frame(minWidth: 24, minHeight: 24).padding(.horizontal, 2).background(Capsule().fill(Color.accentColor))
                        } else {
                            Image(systemName: "circle").font(.system(size: 22)).foregroundColor(Color(.tertiaryLabel))
                                .frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.displayName).foregroundColor(.primary).lineLimit(1)
                            Text(String(format: "%.6f, %.6f", b.lat, b.long)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        } header: {
            Text(L("Chọn điểm (bấm theo thứ tự đi)", "Pick points (tap in travel order)"))
        }
        .onAppear { items = loadList(source) }
        .onChange(of: source) { items = loadList($0) }
    }
}

struct RouteSetupView: View {
    var pinCoordinate: CLLocationCoordinate2D?
    var onStart: ([CLLocationCoordinate2D], [Double], Double, Bool, Int, RouteEnd) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("routeWalking") private var walking = false
    @AppStorage("routeSpeedCar") private var speedCar: String = "40"
    @AppStorage("routeSpeedWalk") private var speedWalk: String = "5"
    @AppStorage("routeVary") private var vary = true
    @AppStorage("routeStopSec") private var stopSecText: String = "0"
    @AppStorage("routeEnd") private var endRaw: String = RouteEnd.stop.rawValue
    @AppStorage("routeSystemPlayback") private var systemPlayback = true
    @State private var picked: [Bookmark] = RouteRunner.shared.points
    @State private var busy: String? = nil

    private var speedBinding: Binding<String> { walking ? $speedWalk : $speedCar }
    private var speed: Double? { Double(speedBinding.wrappedValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("", selection: $walking) {
                        Text(L("🚗 Ô tô", "🚗 Car")).tag(false)
                        Text(L("🚶 Đi bộ", "🚶 Walking")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text(L("Tốc độ", "Speed"))
                        Spacer()
                        TextField(walking ? "5" : "40", text: speedBinding)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        Text("km/h").foregroundColor(.secondary)
                    }
                    Toggle(L("Tốc độ dao động cho giống thật", "Vary the speed a little"), isOn: $vary)
                    HStack {
                        Text(L("Dừng ở mỗi điểm dừng", "Wait at each stop"))
                        Spacer()
                        TextField("0", text: $stopSecText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                        Text(L("giây", "s")).foregroundColor(.secondary)
                    }
                    Picker(L("Khi đến nơi", "At the end"), selection: $endRaw) {
                        ForEach(RouteEnd.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle(L("Giao lộ trình cho iOS tự chạy", "Let iOS play the trip"), isOn: $systemPlayback)
                } footer: {
                    Text(L("Điểm đầu tiên là A, điểm cuối là B, các điểm ở giữa là điểm dừng. Đường đi lấy theo Apple Maps. Bật \"Giao lộ trình cho iOS tự chạy\": vị trí vẫn chạy kể cả khi tắt hẳn app. Tắt: app tự chạy và vẫn chạy ngầm khi ra màn hình chính (hiện biểu tượng định vị xanh).",
                           "The first point is A, the last is B, points in between are stops. Roads come from Apple Maps. \"Let iOS play the trip\" on: keeps moving even if the app is closed. Off: the app drives it and keeps running in the background (blue location icon)."))
                }

                PointPickerSections(picked: $picked, pinCoordinate: pinCoordinate, numberLabel: { i, _ in "\(i + 1)" })
            }
            .navigationTitle(L("Đi theo đường", "Follow roads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Bắt đầu", "Start")) { begin() }
                        .font(.body.weight(.semibold))
                        .disabled(picked.count < 2 || (speed ?? 0) <= 0 || busy != nil)
                }
            }
            .overlay {
                if let busy {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(busy).font(.footnote)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                }
            }
        }
    }

    private func begin() {
        hideKeyboard()
        RouteRunner.shared.points = picked
        busy = L("Đang tìm đường…", "Finding the route…")
        RouteRunner.buildRoute(points: picked, walking: walking, progress: { i, n in
            busy = n > 1 ? L("Đang tìm đường \(i)/\(n)…", "Finding the route \(i)/\(n)…") : L("Đang tìm đường…", "Finding the route…")
        }, done: { result in
            busy = nil
            switch result {
            case .success(let (path, marks)):
                onStart(path, marks, speed ?? 40, vary, Int(stopSecText) ?? 0, RouteEnd(rawValue: endRaw) ?? .stop)
                dismiss()
            case .failure(let e):
                UIApplication.shared.alert(body: L("Không tìm được đường: ", "Could not find a route: ") + e.localizedDescription)
            }
        })
    }
}

// MARK: - Pick route points right on the map

/// Small map for picking points: fixed centre pin, picked points shown as numbered markers.
struct PickMapView: UIViewRepresentable {
    var start: CLLocationCoordinate2D?                  // map coordinate to open at
    var markers: [(String, CLLocationCoordinate2D)]     // label + map coordinate
    @Binding var center: CLLocationCoordinate2D?
    var recenterTick: Int = 0
    var focus: EquatableCoordinate? = nil

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.showsUserLocation = true
        m.pointOfInterestFilter = .includingAll
        if let s = start {
            m.setRegion(MKCoordinateRegion(center: s, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
        }
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        let sig = markers.map { "\($0.0)|\($0.1.latitude),\($0.1.longitude)" }.joined(separator: ";")
        context.coordinator.parent = self
        if recenterTick != context.coordinator.lastRecenter {
            context.coordinator.lastRecenter = recenterTick
            if let loc = m.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) { m.setCenter(loc, animated: true) }
        }
        if let f = focus, f != context.coordinator.lastFocus {
            context.coordinator.lastFocus = f
            m.setRegion(MKCoordinateRegion(center: f.coordinate, latitudinalMeters: 800, longitudinalMeters: 800), animated: true)
        }
        guard sig != context.coordinator.lastSig else { return }
        context.coordinator.lastSig = sig
        m.removeAnnotations(m.annotations.filter { !($0 is MKUserLocation) })
        for (label, c) in markers {
            let a = MKPointAnnotation()
            a.coordinate = c
            a.title = label
            m.addAnnotation(a)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PickMapView
        var lastSig = ""
        var lastRecenter = 0
        var lastFocus: EquatableCoordinate?
        init(_ p: PickMapView) { parent = p }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            DispatchQueue.main.async { self.parent.center = c }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pt") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pt")
            v.annotation = annotation
            let t = annotation.title ?? nil
            v.glyphText = t
            v.titleVisibility = .hidden
            let n = parent.markers.count
            v.markerTintColor = t == "1" ? .systemGreen : (n > 1 && t == "\(n)" ? .systemRed : .systemBlue)
            v.displayPriority = .required
            return v
        }
    }
}

struct MapPointPicker: View {
    @Binding var picked: [Bookmark]
    var start: CLLocationCoordinate2D?                  // map coordinate
    var numberLabel: (Int, Int) -> String
    @Environment(\.dismiss) private var dismiss
    @State private var center: CLLocationCoordinate2D? = nil
    @State private var recenterTick = 0
    @State private var focusTick: EquatableCoordinate? = nil

    private var markers: [(String, CLLocationCoordinate2D)] {
        picked.enumerated().map { (numberLabel($0.offset, picked.count), CoordTransform.wgs84ToGcj02($0.element.coordinate)) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                PickMapView(start: start, markers: markers, center: $center, recenterTick: recenterTick, focus: focusTick)
                    .ignoresSafeArea(edges: .bottom)
                CenterPin()
                VStack {
                    MapSearchBar(near: center ?? start) { c, _ in focusTick = EquatableCoordinate(coordinate: c) }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    Spacer()
                }
                .zIndex(2)
                // Current location button (bottom right, above the add buttons)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { recenterTick += 1 } label: {
                            Image(systemName: "location")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .frame(width: 48, height: 48)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 140)
                    }
                }
                VStack(spacing: 10) {
                    Spacer()
                    if let c = center {
                        Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                            .font(.footnote.monospacedDigit())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    HStack(spacing: 12) {
                        if !picked.isEmpty {
                            Button {
                                picked.removeLast()
                            } label: {
                                Label(L("Bỏ điểm cuối", "Undo"), systemImage: "arrow.uturn.backward")
                                    .font(.body.weight(.semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(Capsule().fill(Color(.systemBackground)))
                                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                            }
                        }
                        Button(action: addHere) {
                            Label(picked.isEmpty ? L("Thêm điểm bắt đầu", "Add start point") : L("Thêm điểm kế tiếp", "Add next point"),
                                  systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(Capsule().fill(Color.accentColor))
                                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        }
                        .disabled(center == nil)
                    }
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(L("Đã chọn \(picked.count) điểm", "\(picked.count) points picked"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Xong", "Done")) { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
    }

    /// Adds the point under the pin; names it after the street when Apple finds one.
    private func addHere() {
        guard let c = center else { return }
        let wgs = CoordTransform.gcj02ToWgs84(c)
        let b = Bookmark(name: L("Điểm trên bản đồ", "Point on map"), lat: wgs.latitude, long: wgs.longitude)
        picked.append(b)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)) { marks, _ in
            guard let p = marks?.first else { return }
            let name = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let label = name.isEmpty ? (p.name ?? "") : name
            guard !label.isEmpty else { return }
            DispatchQueue.main.async {
                if let i = picked.firstIndex(where: { $0.id == b.id }) { picked[i].name = label }
            }
        }
    }
}

/// Pick one or more points to add after the current end of the trip.
struct AddNextPointsView: View {
    var pinCoordinate: CLLocationCoordinate2D?
    var onAdd: ([Bookmark]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [Bookmark] = []

    var body: some View {
        NavigationView {
            List {
                PointPickerSections(picked: $picked, pinCoordinate: pinCoordinate, numberLabel: { i, _ in "+\(i + 1)" })
            }
            .navigationTitle(L("Thêm điểm tiếp theo", "Add next points"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Thêm", "Add")) { onAdd(picked); dismiss() }
                        .font(.body.weight(.semibold))
                        .disabled(picked.isEmpty)
                }
            }
        }
    }
}

// MARK: - Search places on Apple Maps (used on every map)

final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ text: String, near: CLLocationCoordinate2D?) {
        if let c = near { completer.region = MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { results = []; completer.cancel() } else { completer.queryFragment = q }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(8))
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }
}

/// Search field with live suggestions. `onPick` gets the map coordinate and the place name.
struct MapSearchBar: View {
    var near: CLLocationCoordinate2D?
    var onPick: (CLLocationCoordinate2D, String) -> Void
    @StateObject private var model = PlaceSearchModel()
    @State private var text = ""
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L("Tìm địa điểm", "Search places"), text: $text)
                    .disableAutocorrection(true)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { run(MKLocalSearch.Request(), query: text) }
                    .onChange(of: text) { model.update($0, near: near) }
                if searching { ProgressView().scaleEffect(0.8) }
                if !text.isEmpty {
                    Button { text = ""; model.update("", near: near) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)

            if focused && !model.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { i, r in
                        Button {
                            run(MKLocalSearch.Request(completion: r), query: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.subheadline).foregroundColor(.primary).lineLimit(1)
                                if !r.subtitle.isEmpty {
                                    Text(r.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        if i < model.results.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .padding(.top, 6)
            }
        }
    }

    private func run(_ req: MKLocalSearch.Request, query: String?) {
        if let q = query {
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            req.naturalLanguageQuery = q
            if let c = near { req.region = MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        }
        searching = true
        MKLocalSearch(request: req).start { resp, _ in
            searching = false
            guard let item = resp?.mapItems.first else {
                UIApplication.shared.alert(body: L("Không tìm thấy địa điểm.", "No place found."))
                return
            }
            let name = item.name ?? text
            text = name
            focused = false
            hideKeyboard()
            onPick(item.placemark.coordinate, name)
        }
    }
}
