#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Shared-owner install regression: production file staging and ACF writer, no Steam/network.

Exercises different/same install folders, repair, unrelated depots, failed copies,
path containment, custom executables and uninstall. Runs on macOS and Linux.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
checks = r'''
import Foundation

func read(_ id: Int, at apps: URL) throws -> SteamValue {
    var parser = try SteamKeyValues(Data(contentsOf: apps.appendingPathComponent("appmanifest_\(id).acf")))
    return try parser.read()["AppState"]!
}
func expectFailure(line: UInt = #line, _ action: () throws -> Void) {
    do { try action(); fatalError("expected failure at line \(line)") } catch {}
}

@main struct Checks {
    static func main() async throws {
        var game = SteamAppInfo(appID: 9000, name: "Consumer", installDir: "Consumer")
        game.depots = [.init(depotID: 9003, manifests: ["public": 300], fromApp: 9100)]
        var dependency = SteamAppInfo(appID: 9100, name: "Dependency", installDir: "Dependency")
        dependency.depots = [.init(depotID: 9003, manifests: ["public": 300])]
        let fetcher = FixtureFetcher()
        fetcher.infos = [9000: game, 9100: dependency]
        let resolved = try await fetcher.fetchInstallInfo(appID: 9000)
        assert(resolved?.sharedOwners[9100]?.installDir == "Dependency")
        assert(fetcher.requests == [9000, 9100], "owner metadata is needed even if the consumer already publishes the manifest")
        game.depots[0].manifests = [:]
        fetcher.infos[9000] = game
        let inherited = try await fetcher.fetchInstallInfo(appID: 9000)
        assert(inherited?.depots[0].publicManifestID == 300)
        game.depots[0].manifests = ["public": 300]
        fetcher.infos[9000] = game
        fetcher.infos[9100] = nil
        do { _ = try await fetcher.fetchInstallInfo(appID: 9000); fatalError("missing required owner must fail") } catch {}
        dependency.installDir = ""
        fetcher.infos[9100] = dependency
        do { _ = try await fetcher.fetchInstallInfo(appID: 9000); fatalError("missing required folder must fail") } catch {}
        print("PASS: production shared metadata resolution, published/inherited manifest, missing owner/folder refusal")

        let apps = URL(fileURLWithPath: CommandLine.arguments[1])
        let consumer = apps.appendingPathComponent("common/Consumer")
        let owner = apps.appendingPathComponent("common/Dependency")
        let fm = FileManager.default
        try fm.createDirectory(at: consumer.appendingPathComponent("Installers"), withIntermediateDirectories: true)
        let input = consumer.appendingPathComponent("Installers/setup.bin")
        let output = owner.appendingPathComponent("Installers/setup.bin")
        let original = Data("verified depot bytes".utf8)
        try original.write(to: input)
        let depot = AppManifestWriter.InstalledDepot(depotID: 9003, manifestGID: 300, size: Int64(original.count))
        try SteamInstallFiles.stageSharedContent(paths: [input.path, "", input.path], from: consumer, to: owner)
        assert(try Data(contentsOf: input) == original)
        assert(try Data(contentsOf: output) == original)
        try AppManifestWriter.mergeOwnerManifest(ownerAppID: 9100, ownerName: "Dependency", ownerBuildID: 7,
            installDir: "Dependency", steamID: 0, steamAppsPath: apps.path, depots: [depot],
            customExecutables: ["Installers\\setup.bin"])
        try AppManifestWriter.writeManifest(appID: 9000, name: "Consumer", installDir: "Consumer", buildID: 10,
            steamID: 0, steamAppsPath: apps.path, installedDepots: [], sharedDepots: [(9003, 9100)])
        let state = try read(9100, at: apps)
        assert(state["installdir"]?.string == "Dependency")
        assert(state["InstalledDepots"]?["9003"]?["manifest"]?.string == "300")
        assert(state["CheckGuid"]?["0"]?.string == "Installers\\setup.bin")
        assert(try read(9000, at: apps)["SharedDepots"]?["9003"]?.string == "9100")

        // Repair replaces stale bytes in the owner without losing the consumer.
        try Data("stale".utf8).write(to: output)
        try SteamInstallFiles.stageSharedContent(paths: [input.path], from: consumer, to: owner)
        assert(try Data(contentsOf: output) == original)
        try SteamInstallFiles.stageSharedContent(paths: [input.path], from: consumer, to: consumer)
        assert(try Data(contentsOf: input) == original)

        // Missing source and escaping symlinks fail without damaging earlier files.
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [consumer.appendingPathComponent("missing").path], from: consumer, to: owner) }
        assert(try Data(contentsOf: output) == original)
        let outside = apps.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: owner.appendingPathComponent("Escape"), withDestinationURL: outside)
        try fm.createDirectory(at: consumer.appendingPathComponent("Escape"), withIntermediateDirectories: true)
        let escaping = consumer.appendingPathComponent("Escape/secret.bin")
        try original.write(to: escaping)
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [escaping.path], from: consumer, to: owner) }
        assert(!fm.fileExists(atPath: outside.appendingPathComponent("secret.bin").path))
        let outsideFile = outside.appendingPathComponent("private.bin")
        try original.write(to: outsideFile)
        let link = consumer.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [link.path], from: consumer, to: owner) }
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [input.path], from: consumer, to: owner.appendingPathComponent("Escape")) }
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [output.path], from: consumer, to: owner) }
        let blocked = consumer.appendingPathComponent("Installers/blocked.bin")
        try original.write(to: blocked)
        try fm.createDirectory(at: owner.appendingPathComponent("Installers/blocked.bin"), withIntermediateDirectories: true)
        expectFailure { try SteamInstallFiles.stageSharedContent(paths: [blocked.path], from: consumer, to: owner) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try SteamInstallFiles.stageSharedContent(paths: [input.path], from: consumer, to: owner)
        }
        do { try await cancelled.value; fatalError("cancelled staging must fail") } catch is CancellationError {}
        assert(try Data(contentsOf: output) == original)
        assert(try fm.contentsOfDirectory(atPath: output.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".shared-") })

        // Updating a shared owner preserves its other depots and launch metadata.
        try AppManifestWriter.writeManifest(appID: 9100, name: "Dependency", installDir: "Dependency", buildID: 7,
            steamID: 0, steamAppsPath: apps.path,
            installedDepots: [.init(depotID: 9005, manifestGID: 500, size: 12)],
            sharedDepots: [(9006, 9200), (9003, 9300)], customExecutables: ["old.bin"])
        try AppManifestWriter.mergeOwnerManifest(ownerAppID: 9100, ownerName: "Dependency", ownerBuildID: 8,
            installDir: "Dependency", steamID: 0, steamAppsPath: apps.path, depots: [depot], customExecutables: ["new.bin"])
        let merged = try read(9100, at: apps)
        assert(merged["InstalledDepots"]?.fields.count == 2)
        assert(merged["SharedDepots"]?["9006"]?.string == "9200")
        assert(merged["SharedDepots"]?["9003"] == nil)
        assert(Set(merged["CheckGuid"]!.fields.values.compactMap(\.string)) == ["old.bin", "new.bin"])

        // Never claim that old depots in another folder were installed here.
        try AppManifestWriter.mergeOwnerManifest(ownerAppID: 9100, ownerName: "Dependency", ownerBuildID: 8,
            installDir: "NewDependency", steamID: 0, steamAppsPath: apps.path, depots: [depot])
        assert(try read(9100, at: apps)["InstalledDepots"]?.fields.count == 1)
        SteamInstallFiles.delete(appID: 9000, folderName: "Consumer", steamApps: apps)
        assert(!fm.fileExists(atPath: consumer.path))
        assert(fm.fileExists(atPath: output.path))
        assert(fm.fileExists(atPath: apps.appendingPathComponent("appmanifest_9100.acf").path))
        print("PASS: shared dependency staging, repair, same-folder reuse, failure safety, manifest merge and uninstall")
    }
}
'''
# Throwing expressions must be evaluated outside Swift's nonthrowing assert autoclosure.
checks = checks.replace('assert(try ', 'try check(')
checks = checks.replace('func expectFailure', 'func check(_ value: Bool) throws { assert(value) }\nfunc expectFailure')
fetcher = (app / 'SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
metadata = '''import Foundation
enum SteamLog { static func event(_ message: String) {} }
final class FixtureFetcher {
    var infos: [UInt32: SteamAppInfo] = [:]
    var requests: [UInt32] = []
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? {
        requests.append(appID)
        return infos[appID]
    }
'''
# Only network fetching is scripted; dependency resolution and metadata parsing are production code.
metadata += fetcher[fetcher.index('    func fetchInstallInfo('):fetcher.index('    // MARK: - License List')]
metadata += '\n}\n' + fetcher[fetcher.index('enum VDFParser {'):]
with tempfile.TemporaryDirectory(prefix='madeira-shared-content-') as directory:
    work = Path(directory)
    source = work / 'checks.swift'
    source.write_text(checks)
    resolution = work / 'resolution.swift'
    resolution.write_text(metadata)
    binary = work / 'check'
    compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
    subprocess.run([compiler, '-parse-as-library', '-sanitize=address', str(source),
                    str(resolution), str(app / 'SwiftSteam/Library/SteamAppInfo.swift'),
                    str(app / 'SteamInstall.swift'), str(app / 'SteamKeyValues.swift'),
                    str(app / 'SwiftSteam/Install/AppManifestWriter.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(work / 'steamapps')], check=True,
                   env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# These checks bind the isolated filesystem tests to the production download path.
downloader = (app / 'SwiftSteam/Content/DepotDownloader.swift').read_text()
assert downloader.index('stageSharedContent(') < downloader.index('try AppManifestWriter.mergeOwnerManifest(') < downloader.index('try AppManifestWriter.writeManifest(')
assert 'installDir: ownerFolder' in downloader and 'paths: paths, from: installURL, to: ownerURL' in downloader
assert 'owners-skipped=' not in downloader
assert 'depot.fromApp == nil, let owned = await ownedDepots()' in downloader
print('PASS: owners are materialized and recorded before game completion; missing metadata/required licenses fail closed')
