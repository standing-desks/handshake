//
//  HandshakeUITests.swift
//  HandshakeUITests
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import SQLite3
import XCTest

final class HandshakeUITests: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
    }

    @MainActor
    func closeFolder(in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Close Folder"].click()
    }

    /// An app that keeps its data in a fresh temporary directory, deleted when the test ends, so each
    /// test starts clean and never touches the real data directory. `lastOpenFolder` seeds the data
    /// as if that folder was open when Handshake last quit.
    @MainActor
    func makeApp(lastOpenFolder: URL? = nil) throws -> XCUIApplication {
        let dataDirectory = try makeTestFolder(prefix: "com.twineproject.Twine.tests.ui")
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: dataDirectory.lastPathComponent)
        }
        if let lastOpenFolder {
            try seedDatabase(in: dataDirectory, lastOpenFolder: lastOpenFolder.path(percentEncoded: false))
        }
        let app = makeTestApplication()
        // A fresh core database also needs a fresh window. Ignore AppKit's saved window state,
        // including an empty window list left by a unit-test host or a previous UI test.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["HANDSHAKE_DATA_DIRECTORY"] = dataDirectory.path(percentEncoded: false)
        app.launchEnvironment["XDG_CONFIG_HOME"] = dataDirectory.appending(path: "config").path
        // Remember preferences across this app's relaunches without inheriting the user's saved zoom.
        app.launchEnvironment["HANDSHAKE_PREFERENCES_SUITE"] = dataDirectory.lastPathComponent
        return app
    }

    /// Writes the database an earlier launch would leave, in the first migration's schema. Handshake applies
    /// any later migrations when it opens it.
    private func seedDatabase(in directory: URL, lastOpenFolder path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE recent_folders (
                path TEXT PRIMARY KEY NOT NULL,
                last_opened_at INTEGER NOT NULL,
                is_open INTEGER NOT NULL DEFAULT 0 CHECK (is_open IN (0, 1))
            ) STRICT;
            INSERT INTO recent_folders VALUES ('\(path.replacingOccurrences(of: "'", with: "''"))', 1, 1);
            PRAGMA user_version = 1;
            """
        let file = directory.appending(path: "twine.db").path(percentEncoded: false)
        guard sqlite3_open(file, &database) == SQLITE_OK, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
        else {
            throw SeedError(message: String(cString: sqlite3_errmsg(database)))
        }
    }

}

private struct SeedError: Error {
    let message: String
}
