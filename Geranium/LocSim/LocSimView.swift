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

struct LocSimView: View {
    @State private var altitude: String = "0.0"
    @State private var centerCoordinate: CLLocationCoordinate2D? = nil
    @State private var recenterTick = 0
    @State private var focusCoordinate: EquatableCoordinate? = nil
    @State private var bookmarkSheet = false
    @State private var isFaking = false

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { main }
        } else {
            NavigationView { main }.navigationViewStyle(.stack)
        }
    }

    private var main: some View {
        ZStack {
            CustomMapView(centerCoordinate: $centerCoordinate,
                          recenterTick: recenterTick,
                          focusCoordinate: focusCoordinate)
                .ignoresSafeArea(edges: .bottom)

            CenterPin()

            VStack {
                Spacer()
                bottomPanel
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            LocationModel().requestAuthorisation()
            CLLocationManager().requestAlwaysAuthorization()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Text("LocSim").font(.title2).bold()
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: enterCoordinates) {
                    Image(systemName: "number")
                }
                Button(action: setAltitude) {
                    Image(systemName: "mountain.2.fill")
                }
                Button { bookmarkSheet = true } label: {
                    Image(systemName: "list.star")
                }
            }
        }
        .sheet(isPresented: $bookmarkSheet) {
            BookMarkSlider { bookmark in
                let coord = CLLocationCoordinate2D(latitude: bookmark.lat, longitude: bookmark.long)
                fake(wgs: coord, save: false)
                // Show it on the map (map uses GCJ in China, WGS elsewhere).
                focusCoordinate = EquatableCoordinate(coordinate: CoordTransform.wgs84ToGcj02(coord))
            }
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(coordinateText)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    recenterTick += 1
                } label: {
                    Image(systemName: "location.fill")
                        .padding(8)
                        .background(Circle().fill(Color(.systemBackground)))
                }
            }

            HStack(spacing: 10) {
                Button(action: startAtPin) {
                    Label("Bắt đầu", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                        .foregroundColor(.white)
                }
                Button(action: stop) {
                    Label("Dừng", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(isFaking ? Color.red : Color.gray.opacity(0.6)))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
        // Map coordinates are GCJ-02 inside China, WGS-84 elsewhere; convert to real GPS.
        fake(wgs: CoordTransform.gcj02ToWgs84(center), save: true)
    }

    private func fake(wgs: CLLocationCoordinate2D, save: Bool) {
        let alt = Double(altitude) ?? 0.0
        let location = CLLocation(coordinate: wgs, altitude: alt,
                                  horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        LocSimManager.startLocSim(location: location)
        isFaking = true
        if save {
            autoSaveFakedLocation(lat: wgs.latitude, long: wgs.longitude)
        }
        AlertKitAPI.present(title: save ? "Đã bắt đầu & đã lưu" : "Đã bắt đầu",
                            icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func stop() {
        LocSimManager.stopLocSim()
        isFaking = false
        AlertKitAPI.present(title: "Đã dừng", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func enterCoordinates() {
        UIApplication.shared.TextFieldAlert(
            title: "Nhập toạ độ",
            message: "Vị trí sẽ được fake và lưu lại.",
            textFieldPlaceHolder: "Vĩ độ (latitude)",
            secondTextFieldPlaceHolder: "Kinh độ (longitude)"
        ) { latText, longText in
            let clean: (String?) -> Double? = { Double(($0 ?? "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
            guard let la = clean(latText), let lo = clean(longText),
                  (-90...90).contains(la), (-180...180).contains(lo) else {
                UIApplication.shared.alert(body: "Toạ độ không hợp lệ.")
                return
            }
            let typed = CLLocationCoordinate2D(latitude: la, longitude: lo)
            fake(wgs: CoordTransform.gcj02ToWgs84(typed), save: true)
            focusCoordinate = EquatableCoordinate(coordinate: typed)
        }
    }

    private func setAltitude() {
        UIApplication.shared.TextFieldAlert(
            title: "Độ cao",
            message: "Nhập độ cao (mét).",
            textFieldPlaceHolder: "Độ cao (m)"
        ) { altitudeText, _ in
            if let t = altitudeText, Double(t) != nil {
                altitude = t
                AlertKitAPI.present(title: "Đã đặt độ cao", icon: .done, style: .iOS17AppleMusic, haptic: .success)
            }
        }
    }
}
