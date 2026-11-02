//
//  CustomMapView.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//  Modified: no tap-to-move. The map just reports its centre (under the fixed pin).
//

import SwiftUI
import MapKit

struct CustomMapView: UIViewRepresentable {
    /// Coordinate currently under the centre pin.
    @Binding var centerCoordinate: CLLocationCoordinate2D?
    /// Increment to re-centre the map on the device location.
    var recenterTick: Int
    /// Set to move the map to a coordinate (e.g. when a saved location is started).
    var focusCoordinate: EquatableCoordinate?
    /// Zoom from the slider (keeps the centre).
    var zoomRequest: ZoomRequest? = nil
    /// Reports the zoom level (0 far … 1 close) after the map moves.
    var onZoomChanged: ((Double) -> Void)? = nil
    /// "standard", "satellite" or "hybrid" (Settings).
    var mapType: String = "standard"

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.pointOfInterestFilter = .includingAll
        // Allow zooming in closer than the default limit.
        mapView.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 15), animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let c = context.coordinator
        let wanted: MKMapType = mapType == "satellite" ? .satellite : (mapType == "hybrid" ? .hybrid : .standard)
        if mapView.mapType != wanted { mapView.mapType = wanted }
        if recenterTick != c.lastRecenterTick {
            c.lastRecenterTick = recenterTick
            if let loc = mapView.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) {
                mapView.setCenter(loc, animated: true)   // keep the current zoom level
            }
        }
        if let z = zoomRequest, z.id != c.lastZoomID, z.reset {
            c.lastZoomID = z.id
            mapView.setRegion(MKCoordinateRegion(center: mapView.centerCoordinate,
                                                 latitudinalMeters: 600, longitudinalMeters: 600), animated: true)
        }
        if let z = zoomRequest, z.id != c.lastZoomID {
            c.lastZoomID = z.id
            let cam = mapView.camera.copy() as! MKMapCamera
            cam.centerCoordinate = mapView.centerCoordinate
            cam.centerCoordinateDistance = ZoomScale.distance(for: z.level)
            c.applyingZoom = true
            mapView.setCamera(cam, animated: false)
        }
        if focusCoordinate == nil { c.lastFocus = nil }
        if let focus = focusCoordinate, focus != c.lastFocus {
            c.lastFocus = focus
            mapView.setCenter(focus.coordinate, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CustomMapView
        var lastRecenterTick = 0
        var lastFocus: EquatableCoordinate?
        var lastZoomID: UUID?
        var applyingZoom = false
        private var didInitialCenter = false

        init(_ parent: CustomMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            let level = ZoomScale.level(for: mapView.camera.centerCoordinateDistance)
            let fromSlider = applyingZoom
            applyingZoom = false
            DispatchQueue.main.async {
                self.parent.centerCoordinate = center
                if !fromSlider { self.parent.onZoomChanged?(level) }
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // Centre on the device once, when the app opens.
            guard !didInitialCenter, let loc = userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) else { return }
            didInitialCenter = true
            mapView.setRegion(MKCoordinateRegion(center: loc, latitudinalMeters: 600, longitudinalMeters: 600), animated: false)
        }
    }
}

/// Thin needle pin. The very bottom tip of the needle is the exact map centre.
struct CenterPin: View {
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: 23)   // 1-2 px needle
            }
            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
            // Lift the needle so its tip sits exactly on the centre point.
            .offset(y: -17.5)

            // Tiny dot marking the exact point.
            Circle()
                .fill(Color.black)
                .frame(width: 3, height: 3)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}

struct ZoomRequest: Equatable {
    let id = UUID()
    var level: Double = 0.5
    /// true = back to the standard zoom (about 600 m across, like when the app opens).
    var reset: Bool = false
}

/// Maps slider level 0…1 to camera distance (log scale): 0 = 400 km, 1 = 15 m.
enum ZoomScale {
    static let far: Double = 400_000
    static let near: Double = 15
    static func distance(for level: Double) -> Double {
        far * pow(near / far, min(max(level, 0), 1))
    }
    static func level(for distance: Double) -> Double {
        let d = min(max(distance, near), far)
        return log(d / far) / log(near / far)
    }
}

/// Thin vertical slider. Top = zoomed out, bottom = zoomed in.
struct ZoomSlider: View {
    @Binding var level: Double
    var onChange: (Double) -> Void
    var onReset: () -> Void = {}
    private let height: CGFloat = 220

    var body: some View {
        VStack(spacing: 6) {
            // Reset to the standard zoom
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(.systemBackground)))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            ZStack(alignment: .top) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 4, height: height)
                Capsule().fill(Color.accentColor).frame(width: 4, height: CGFloat(level) * height)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: CGFloat(level) * height - 11)
            }
            .frame(width: 30, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let l = Double(min(max(v.location.y / height, 0), 1))
                        level = l
                        onChange(l)
                    }
            )
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}
