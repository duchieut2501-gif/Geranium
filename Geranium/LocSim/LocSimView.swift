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
    case map, history, bookmarks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .map: return "Bản đồ"
        case .history: return "Lịch sử"
        case .bookmarks: return "Đánh dấu"
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

    var body: some View {
        NavigationView {
            ZStack {
                mapLayer                                  // kept alive so the map keeps its position
                if tab != .map {
                    LocationListView(list: tab == .history ? .history : .bookmarks,
                                     onStart: { item in
                                         fake(wgs: item.coordinate)
                                         showOnMap(item)
                                     },
                                     onShowOnMap: { item in showOnMap(item) })
                        .id(tab)
                        .background(Color(.systemBackground).ignoresSafeArea())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: stop) {
                        Image(systemName: "location.slash")
                            .font(.title3)
                            .foregroundColor(isFaking ? .red : .secondary)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(MainTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { settingsSheet = true } label: {
                        Image(systemName: "gearshape").font(.title3)
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
        .onAppear {
            LocationModel().requestAuthorisation()
            CLLocationManager().requestAlwaysAuthorization()
            AppCustomizer.restoreIconIfNeeded()
        }
    }

    // MARK: - Map tab

    private var mapLayer: some View {
        ZStack {
            CustomMapView(centerCoordinate: $centerCoordinate,
                          recenterTick: recenterTick,
                          focusCoordinate: focusCoordinate)
                .ignoresSafeArea(edges: .bottom)

            CenterPin()

            VStack(spacing: 10) {
                Spacer()
                Text(coordinateText)
                    .font(.footnote.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .onTapGesture {
                        UIPasteboard.general.string = coordinateText
                        AlertKitAPI.present(title: "Đã sao chép toạ độ", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                    }
                HStack(alignment: .bottom) {
                    // Play (blue) -> while faking becomes Stop (red, square in the middle)
                    Button(action: { isFaking ? stop() : startAtPin() }) {
                        ZStack {
                            Circle().fill(isFaking ? Color(red: 0.96, green: 0.26, blue: 0.21)
                                                   : Color(red: 0.13, green: 0.59, blue: 0.95))
                            if isFaking {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white)
                                    .frame(width: 21, height: 21)
                            } else {
                                PlayTriangle()
                                    .fill(Color.white)
                                    .frame(width: 24, height: 27)
                            }
                        }
                        .frame(width: 58, height: 58)
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        .animation(.easeInOut(duration: 0.2), value: isFaking)
                    }
                    Spacer()
                    // Go to my real location
                    Button { recenterTick += 1 } label: {
                        Image(systemName: "location")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 54, height: 54)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var coordinateText: String {
        guard let c = centerCoordinate else { return "Đang tải bản đồ…" }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    // MARK: - Actions

    private func startAtPin() {
        guard let center = centerCoordinate, CLLocationCoordinate2DIsValid(center) else {
            UIApplication.shared.alert(body: "Bản đồ chưa sẵn sàng, thử lại sau giây lát.")
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
        logToHistory(lat: wgs.latitude, long: wgs.longitude)
        AlertKitAPI.present(title: "Đã bắt đầu fake", icon: .done, style: .iOS17AppleMusic, haptic: .success)
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
        isFaking = false
        AlertKitAPI.present(title: "Đã dừng fake", icon: .done, style: .iOS17AppleMusic, haptic: .success)
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
    case d, e, f, custom
    var id: String { rawValue }

    /// Name of the alternate icon in Info.plist (files Icons/Beta.png, Flore.png, Bouquet.png).
    var alternateName: String? {
        switch self {
        case .d: return "Beta"
        case .e: return "Flore"
        case .f: return "Bouquet"
        case .custom: return nil
        }
    }

    var title: String {
        switch self {
        case .d: return "Ghim đôi"
        case .e: return "Bản đồ"
        case .f: return "Sóng"
        case .custom: return "Ảnh của bạn"
        }
    }

    var preview: UIImage? {
        alternateName.flatMap { UIImage(named: $0) }
    }
}

enum AppCustomizer {
    static var storedChoice: String {
        get { UserDefaults.standard.string(forKey: "iconChoice") ?? AppIconChoice.d.rawValue }
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
        let alert = UIAlertController(title: "Cần respring để áp dụng",
                                      message: "Đã lưu thay đổi. Màn hình chính cần khởi động lại (respring) thì tên / biểu tượng mới hiện ra.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Để sau", style: .cancel) { _ in onLater?() })
        alert.addAction(UIAlertAction(title: "Respring ngay", style: .default) { _ in respringNow() })
        presentTop(alert)
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
            case .readInfo: return "Không đọc được thông tin app."
            case .writeTemp: return "Không ghi được file tạm."
            case .rootWrite: return "Không ghi được vào app. App phải được cài bằng TrollStore."
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
            setBuiltIn(.d) { _ in completion(nil) }
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Info.plist")
            try original.write(to: tmp)
            _ = RootHelper.removeItem(at: infoURL)
            _ = RootHelper.copy(from: tmp, to: infoURL)
            guard FileManager.default.fileExists(atPath: infoURL.path) else { throw Failure.rootWrite }
            storedChoice = AppIconChoice.d.rawValue
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
    @State private var manualLat = ""
    @State private var manualLong = ""
    @State private var choice = AppIconChoice(rawValue: AppCustomizer.storedChoice) ?? .d
    @State private var name = AppCustomizer.currentDisplayName
    @State private var originalName = AppCustomizer.currentDisplayName
    @State private var pickedImage: UIImage? = nil      // raw photo, before crop
    @State private var croppedIcon: UIImage? = nil      // final square icon
    @State private var showPicker = false
    @State private var showCrop = false
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
                            Label("Respring ngay để áp dụng", systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text("Có thay đổi tên / biểu tượng chưa áp dụng. Bấm để respring, hoặc để sau: thay đổi sẽ hiện ra lần respring hoặc khởi động lại máy tiếp theo.")
                    }
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach([AppIconChoice.d, .e, .f]) { option in
                            iconTile(image: option.preview, title: option.title, selected: choice == option && croppedIcon == nil) {
                                croppedIcon = nil
                                AppCustomizer.setBuiltIn(option) { ok in
                                    if ok { choice = option }
                                    else { UIApplication.shared.alert(body: "Không đổi được biểu tượng.") }
                                }
                            }
                        }
                        iconTile(image: croppedIcon, title: "Ảnh của bạn", selected: croppedIcon != nil || choice == .custom, placeholder: "photo.badge.plus") {
                            showPicker = true
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Biểu tượng")
                } footer: {
                    Text("3 mẫu có sẵn đổi ngay. \"Ảnh của bạn\": chọn ảnh, cắt cho vừa khung rồi bấm Áp dụng ở dưới.")
                }

                Section {
                    TextField("Tên hiển thị", text: $name)
                        .disableAutocorrection(true)
                } header: {
                    Text("Tên dưới biểu tượng")
                } footer: {
                    Text("Tên ngắn (khoảng 12 ký tự) sẽ hiện đầy đủ, tên dài sẽ bị cắt bớt.")
                }

                Section {
                    Button {
                        applyChanges()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Áp dụng").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || (!nameChanged && croppedIcon == nil))
                } footer: {
                    Text("Đổi tên hoặc dùng ảnh riêng cần respring mới hiện ra. App sẽ hỏi bạn respring ngay hay để sau.")
                }

                Section {
                    TextField("Vĩ độ (latitude)", text: $manualLat).keyboardType(.numbersAndPunctuation)
                    TextField("Kinh độ (longitude)", text: $manualLong).keyboardType(.numbersAndPunctuation)
                    Button("Bắt đầu fake toạ độ này") { fakeManual() }
                } header: {
                    Text("Fake theo toạ độ")
                } footer: {
                    Text("Có thể dán cả cặp \"21.05, 105.91\" vào ô Vĩ độ.")
                }

                Section {
                    HStack {
                        Text("Độ cao (m)")
                        Spacer()
                        TextField("0", text: $altitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                } header: {
                    Text("Độ cao")
                }

                Section {
                    Button("Khôi phục mặc định", role: .destructive) {
                        UIApplication.shared.confirmAlert(title: "Khôi phục mặc định?",
                                                          body: "Tên về \"Location Simulator\", biểu tượng về mẫu Ghim đôi.",
                                                          onOK: {
                            AppCustomizer.resetToDefault { error in
                                if let error { UIApplication.shared.alert(body: error.localizedDescription) }
                                else if AppCustomizer.pendingRespring { pending = true; AppCustomizer.askRespring() }
                            }
                        }, noCancel: false)
                    }
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { image in
                    showPicker = false
                    if let image {
                        pickedImage = image
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showCrop = true }
                    }
                }
            }
            .fullScreenCover(isPresented: $showCrop) {
                if let img = pickedImage {
                    IconCropView(image: img) { result in
                        showCrop = false
                        if let result { croppedIcon = result }
                    }
                }
            }
        }
    }

    private func fakeManual() {
        let clean: (String) -> String = { $0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces) }
        var la = Double(clean(manualLat)), lo = Double(clean(manualLong))
        if lo == nil, let pair = parseText(manualLat).first { la = pair.lat; lo = pair.long }   // pasted "lat, long"
        guard let la, let lo, (-90...90).contains(la), (-180...180).contains(lo) else {
            UIApplication.shared.alert(body: "Toạ độ không hợp lệ.")
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
                Text("Kéo và chụm 2 ngón để cắt ảnh")
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
                    Text("Xem trước:").foregroundColor(.white.opacity(0.8)).font(.footnote)
                    Image(uiImage: render(side: side, base: base, px: 180))
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                }
                Spacer()
                HStack {
                    Button("Huỷ") { onDone(nil) }
                        .foregroundColor(.white)
                    Spacer()
                    Button("Dùng ảnh này") { onDone(render(side: side, base: base, px: 1024)) }
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
