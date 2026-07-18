//
//  Quick_ReaderApp.swift
//  Quick Reader
//
//  Created by Bennett Atwood on 5/17/26.
//

import SwiftUI

@main
struct Quick_ReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 600, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
        #endif
    }
}
