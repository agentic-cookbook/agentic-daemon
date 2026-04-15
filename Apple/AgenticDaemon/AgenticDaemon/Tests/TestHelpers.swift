import Foundation
@testable import AgenticDaemonLib

/// Creates a temporary directory for test isolation. Caller must clean up.
func makeTempDir(prefix: String = "agenticd-test") -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

/// Creates a job directory with an optional job.swift and config.json.
@discardableResult
func createJobDir(
    in parent: URL,
    name: String,
    swiftSource: String? = "import Foundation\nprint(\"hello\")\n",
    configJSON: String? = nil
) -> URL {
    let jobDir = parent.appending(path: name)
    try! FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

    if let source = swiftSource {
        let sourceURL = jobDir.appending(path: "job.swift")
        try! source.write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    if let config = configJSON {
        let configURL = jobDir.appending(path: "config.json")
        try! config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    return jobDir
}

/// Builds a JobDescriptor pointing at a real job directory.
func makeDescriptor(
    in parent: URL,
    name: String,
    config: JobConfig = .default
) -> JobDescriptor {
    let dir = parent.appending(path: name)
    let moduleName = name.replacingOccurrences(of: "-", with: "_")
    return JobDescriptor(
        name: name,
        directory: dir,
        sourceURL: dir.appending(path: "job.swift"),
        binaryURL: dir.appending(path: "lib\(moduleName).dylib"),
        config: config
    )
}

/// Removes a temporary directory.
func cleanupTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Returns a valid AgenticJob plugin source string.
func validJobSource(body: String = "") -> String {
    """
    import Foundation
    import AgenticJobKit

    class Job: AgenticJob {
        override func run(request: JobRequest) throws -> JobResponse {
            \(body)
            return JobResponse()
        }
    }
    """
}

/// Finds the build directory containing AgenticJobKit artifacts.
/// Under xcodebuild, AgenticJobKit.swiftmodule + libAgenticJobKit.dylib live
/// alongside the running xctest bundle in Build/Products/<Config>/. Under
/// `swift test`, they live at <package root>/.build/debug/.
func findBuildDir(file: String = #filePath) -> URL {
    if let products = Bundle.allBundles
        .lazy
        .map({ $0.bundleURL.deletingLastPathComponent() })
        .first(where: { dir in
            let fm = FileManager.default
            return fm.fileExists(atPath: dir.appending(path: "AgenticJobKit.swiftmodule").path)
                || fm.fileExists(atPath: dir.appending(path: "libAgenticJobKit.dylib").path)
        }) {
        return products
    }
    let testsDir = URL(fileURLWithPath: file).deletingLastPathComponent()
    let packageRoot = testsDir.deletingLastPathComponent()
    return packageRoot.appending(path: ".build/debug")
}
