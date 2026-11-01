//
//  GeraniumApp.swift
//  Geranium
//
//  Created by Constantin Clerc on 10/12/2023.
//

import SwiftUI
@main
struct GeraniumApp: App {
    // Location-simulation only build: no welcome screen, update check, cleaner, daemons, etc.
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppSettings: ObservableObject {
    @AppStorage("TSBypass") var tsBypass: Bool = false
    @AppStorage("UPDBypass") var updBypass: Bool = false
    @AppStorage("isLoggingAllowed") var loggingAllowed: Bool = true
    @AppStorage("isFirstRun") var isFirstRun: Bool = true
    @AppStorage("minimSizeC") var minimSizeC: Double = 50.0
    @AppStorage("keepCheckBoxesC") var keepCheckBoxesC: Bool = true
    @AppStorage("LocSimAttempts") var locSimAttemptNB: Int = 1
    @AppStorage("locSimMultipleAttempts") var locSimMultipleAttempts: Bool = false
    @AppStorage("usrUUID") var usrUUID: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    @AppStorage("languageCode") var languageCode: String = ""
    @AppStorage("defaultTab") var defaultTab: Int = 1 
    @AppStorage("firstCleanerTime") var firstCleanerTime: Bool = true
    @AppStorage("tmpClean") var tmpClean: Bool = true
    @AppStorage("getSizes") var getSizes: Bool = false
}

var langaugee: String = {
    if AppSettings().languageCode.isEmpty {
        return "\(Locale.current.languageCode ?? "en-US")"
    }
    else {
        return "\(Locale.current.languageCode ?? "en")-\(AppSettings().languageCode)"
    }
}()
