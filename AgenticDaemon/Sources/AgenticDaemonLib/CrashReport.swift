import Foundation

public struct CrashReport: Codable, Sendable {
    public let jobName: String
    public let timestamp: Date
    public let signal: String?
    public let exceptionType: String?
    public let faultingThread: Int?
    public let stackTrace: [StackFrame]?
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case plcrash
        case diagnosticReport
    }

    public struct StackFrame: Codable, Sendable {
        public let symbol: String?
        public let imageOffset: Int?
        public let sourceFile: String?
        public let sourceLine: Int?

        public init(symbol: String?, imageOffset: Int?, sourceFile: String?, sourceLine: Int?) {
            self.symbol = symbol
            self.imageOffset = imageOffset
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
        }
    }

    public init(
        jobName: String,
        timestamp: Date,
        signal: String?,
        exceptionType: String?,
        faultingThread: Int?,
        stackTrace: [StackFrame]?,
        source: Source
    ) {
        self.jobName = jobName
        self.timestamp = timestamp
        self.signal = signal
        self.exceptionType = exceptionType
        self.faultingThread = faultingThread
        self.stackTrace = stackTrace
        self.source = source
    }
}
