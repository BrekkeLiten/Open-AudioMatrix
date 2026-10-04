import AppKit
import AudioMatrixCore
import SwiftUI

@MainActor
enum AppIconLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(for bundleID: String) -> NSImage {
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image: NSImage
        if SourceCatalog.isSystemSoundsBundleID(bundleID) {
            image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 1, height: 1))
        } else if SourceCatalog.isInputDeviceBundleID(bundleID) {
            image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 1, height: 1))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 1, height: 1))
        }

        cache.setObject(image, forKey: key)
        return image
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = MatrixTheme.appIconSize

    var body: some View {
        Image(nsImage: AppIconLoader.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
