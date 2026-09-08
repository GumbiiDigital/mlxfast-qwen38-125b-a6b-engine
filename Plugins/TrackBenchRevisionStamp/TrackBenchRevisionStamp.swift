import Foundation
import PackagePlugin

/// Generates `BenchBuildRevision.swift` for this repository's `bench-worker`
/// before every build, so the hello names the revision the executable was
/// *built* from.
///
/// A MIRROR of the pinned fork's `Plugins/BenchRevisionStamp` (449f2d01),
/// which stamps the fork's own `bench-worker` target. This repository builds
/// its own `bench-worker` -- the one that registers the editable Runner in
/// `Runner/` -- and a plugin declared inside a dependency package cannot be
/// used from here (the fork exports no plugin product, and the fork is
/// pinned), so the stamp is declared again on this side. It stamps THIS
/// repository's revision, which is the tree that now carries the Runner.
///
/// A prebuild command (not a build command) because there is no input file to
/// key on: the revision changes when the checkout moves, not when a source
/// file does, so it must be recomputed on every build invocation. The script
/// rewrites the generated file only when the value actually changes, so a
/// no-op build stays a no-op.
@main
struct TrackBenchRevisionStamp: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let outputDirectory = context.pluginWorkDirectoryURL
            .appending(path: "GeneratedSources")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let script = context.package.directoryURL
            .appending(path: "tools/stamp-bench-revision.sh")
        return [
            .prebuildCommand(
                displayName: "Stamp bench-worker build revision",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    script.path(percentEncoded: false),
                    context.package.directoryURL.path(percentEncoded: false),
                    outputDirectory.appending(path: "BenchBuildRevision.swift")
                        .path(percentEncoded: false),
                ],
                outputFilesDirectory: outputDirectory)
        ]
    }
}
