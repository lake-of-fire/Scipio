import Foundation
import PackageGraph
import XcodeProj
import AEXML
import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath
import var TSCBasic.localFileSystem
import func TSCBasic.walk
import struct PackageLoading.ModuleMapGenerator
import enum PackageLoading.GeneratedModuleMapType
import PackageModel
import Basics
import PathKit

class ProjectGenerator {
    private let package: Package
    private let pbxProj: PBXProj
    private let fileSystem: any FileSystem

    private let buildOptions: BuildOptions

    init(
        package: Package,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.package = package
        self.buildOptions = buildOptions
        self.pbxProj = .init()
        self.fileSystem = fileSystem
    }

    private func preparePBXProj() {
        let mainGroup = addObject(
            PBXGroup(
                children: [],
                sourceTree: .group
            )
        )

        let buildSettingsGenerator = ProjectBuildSettingsGenerator()

        let debugConfiguration = addObject(
            buildSettingsGenerator.generate(configuration: .debug)
        )
        let releaseConfiguration = addObject(
            buildSettingsGenerator.generate(configuration: .release)
        )

        let buildConfigurationList = addObject(
            XCConfigurationList(
                buildConfigurations: [
                    debugConfiguration,
                    releaseConfiguration,
                ],
                defaultConfigurationName: buildOptions.buildConfiguration.settingsValue,
                defaultConfigurationIsVisible: true
            )
        )

        let productGroup = addObject(
            PBXGroup(
                sourceTree: .buildProductsDir,
                name: "Products",
                path: nil
            )
        )

        let rootObject = addObject(
            PBXProject(
                name: package.manifest.displayName,
                buildConfigurationList: buildConfigurationList,
                compatibilityVersion: "Xcode 11.0",
                mainGroup: mainGroup,
                productsGroup: productGroup
            )
        )
        pbxProj.rootObject = rootObject
        
    }

    enum Error: LocalizedError {
        case invalidPackage
        case notSupported(PackageModel.Target.Kind)
        case unknownError
    }

    @discardableResult
    private func addObject<T: PBXObject>(_ object: T, context: String? = nil) -> T {
        pbxProj.add(object: object)
        object.context = context
        return object
    }

    private var sourceRoot: AbsolutePath? {
        return package.graph.rootPackages.first?.path
    }

    func generate() throws {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        preparePBXProj()

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage
        }
        pbxProj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        try generateTargets()

        let projectFile = XcodeProj(workspace: .init(),
                                    pbxproj: pbxProj)
        try projectFile.write(pathString: projectPath.path, override: true)
    }

    private func generateTargets() throws {
        // First, generate all library targets
        let targetsToGenerate = package.graph.reachableTargets
            .filter { $0.type == .library }
            .sorted { $0.name < $1.name }
        let xcodeTargets: [ResolvedTarget: PBXNativeTarget] = try targetsToGenerate.reduce(into: [:]) { targets, target in
            let xcodeTarget = addObject(
                try makeTarget(for: target)
            )
            targets[target] = xcodeTarget
        }
        xcodeTargets.values.forEach { self.pbxProj.rootObject?.targets.append($0) }

        let clangTargets = xcodeTargets.map({ ($0.key.underlyingTarget as? ClangTarget, $0.value) })
        let moduleMaps = try clangTargets.compactMap { clangTarget, xcodeTarget in
            if let clangTarget {
                return try applyClangTargetSpecificSettings(for: clangTarget, xcodeTarget: xcodeTarget, targetGroup: pbxProj.rootGroup()!)
            }
            return nil
        }

        // Make LinkPhase for each Xcode targets
        for (target, xcodeTarget) in xcodeTargets {
            let dependsTargets = try target.recursiveDependencies().compactMap { value in
                if case .target(let dependency, _) = value {
                    return (xcodeTargets[dependency])
                }
                return nil
            }
            xcodeTarget.dependencies = dependsTargets.map { target in
                addObject(PBXTargetDependency(target: target))
            }

            let linkReferences: [PBXBuildFile]
            if target.type == .library {
                linkReferences = dependsTargets.map { dependency in
                    addObject(PBXBuildFile(file: dependency.product))
                }
            } else {
                linkReferences = []
            }

            let linkPhase = addObject(
                PBXFrameworksBuildPhase(files: linkReferences)
            )
            xcodeTarget.buildPhases.append(linkPhase)

            // TODO Add -fmodule-map-file for Swift targets
        }
    }

    private func makeTarget(for target: ResolvedTarget) throws -> PBXNativeTarget {
        let targetSettingsGenerator = TargetBuildSettingsGenerator(
            package: package,
            isDebugSymbolsEmbedded: buildOptions.isDebugSymbolsEmbedded,
            isStaticFramework: buildOptions.frameworkType == .static
        )

        let productType: PBXProductType
        switch target.type {
        case .executable, .snippet:
            productType = .commandLineTool
        case .library:
            productType = .framework
        case .test:
            productType = .unitTestBundle
        case .binary, .systemModule, .plugin:
            throw Error.notSupported(target.type)
        }

        // Generate Info.plist
        let plistPath = package.projectPath.appendingPathComponent(target.infoPlistFileName)
        fileSystem.write(infoPlist.data(using: .utf8)!, to: plistPath)

        let buildConfigurationList = addObject(
            XCConfigurationList(buildConfigurations: [
                addObject(targetSettingsGenerator.generate(for: target, configuration: .debug, infoPlistPath: plistPath)),
                addObject(targetSettingsGenerator.generate(for: target, configuration: .release, infoPlistPath: plistPath)),
            ])
        )

        let productRef: PBXFileReference?
        if let productGroup = pbxProj.rootObject?.productsGroup {
            productRef = try productGroup.addFile(
                at: target.productPath.toPath(),
                sourceTree: .buildProductsDir,
                sourceRoot: .init("."),
                validatePresence: false
            )
        } else {
            productRef = nil
        }

        guard let sourceRoot = sourceRoot else {
            throw Error.unknownError
        }

        guard let mainGroup = pbxProj.rootObject?.mainGroup else {
            throw Error.unknownError
        }

        let targetRootGroup = try mainGroup.addGroup(named: target.name, options: .withoutFolder).first!

        let fileReferences = try target.sources.paths.map { sourcePath in
           let group = try self.group(
                for: sourcePath.parentDirectory,
                parentGroup: targetRootGroup,
                sourceRoot: target.sources.root
            )
            return try group.addFile(
                at: sourcePath.toPath(),
                sourceTree: .sourceRoot,
                sourceRoot: sourceRoot.toPath()
            )
        }

        let buildFiles: [PBXBuildFile] = fileReferences.map { reference in
            return addObject(PBXBuildFile(file: reference))
        }

        let compilePhase = addObject(
            PBXSourcesBuildPhase(
                files: buildFiles
            )
        )

        // TODO Add Resources

        return PBXNativeTarget(name: target.c99name,
                               buildConfigurationList: buildConfigurationList,
                               buildPhases: [compilePhase],
                               product: productRef,
                               productType: productType)
    }

    private func applyClangTargetSpecificSettings(for clangTarget: ClangTarget, xcodeTarget: PBXNativeTarget, targetGroup: PBXGroup) throws -> AbsolutePath? {
        let includeDir = clangTarget.includeDir
        let includeGroup = try group(for: includeDir,
                                     parentGroup: targetGroup,
                                     sourceRoot: clangTarget.sources.root)
        let headerFiles = try walk(includeDir).filter { $0.extension == "h" }
        var headerFileRefs: [PBXFileReference] = []
        for header in headerFiles {
            let includeGroup = try self.group(
                for: header.parentDirectory,
                parentGroup: includeGroup,
                sourceRoot: includeDir
            )
            let fileRef = try includeGroup.addFile(at: header.toPath(),
                                                   sourceRoot: includeDir.toPath())
            headerFileRefs.append(fileRef)
        }
        return try prepareModuleMap(for: clangTarget, xcodeTarget: xcodeTarget, includeFileRefs: headerFileRefs)
    }

    private func prepareModuleMap(for clangTarget: ClangTarget, xcodeTarget: PBXNativeTarget, includeFileRefs: [PBXFileReference]) throws -> AbsolutePath? {
        let headerFiles = try walk(clangTarget.includeDir).filter { $0.extension == "h" }

        let hasUmbrellaHeader = headerFiles
            .map { $0.basenameWithoutExt }
            .contains(clangTarget.c99name)

        if case .custom(let path) = clangTarget.moduleMapType {
            return path
        } else if hasUmbrellaHeader {
            let files = includeFileRefs.map { fileRef in
                PBXBuildFile(file: fileRef, settings: ["ATTRIBUTES": "Public"])
            }
            let headerPhase = addObject(
                PBXHeadersBuildPhase(files: files)
            )

            xcodeTarget.buildPhases.append(headerPhase)
            return nil
        } else if let generatedModuleMapType = clangTarget.moduleMapType.generatedModuleMapType {
            let generatedModuleMapPath = try generateModuleMap(for: clangTarget, moduleMapType: generatedModuleMapType)
            return generatedModuleMapPath
        }
        return nil
    }

    private func generateModuleMap(for clangTarget: ClangTarget, moduleMapType: GeneratedModuleMapType) throws -> AbsolutePath {
        let fileSystem = TSCBasic.localFileSystem
        let moduleMapPath = try AbsolutePath(validating: package.projectPath.path)
            .appending(components: "GeneratedModuleMap", clangTarget.c99name, "module.modulemap")
        try fileSystem.createDirectory(moduleMapPath, recursive: true)

        let moduleMapGenerator = ModuleMapGenerator(
            targetName: clangTarget.name,
            moduleName: clangTarget.c99name,
            publicHeadersDir: clangTarget.includeDir,
            fileSystem: fileSystem
        )
        try moduleMapGenerator.generateModuleMap(type: moduleMapType,
                                                 at: moduleMapPath)
        return moduleMapPath
    }

    private func link(to moduleMap: AbsolutePath) throws {

    }

    /// Helper function to create or get group recursively
    private func group(
        for path: AbsolutePath,
        parentGroup: PBXGroup,
        sourceRoot: AbsolutePath
    ) throws -> PBXGroup {
        let groupName = path.components.last!
        let relativePath = path.relative(to: sourceRoot)
        let pathComponents = relativePath.components.filter { !["."].contains($0) }

        if let nextPathComponent = pathComponents.first {
            let nextSourceRoot = sourceRoot.appending(component: nextPathComponent)
            return try group(for: path, parentGroup: parentGroup, sourceRoot: nextSourceRoot)
        } else {
            if let existingGroup = parentGroup.group(named: groupName) {
                return existingGroup
            } else {
                return parentGroup
            }
        }
    }
}

extension AbsolutePath {
    fileprivate func toPath() -> PathKit.Path {
        .init(self.pathString)
    }
}

extension RelativePath {
    fileprivate func toPath() -> PathKit.Path {
        .init(self.pathString)
    }
}

extension PBXGroup {
    fileprivate func addChild(_ childGroup: PBXGroup) {
        childGroup.parent = self
        self.children.append(childGroup)
    }
}

extension ResolvedTarget {
    fileprivate var productPath: RelativePath {
        switch type {
        case .test:
            return RelativePath("\(c99name).xctest")
        case .library:
            return RelativePath("\(c99name).framework")
        case .executable, .snippet:
            return RelativePath(name)
        case .systemModule, .binary, .plugin:
            fatalError()
        }
    }

    fileprivate var infoPlistFileName: String {
        return "\(c99name)_Info.plist"
    }
}

private var infoPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSPrincipalClass</key>
    <string></string>
    </dict>
    </plist>
    """
}
