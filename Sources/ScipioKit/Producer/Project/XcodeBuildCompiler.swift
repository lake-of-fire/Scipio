import Foundation
import PackageGraph
import TSCBasic

struct XcodeBuildCompiler<E: Executor>: Compiler {
    let rootPackage: Package
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem
    private let xcodebuild: XcodeBuildClient<E>
    private let extractor: DwarfExtractor<E>

    init(
        rootPackage: Package,
        buildOptions: BuildOptions,
        executor: E = ProcessExecutor(),
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
        self.xcodebuild = XcodeBuildClient(executor: executor)
        self.extractor = DwarfExtractor(executor: executor)
    }

    func createXCFramework(
        buildProduct: BuildProduct,
        outputDirectory: URL,
        overwrite: Bool
    ) async throws {
        let buildConfiguration = buildOptions.buildConfiguration
        let sdks = buildOptions.sdks
        let target = buildProduct.target

        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await xcodebuild.archive(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)
        }

        logger.info("🚀 Combining into XCFramework...")

        let debugSymbolPaths: [URL]?
        if buildOptions.isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildConfiguration,
                                                                 sdks: Set(sdks))
        } else {
            debugSymbolPaths = nil
        }

        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = outputDirectory.appendingPathComponent(frameworkName)
        if fileSystem.exists(outputXCFrameworkPath.absolutePath) && overwrite {
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputXCFrameworkPath.absolutePath)
        }

        try await xcodebuild.createXCFramework(
            package: rootPackage,
            buildProduct: buildProduct,
            buildConfiguration: buildConfiguration,
            sdks: Set(sdks),
            debugSymbolPaths: debugSymbolPaths,
            outputDir: outputDirectory
        )
    }
}

extension Package {
    var archivesPath: URL {
        workspaceDirectory.appendingPathComponent("archives")
    }
}
