import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("SwiftCompiler", .serialized)
struct SwiftCompilerTests {
    let compiler: SwiftCompiler
    let tmpDir: URL

    init() {
        tmpDir = makeTempDir(prefix: "compiler")
        compiler = SwiftCompiler(buildDir: findBuildDir())
    }

    @Test("needsCompile returns true when no dylib exists")
    func needsCompileNoDylib() {
        createJobDir(in: tmpDir, name: "fresh", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "fresh")

        #expect(compiler.needsCompile(job: descriptor) == true)
        cleanupTempDir(tmpDir)
    }

    @Test("needsCompile returns false when dylib is newer than source")
    func needsCompileDylibNewer() throws {
        createJobDir(in: tmpDir, name: "cached", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "cached")

        try compiler.compile(job: descriptor)

        #expect(compiler.needsCompile(job: descriptor) == false)
        cleanupTempDir(tmpDir)
    }

    @Test("needsCompile returns true when source is newer than dylib")
    func needsCompileSourceNewer() throws {
        createJobDir(in: tmpDir, name: "updated", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "updated")

        try compiler.compile(job: descriptor)

        Thread.sleep(forTimeInterval: 1.0)
        let newSource = validJobSource(body: "let _ = 42")
        try newSource.write(to: descriptor.sourceURL, atomically: true, encoding: .utf8)

        #expect(compiler.needsCompile(job: descriptor) == true)
        cleanupTempDir(tmpDir)
    }

    @Test("compile produces dylib from valid AgenticJob source")
    func compilesValidSource() throws {
        createJobDir(in: tmpDir, name: "valid", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "valid")

        try compiler.compile(job: descriptor)

        let dylibPath = descriptor.binaryURL.path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: dylibPath))
        #expect(dylibPath.hasSuffix(".dylib"))
        cleanupTempDir(tmpDir)
    }

    @Test("compile throws for invalid source")
    func compilesInvalidSource() throws {
        createJobDir(in: tmpDir, name: "broken", swiftSource: "this is not valid swift }{}{")
        let descriptor = makeDescriptor(in: tmpDir, name: "broken")

        var didThrow = false
        do {
            try compiler.compile(job: descriptor)
        } catch is CompileError {
            didThrow = true
        }
        #expect(didThrow)
        cleanupTempDir(tmpDir)
    }
}
