import Foundation

/// Separate development state from the installed app, including launches outside the Makefile.
enum AppPaths {
    struct Launch {
        let dataDirectory: URL
        let legacyDirectory: URL?
    }

    static var launch: Launch {
        #if DEBUG
            let isDebug = true
        #else
            let isDebug = false
        #endif
        return launch(
            environment: ProcessInfo.processInfo.environment, isDebug: isDebug,
            isTesting: NSClassFromString("XCTestCase") != nil)
    }

    static var dataDirectory: URL { launch.dataDirectory }

    static func launch(
        environment: [String: String], isDebug: Bool, isTesting: Bool = false,
        applicationSupport: URL = .applicationSupportDirectory
    ) -> Launch {
        if let path = environment["HANDSHAKE_DATA_DIRECTORY"] ?? environment["TWINE_DATA_DIRECTORY"] {
            return Launch(dataDirectory: URL(filePath: path, directoryHint: .isDirectory), legacyDirectory: nil)
        }
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return Launch(dataDirectory: previewDirectory, legacyDirectory: nil)
        }
        let isTestHost = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        if isDebug || isTesting || isTestHost {
            return Launch(dataDirectory: developmentDirectory, legacyDirectory: nil)
        }
        return Launch(
            dataDirectory: applicationSupport.appending(path: "Handshake", directoryHint: .isDirectory),
            legacyDirectory: applicationSupport.appending(path: "Twine", directoryHint: .isDirectory))
    }

    static var previewDirectory: URL {
        developmentDirectory.appending(path: "previews", directoryHint: .isDirectory)
    }

    private static var developmentDirectory: URL {
        // Bind developer state to the checkout that built the app, including previews and test hosts.
        return DevelopmentPaths.checkoutDirectory.appending(path: "out/runtime/debug")
    }
}
