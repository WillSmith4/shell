import Foundation
import UIKit
import ios_system

@main
enum CommandEnvironmentCheck {
    static func value(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        initializeEnvironment()
        for identifier in ["AsheKube.app.a-Shell", "AsheKube.app.a-Shell.TESTTEAM"] {
            let testRoot = root.appendingPathComponent(identifier, isDirectory: true)
            let library = testRoot.appendingPathComponent("Library", isDirectory: true)
            let documents = testRoot.appendingPathComponent("Documents", isDirectory: true)
            let bundleURL = testRoot.appendingPathComponent("Host.bundle", isDirectory: true)
            for url in [library, documents, bundleURL] {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "a-Shell",
                                       "CFBundlePackageType": "BNDL"]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: bundleURL) else { fatalError("Cannot load test bundle") }
            unsetenv("PATH")
            unsetenv("GROUP")
            unsetenv("SHORTCUTS")
            initializeCommandEnvironment(hostBundle: bundle, documentsUrl: documents,
                                         libraryURL: library, groupURL: nil)
            let fallback = library.appendingPathComponent("Application Support/a-Shell/LocalGroup", isDirectory: true)
            precondition(value("GROUP") == fallback.path)
            precondition(value("SHORTCUTS") == fallback.path)
            precondition(value("APPVERSION") == "unknown")
            precondition(value("APPBUILDNUMBER") == "unknown")
            precondition(value("PATH") != nil)
            for relative in ["Library/codex", "Library/gemini/.gemini"] {
                let directory = fallback.appendingPathComponent(relative, isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("writable".utf8).write(to: directory.appendingPathComponent("fixture"))
            }
            print("PASS missing App Group, missing PATH, writable Codex/Gemini state: \(identifier)")

            let shared = testRoot.appendingPathComponent("Shared", isDirectory: true)
            try manager.createDirectory(at: shared, withIntermediateDirectories: true)
            initializeCommandEnvironment(hostBundle: bundle, documentsUrl: documents,
                                         libraryURL: library, groupURL: shared)
            precondition(value("GROUP") == shared.path)
            precondition(value("SHORTCUTS") == shared.path)
            print("PASS existing App Group preserved: \(identifier)")
        }
        let collisionLibrary = root.appendingPathComponent("CollisionLibrary", isDirectory: true)
        let parent = collisionLibrary.appendingPathComponent("Application Support/a-Shell", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let collision = parent.appendingPathComponent("LocalGroup")
        try Data("keep".utf8).write(to: collision)
        precondition(commandGroupDirectory(groupURL: nil, libraryURL: collisionLibrary) == collisionLibrary)
        let preserved = try Data(contentsOf: collision)
        precondition(preserved == Data("keep".utf8))
        print("PASS fallback creation error returns existing Library without deleting files")
    }
}
