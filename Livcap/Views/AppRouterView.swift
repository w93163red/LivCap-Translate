//
//  AppRouterView.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/8/25.
//

import SwiftUI

struct AppRouterView: View {
    @StateObject private var permissionManager = PermissionManager.shared
    @State private var hasInitialized = false

    var body: some View {
        VStack(spacing: 0) {
            // Warning banner for denied permissions (appears at top if needed)
            PermissionWarningBanner(permissionManager: permissionManager)

            // Always show CaptionView (no more permission blocking)
            CaptionView()
        }
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                permissionManager.checkDeniedPermissionsOnLoad()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.checkDeniedPermissionsOnLoad()
        }
    }
}

#Preview {
    AppRouterView()
}
