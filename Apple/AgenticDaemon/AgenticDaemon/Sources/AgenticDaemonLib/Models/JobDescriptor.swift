import Foundation

public struct JobDescriptor: Sendable {
    public let name: String
    public let directory: URL
    public let sourceURL: URL
    public let binaryURL: URL
    public let config: JobConfig

    public init(
        name: String,
        directory: URL,
        sourceURL: URL,
        binaryURL: URL,
        config: JobConfig
    ) {
        self.name = name
        self.directory = directory
        self.sourceURL = sourceURL
        self.binaryURL = binaryURL
        self.config = config
    }
}
