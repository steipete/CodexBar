import Foundation

enum InstallOrigin {
    static func isHomebrewCask(appBundleURL: URL) -> Bool {
        let resolved = appBundleURL.resolvingSymlinksInPath()
        let path = resolved.path
        return path.contains("/Caskroom/") || path.contains("/Homebrew/Caskroom/")
    }
}
