// Copyright © 2024 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if os(macOS)
import Foundation

// MARK: - Model

struct SnapshotEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let date: String?
    let size: String?
    let isSuspend: Bool
}

// MARK: - Errors

enum VMSnapshotError: LocalizedError {
    case vmMustBeStopped
    case noQCOW2Drives
    case noVmstate(String)
    case snapshotExists(String)
    case snapshotNotFound(String)
    case qemuImgNotFound
    case qemuImgFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .vmMustBeStopped:
            return NSLocalizedString("The VM must be stopped before managing snapshots.", comment: "VMSnapshotManager")
        case .noQCOW2Drives:
            return NSLocalizedString("No QCOW2 disk images found in this VM.", comment: "VMSnapshotManager")
        case .noVmstate(let name):
            return String(format: NSLocalizedString("No saved VM state for %@. Pause the VM in UTM first.", comment: "VMSnapshotManager"), name)
        case .snapshotExists(let name):
            return String(format: NSLocalizedString("Snapshot '%@' already exists.", comment: "VMSnapshotManager"), name)
        case .snapshotNotFound(let name):
            return String(format: NSLocalizedString("Snapshot '%@' not found.", comment: "VMSnapshotManager"), name)
        case .qemuImgNotFound:
            return NSLocalizedString("qemu-img not found. Install via: brew install qemu", comment: "VMSnapshotManager")
        case .qemuImgFailed(let msg):
            return String(format: NSLocalizedString("qemu-img failed: %@", comment: "VMSnapshotManager"), msg)
        case .ioError(let msg):
            return msg
        }
    }
}

// MARK: - Manager

@MainActor
class VMSnapshotManager {
    static let shared = VMSnapshotManager()

    private let qemuImgPath: String? = {
        let candidates = [
            "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/qemu-img",
            "/opt/homebrew/bin/qemu-img",
            "/usr/local/bin/qemu-img",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    // MARK: Public API

    func listSnapshots(for vm: VMData) async throws -> [SnapshotEntry] {
        if let qemuConfig = vm.config as? UTMQemuConfiguration {
            return try await listQEMUSnapshots(config: qemuConfig, bundleURL: vm.pathUrl)
        } else if vm.config is UTMAppleConfiguration {
            return try listAppleSnapshots(bundleURL: vm.pathUrl)
        }
        return []
    }

    func createSnapshot(for vm: VMData, name: String) async throws {
        if let qemuConfig = vm.config as? UTMQemuConfiguration {
            try await createQEMUSnapshot(config: qemuConfig, bundleURL: vm.pathUrl, name: name)
        } else if vm.config is UTMAppleConfiguration {
            try createAppleSnapshot(bundleURL: vm.pathUrl, vmName: vm.detailsTitleLabel, name: name)
        }
    }

    func restoreSnapshot(for vm: VMData, name: String) async throws {
        if let qemuConfig = vm.config as? UTMQemuConfiguration {
            try await restoreQEMUSnapshot(config: qemuConfig, bundleURL: vm.pathUrl, name: name)
        } else if vm.config is UTMAppleConfiguration {
            try restoreAppleSnapshot(bundleURL: vm.pathUrl, name: name)
        }
    }

    func deleteSnapshot(for vm: VMData, name: String) async throws {
        if let qemuConfig = vm.config as? UTMQemuConfiguration {
            try await deleteQEMUSnapshot(config: qemuConfig, bundleURL: vm.pathUrl, name: name)
        } else if vm.config is UTMAppleConfiguration {
            try deleteAppleSnapshot(bundleURL: vm.pathUrl, name: name)
        }
    }

    // MARK: - QEMU helpers

    private func qcow2Drives(config: UTMQemuConfiguration, bundleURL: URL) -> [URL] {
        let dataDir = bundleURL.appendingPathComponent("Data")
        return config.drives.compactMap { drive -> URL? in
            guard !drive.isExternal, let url = drive.imageURL else { return nil }
            // Resolve relative paths via the Data directory
            let resolved = url.path.hasPrefix("/") ? url : dataDir.appendingPathComponent(url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
            // Check QCOW2 magic bytes: QFI\xfb
            guard let fh = FileHandle(forReadingAtPath: resolved.path) else { return nil }
            let magic = fh.readData(ofLength: 4)
            fh.closeFile()
            guard magic == Data([0x51, 0x46, 0x49, 0xfb]) else { return nil }
            return resolved
        }
    }

    private func requireQemuImg() throws -> String {
        guard let path = qemuImgPath else { throw VMSnapshotError.qemuImgNotFound }
        return path
    }

    private func runQemuImg(_ args: [String]) async throws -> String {
        let qimg = try requireQemuImg()
        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: qimg)
            proc.arguments = args
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if proc.terminationStatus != 0 {
                let msg = errOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : errOut
                throw VMSnapshotError.qemuImgFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return out
        }.value
    }

    private func listQEMUSnapshots(config: UTMQemuConfiguration, bundleURL: URL) async throws -> [SnapshotEntry] {
        let drives = qcow2Drives(config: config, bundleURL: bundleURL)
        guard !drives.isEmpty else { return [] }
        // Use first drive as source of truth
        let out = try await runQemuImg(["snapshot", "-l", drives[0].path])
        return parseQemuImgSnapshotList(out)
    }

    private func parseQemuImgSnapshotList(_ output: String) -> [SnapshotEntry] {
        var entries: [SnapshotEntry] = []
        // Format: ID   TAG   VM-SIZE   DATE   VM-CLOCK
        let pattern = #"^\s*\d+\s+(\S+)\s+([\d.]+ \w+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for line in output.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex?.firstMatch(in: line, range: range) {
                let tag  = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? ""
                let size = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                let date = Range(match.range(at: 3), in: line).map { String(line[$0]) }
                entries.append(SnapshotEntry(name: tag, date: date, size: size, isSuspend: tag == "suspend"))
            }
        }
        return entries
    }

    private func createQEMUSnapshot(config: UTMQemuConfiguration, bundleURL: URL, name: String) async throws {
        let drives = qcow2Drives(config: config, bundleURL: bundleURL)
        guard !drives.isEmpty else { throw VMSnapshotError.noQCOW2Drives }
        for drive in drives {
            try await runQemuImg(["snapshot", "-c", name, drive.path])
        }
    }

    private func restoreQEMUSnapshot(config: UTMQemuConfiguration, bundleURL: URL, name: String) async throws {
        let drives = qcow2Drives(config: config, bundleURL: bundleURL)
        guard !drives.isEmpty else { throw VMSnapshotError.noQCOW2Drives }
        for drive in drives {
            try await runQemuImg(["snapshot", "-a", name, drive.path])
        }
    }

    private func deleteQEMUSnapshot(config: UTMQemuConfiguration, bundleURL: URL, name: String) async throws {
        let drives = qcow2Drives(config: config, bundleURL: bundleURL)
        guard !drives.isEmpty else { throw VMSnapshotError.noQCOW2Drives }
        for drive in drives {
            try await runQemuImg(["snapshot", "-d", name, drive.path])
        }
        if name == "suspend" {
            let screenshot = bundleURL.appendingPathComponent("screenshot.png")
            try? FileManager.default.removeItem(at: screenshot)
        }
    }

    // MARK: - Apple VM helpers

    private func dataDir(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Data")
    }

    private func snapshotDir(bundleURL: URL) -> URL {
        dataDir(bundleURL: bundleURL).appendingPathComponent("snapshots")
    }

    private func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func listAppleSnapshots(bundleURL: URL) throws -> [SnapshotEntry] {
        let fm = FileManager.default
        var entries: [SnapshotEntry] = []

        // Suspend state
        let vmstate = dataDir(bundleURL: bundleURL).appendingPathComponent("vmstate")
        if fm.fileExists(atPath: vmstate.path),
           let attrs = try? fm.attributesOfItem(atPath: vmstate.path),
           let mtime = attrs[.modificationDate] as? Date,
           let size = attrs[.size] as? Int64 {
            let dateStr = DateFormatter.localizedString(from: mtime, dateStyle: .short, timeStyle: .short)
            entries.append(SnapshotEntry(name: "suspend", date: dateStr, size: humanSize(size), isSuspend: true))
        }

        // Named snapshots
        let snapDir = snapshotDir(bundleURL: bundleURL)
        if fm.fileExists(atPath: snapDir.path),
           let contents = try? fm.contentsOfDirectory(at: snapDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = attrs?[.modificationDate] as? Date
                let size = attrs?[.size] as? Int64
                let dateStr = mtime.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) }
                entries.append(SnapshotEntry(name: url.lastPathComponent, date: dateStr, size: size.map { humanSize($0) }, isSuspend: false))
            }
        }
        return entries
    }

    private func createAppleSnapshot(bundleURL: URL, vmName: String, name: String) throws {
        let fm = FileManager.default
        let vmstate = dataDir(bundleURL: bundleURL).appendingPathComponent("vmstate")
        guard fm.fileExists(atPath: vmstate.path) else {
            throw VMSnapshotError.noVmstate(vmName)
        }
        let snapDir = snapshotDir(bundleURL: bundleURL)
        try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let dest = snapDir.appendingPathComponent(name)
        guard !fm.fileExists(atPath: dest.path) else {
            throw VMSnapshotError.snapshotExists(name)
        }
        do {
            try fm.copyItem(at: vmstate, to: dest)
        } catch {
            throw VMSnapshotError.ioError(error.localizedDescription)
        }
    }

    private func restoreAppleSnapshot(bundleURL: URL, name: String) throws {
        let fm = FileManager.default
        if name == "suspend" { return } // vmstate is already there
        let src = snapshotDir(bundleURL: bundleURL).appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else {
            throw VMSnapshotError.snapshotNotFound(name)
        }
        let vmstate = dataDir(bundleURL: bundleURL).appendingPathComponent("vmstate")
        do {
            if fm.fileExists(atPath: vmstate.path) {
                try fm.removeItem(at: vmstate)
            }
            try fm.copyItem(at: src, to: vmstate)
        } catch {
            throw VMSnapshotError.ioError(error.localizedDescription)
        }
    }

    private func deleteAppleSnapshot(bundleURL: URL, name: String) throws {
        let fm = FileManager.default
        if name == "suspend" {
            let vmstate = dataDir(bundleURL: bundleURL).appendingPathComponent("vmstate")
            guard fm.fileExists(atPath: vmstate.path) else {
                throw VMSnapshotError.snapshotNotFound(name)
            }
            try? fm.removeItem(at: vmstate)
            try? fm.removeItem(at: bundleURL.appendingPathComponent("screenshot.png"))
            return
        }
        let target = snapshotDir(bundleURL: bundleURL).appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else {
            throw VMSnapshotError.snapshotNotFound(name)
        }
        do {
            try fm.removeItem(at: target)
        } catch {
            throw VMSnapshotError.ioError(error.localizedDescription)
        }
    }
}
#endif
