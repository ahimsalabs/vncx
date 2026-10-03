import Foundation

/// Which build this is. Local builds are "vncx Dev" (net.ahimsalabs.vncx.dev) and keep their own preferences,
/// saved computers, thumbnails and Keychain items, so testing never touches the installed release's data.
enum AppIdentity {
    static let releaseBundleID = "net.ahimsalabs.vncx"
    static let bundleID = Bundle.main.bundleIdentifier ?? "net.ahimsalabs.vncx.dev"
    static let isDev = bundleID != releaseBundleID
    static let name = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? (isDev ? "vncx Dev" : "vncx")

    /// Keychain service for saved passwords. The release keeps the original name so existing items still match.
    static var keychainService: String { bundleID }

    /// Folder under Application Support for saved computers and thumbnails.
    static var dataFolderName: String { isDev ? "vncx-dev" : "vncx" }
}
