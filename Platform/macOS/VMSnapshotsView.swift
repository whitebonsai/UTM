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
import SwiftUI

struct VMSnapshotsView: View {
    @ObservedObject var vm: VMData
    @EnvironmentObject private var data: UTMData

    @State private var snapshots: [SnapshotEntry] = []
    @State private var isLoading: Bool = false
    @State private var newSnapshotName: String = ""
    @State private var errorMessage: String?
    @State private var snapshotToDelete: SnapshotEntry?
    @State private var snapshotToRestore: SnapshotEntry?
    @State private var showCreateField: Bool = false

    private let manager = VMSnapshotManager.shared

    private var canManage: Bool {
        vm.isStopped && vm.isLoaded
    }

    var body: some View {
        Group {
            if !snapshots.isEmpty || showCreateField {
                snapshotList
            }
            createBar
        }
        .alert(item: $errorMessage) { msg in
            Alert(title: Text("Error"), message: Text(msg), dismissButton: .default(Text("OK")))
        }
        .alert(item: $snapshotToDelete) { snap in
            Alert(
                title: Text("Delete snapshot '\(snap.name)'?"),
                message: Text("This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    perform { try await manager.deleteSnapshot(for: vm, name: snap.name) }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $snapshotToRestore) { snap in
            Alert(
                title: Text("Restore snapshot '\(snap.name)'?"),
                message: Text("All current disk state will be replaced. Make sure the VM is stopped."),
                primaryButton: .default(Text("Restore")) {
                    perform { try await manager.restoreSnapshot(for: vm, name: snap.name) }
                },
                secondaryButton: .cancel()
            )
        }
        .task(id: vm.id) {
            await reload()
        }
        .onChange(of: vm.state) { _ in
            Task { await reload() }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var snapshotList: some View {
        ForEach(snapshots) { snap in
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.name)
                            .fontWeight(snap.isSuspend ? .semibold : .regular)
                        HStack(spacing: 8) {
                            if let date = snap.date {
                                Text(date).foregroundColor(.secondary).font(.caption)
                            }
                            if let size = snap.size {
                                Text(size).foregroundColor(.secondary).font(.caption)
                            }
                            if snap.isSuspend {
                                Text("suspend").foregroundColor(.orange).font(.caption)
                            }
                        }
                    }
                } icon: {
                    Image(systemName: snap.isSuspend ? "camera.badge.clock" : "camera")
                        .foregroundColor(snap.isSuspend ? .orange : .accentColor)
                }
                Spacer()
                if canManage {
                    Button {
                        snapshotToRestore = snap
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore this snapshot")

                    Button {
                        snapshotToDelete = snap
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .help("Delete this snapshot")
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var createBar: some View {
        if isLoading {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading snapshots…").foregroundColor(.secondary).font(.caption)
            }
        } else if showCreateField {
            HStack {
                Image(systemName: "camera.badge.plus")
                    .foregroundColor(.accentColor)
                TextField("Snapshot name", text: $newSnapshotName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { createSnapshot() }
                Button("Save") { createSnapshot() }
                    .disabled(newSnapshotName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    showCreateField = false
                    newSnapshotName = ""
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button {
                showCreateField = true
            } label: {
                Label("New Snapshot…", systemImage: "camera.badge.plus")
            }
            .disabled(!canManage)
            .help(canManage ? "Create a new snapshot of this VM (VM must be stopped)" : "Stop the VM before managing snapshots")
        }
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots = try await manager.listSnapshots(for: vm)
        } catch {
            // Silently ignore listing errors (no drives = no snapshots)
            snapshots = []
        }
    }

    private func createSnapshot() {
        let name = newSnapshotName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showCreateField = false
        newSnapshotName = ""
        perform {
            try await manager.createSnapshot(for: vm, name: name)
        }
    }

    private func perform(_ action: @escaping @Sendable () async throws -> Void) {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await action()
                snapshots = (try? await manager.listSnapshots(for: vm)) ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Section wrapper for VMDetailsView

struct VMSnapshotsSectionView: View {
    @ObservedObject var vm: VMData

    var body: some View {
        GroupBox {
            VMSnapshotsView(vm: vm)
                .padding(.top, 4)
        } label: {
            Label("Snapshots", systemImage: "camera.on.rectangle")
                .font(.headline)
        }
    }
}

// MARK: - Preview

struct VMSnapshotsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section("Snapshots") {
                VMSnapshotsView(vm: VMData(from: .empty))
            }
        }
        .frame(width: 400)
    }
}
#endif
