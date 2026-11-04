//
//  LocSimManager.swift
//  Geranium
//
//  Created by Constantin Clerc on 12.11.2022.
//

import Foundation
import CoreLocation


class LocSimManager {
    static let simManager = CLSimulationManager()
    
    /// Updates timezone
    static func post_required_timezone_update(){
        CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(), .init("AutomaticTimeZoneUpdateNeeded" as CFString), nil, nil, kCFNotificationDeliverImmediately);
    }
    
    // All commands go through one queue, so fast hops can never pile up inside iOS.
    private static let queue = DispatchQueue(label: "locsim.commands")
    private static let lock = NSLock()
    private static var _gen = 0
    private static var _busy = false
    private static var gen: Int { lock.lock(); defer { lock.unlock() }; return _gen }
    private static func bump() -> Int { lock.lock(); defer { lock.unlock() }; _gen += 1; return _gen }

    private static func doStart(_ location: CLLocation, _ tz: Bool) {
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.appendSimulatedLocation(location)
        simManager.flush()
        simManager.startLocationSimulation()
        if tz { post_required_timezone_update() }
    }

    /// Simulates one location. `hop` = a hop jump: skipped if the previous one is still being handled,
    /// and dropped if anything else was asked meanwhile. Other calls cancel waiting hops and are
    /// sent again after 0.5 s and 1.5 s so nothing old can cover them.
    static func startLocSim(location: CLLocation, updateTimezone: Bool = true, hop: Bool = false) {
        if hop {
            lock.lock()
            if _busy { lock.unlock(); return }
            _busy = true
            let g = _gen
            lock.unlock()
            queue.async {
                if gen == g { doStart(location, updateTimezone) }
                lock.lock(); _busy = false; lock.unlock()
            }
            return
        }
        let g = bump()
        queue.async { if gen == g { doStart(location, updateTimezone) } }
        for delay in [0.5, 1.5] {
            queue.asyncAfter(deadline: .now() + delay) {
                if gen == g { doStart(location.withNewTimestamp(), false) }
            }
        }
    }

    /// Plays a whole list of locations (one every `interval` s) inside iOS itself,
    /// so it keeps going when the app is in the background or closed.
    static func playRoute(_ locations: [CLLocation], interval: Double, loop: Bool) {
        guard !locations.isEmpty else { return }
        let g = bump()
        queue.async {
            guard gen == g else { return }
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.locationDeliveryBehavior = 0
            simManager.locationRepeatBehavior = loop ? 2 : 0
            simManager.locationInterval = interval
            for l in locations { simManager.appendSimulatedLocation(l) }
            simManager.flush()
            simManager.startLocationSimulation()
            post_required_timezone_update()
        }
    }

    private static func doStop() {
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.flush()
    }

    /// Stops location simulation (also repeated after 0.5 s and 1.5 s).
    static func stopLocSim() {
        let g = bump()
        queue.async { if gen == g { doStop(); post_required_timezone_update() } }
        for delay in [0.5, 1.5] {
            queue.asyncAfter(deadline: .now() + delay) { if gen == g { doStop() } }
        }
    }
}

extension CLLocation {
    func withNewTimestamp() -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: horizontalAccuracy,
                   verticalAccuracy: verticalAccuracy, course: course, speed: speed, timestamp: Date())
    }
}


struct EquatableCoordinate: Equatable {
    var coordinate: CLLocationCoordinate2D
    
    static func ==(lhs: EquatableCoordinate, rhs: EquatableCoordinate) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}


// https://stackoverflow.com/a/75703059

class LocationModel: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    @Published var authorisationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        self.locationManager.delegate = self
    }

    public func requestAuthorisation(always: Bool = false) {
        if always {
            self.locationManager.requestAlwaysAuthorization()
        } else {
            self.locationManager.requestWhenInUseAuthorization()
        }
    }
}

extension LocationModel: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.authorisationStatus = status
    }
}
