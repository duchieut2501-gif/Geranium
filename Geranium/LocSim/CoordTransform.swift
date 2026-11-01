//
//  CoordTransform.swift
//  Geranium
//
//  Created by acg7878 on 28.07.25.
//

import CoreLocation
import Foundation

/// A utility for converting coordinates between WGS-84 and GCJ-02.
struct CoordTransform {

    // MARK: - Geodetic Constants

    /// Semi-major axis of the Krasovsky 1940 ellipsoid, used for GCJ-02.
    private static let krasovskySemiMajorAxis = 6378245.0

    /// Squared eccentricity of the WGS-84 ellipsoid.
    private static let wgs84EccentricitySquared = 0.00669342162296594323

    /// Converts GCJ-02 (Mars Coordinates) to WGS-84 (World Geodetic System).
    /// This is the primary function needed for correcting the map offset.
    /// - Parameter gcjCoordinate: The coordinate obtained from a Chinese map (in GCJ-02).
    /// - Returns: The corrected coordinate in WGS-84.
    static func gcj02ToWgs84(_ gcjCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if isOutOfChina(gcjCoordinate) {
            return gcjCoordinate
        }

        let wgsCoordinate = reverseGeocode(gcjCoordinate)
        return wgsCoordinate
    }

    /// Converts WGS-84 (World Geodetic System) to GCJ-02 (Mars Coordinates).
    /// - Parameter wgsCoordinate: The coordinate from a standard GPS source (in WGS-84).
    /// - Returns: The coordinate ready to be displayed on a Chinese map (in GCJ-02).
    static func wgs84ToGcj02(_ wgsCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if isOutOfChina(wgsCoordinate) {
            return wgsCoordinate
        }
        return geocode(wgsCoordinate)
    }

    // MARK: - Core Transformation Logic

    /// Forward geocoding: Applies the GCJ-02 offset to a WGS-84 coordinate.
    private static func geocode(_ wgsCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var adjustedCoordinate = wgsCoordinate
        var latOffset = transformLatitude(
            x: wgsCoordinate.longitude - 105.0, y: wgsCoordinate.latitude - 35.0)
        var lonOffset = transformLongitude(
            x: wgsCoordinate.longitude - 105.0, y: wgsCoordinate.latitude - 35.0)

        let radLat = wgsCoordinate.latitude / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1 - wgs84EccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        latOffset =
            (latOffset * 180.0)
            / ((krasovskySemiMajorAxis * (1 - wgs84EccentricitySquared)) / (magic * sqrtMagic)
                * Double.pi)
        lonOffset =
            (lonOffset * 180.0) / (krasovskySemiMajorAxis / sqrtMagic * cos(radLat) * Double.pi)

        adjustedCoordinate.latitude += latOffset
        adjustedCoordinate.longitude += lonOffset

        return adjustedCoordinate
    }

    /// Reverse geocoding: Removes the GCJ-02 offset from a coordinate using iterative approximation.
    private static func reverseGeocode(_ gcjCoordinate: CLLocationCoordinate2D)
        -> CLLocationCoordinate2D
    {
        let initialPoint = gcjCoordinate
        let geocodedPoint = geocode(initialPoint)
        let latOffset = geocodedPoint.latitude - initialPoint.latitude
        let lonOffset = geocodedPoint.longitude - initialPoint.longitude

        return CLLocationCoordinate2D(
            latitude: initialPoint.latitude - latOffset,
            longitude: initialPoint.longitude - lonOffset
        )
    }

    /// Checks if a coordinate is outside of mainland China.
    /// The old single bounding box also covered Vietnam, Laos, Thailand, Korea, Japan...
    /// which shifted faked locations there by a few hundred metres. Use region rectangles instead.
    private static let chinaRegions: [(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)] = [
        (79.446200, 42.889900, 96.330000, 49.220400),
        (109.687200, 39.374200, 135.000200, 54.141500),
        (73.124600, 29.529700, 124.143255, 42.889900),
        (82.968400, 26.718600, 97.035200, 29.529700),
        (97.025300, 20.414096, 124.367395, 29.529700),
        (107.975793, 17.871542, 111.744104, 20.414096),
    ]
    private static let excludedRegions: [(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)] = [
        (119.921265, 21.785006, 122.497559, 25.398623), // Taiwan
        (101.865200, 20.098800, 106.665000, 22.284000), // Northern Vietnam / Laos
        (106.452500, 20.487800, 108.051000, 21.542200), // Northern Vietnam (coast)
        (102.140000, 20.098800, 105.300000, 22.400000), // Northern Vietnam (west)
        (103.200000, 22.284000, 104.150000, 22.490000), // Lao Cai
        (104.150000, 22.284000, 105.300000, 22.850000), // Ha Giang
        (105.300000, 22.284000, 106.700000, 22.800000), // Cao Bang / Ha Giang (south part)
        (106.700000, 21.542200, 107.350000, 22.000000), // Lang Son / Quang Ninh
        (109.032300, 50.325700, 119.127000, 55.817500), // Mongolia / Russia
        (127.456800, 49.557400, 137.022700, 55.817500), // Russia
        (131.266200, 42.569200, 137.022700, 44.892200), // Russia
        (124.500000, 37.400000, 131.000000, 43.000000), // Korea
    ]

    private static func isOutOfChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        func inside(_ r: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)) -> Bool {
            coordinate.longitude >= r.minLon && coordinate.longitude <= r.maxLon
                && coordinate.latitude >= r.minLat && coordinate.latitude <= r.maxLat
        }
        guard chinaRegions.contains(where: inside) else { return true }
        return excludedRegions.contains(where: inside)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var lat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        lat += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        lat += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        lat += (160.0 * sin(y / 12.0 * Double.pi) + 320 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return lat
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var lon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        lon += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        lon += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        lon += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return lon
    }
}
