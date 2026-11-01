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

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.pointOfInterestFilter = .includingAll
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let c = context.coordinator
        if recenterTick != c.lastRecenterTick {
            c.lastRecenterTick = recenterTick
            if let loc = mapView.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) {
                mapView.setCenter(loc, animated: true)   // keep the current zoom level
            }
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
        private var didInitialCenter = false

        init(_ parent: CustomMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            DispatchQueue.main.async {
                self.parent.centerCoordinate = center
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
                    .frame(width: 1.5, height: 34)   // 1-2 px needle
            }
            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
            // Lift the needle so its tip sits exactly on the centre point.
            .offset(y: -23)

            // Tiny dot marking the exact point.
            Circle()
                .fill(Color.black)
                .frame(width: 3, height: 3)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}
