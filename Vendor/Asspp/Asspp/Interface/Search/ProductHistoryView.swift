//
//  ProductHistoryView.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import SwiftUI

struct ProductHistoryView: View {
    @State var vm: AppPackageArchive
    @State private var showErrorAlert = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
            if vm.isLoadingIndex {
                HStack { ProgressView(); Text(vm.isLoadingEarlierVersions ? "正在加载更早版本…" : "正在加载版本…").foregroundStyle(.secondary) }
            }
            ForEach(vm.versionIdentifiers, id: \.self) { key in
                historyRow(key)
            }
            if vm.canLoadEarlierVersions && !vm.isLoadingIndex {
                Button("加载更早版本") { vm.loadEarlierVersions() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Version History")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                Menu {
                    Button { vm.populateNextVersionItems() } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled((vm.isVersionItemsFullyLoaded && !vm.canLoadEarlierVersions) || vm.isLoadingIndex)
                    Button { vm.loadHistory(force: true) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(vm.isLoadingIndex)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Oops", isPresented: $showErrorAlert) {
            Button("OK") {
                vm.error = nil
                if vm.shouldDismiss { dismiss() }
            }
        } message: { Text(vm.error ?? String(localized: "Unknown Error")) }
        .onChange(of: vm.error) { _, value in showErrorAlert = value != nil }
        .onAppear { vm.loadHistory() }
        .onDisappear { vm.cancelHistoryLoading() }
    }

    @ViewBuilder private func historyRow(_ key: String) -> some View {
        if let accountID = vm.accountIdentifier, let package = vm.package(for: key),
           let details = vm.versionItems[key] {
            Menu {
                Button("Download \(package.software.version)") {
                    Task {
                        do { try await Downloads.this.startDownload(for: package, accountID: accountID) }
                        catch { vm.error = error.localizedDescription }
                    }
                }
            } label: {
                HStack {
                    Text(package.software.version).foregroundStyle(Color.accentColor)
                    Spacer()
                    if let date = details.releaseDate {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
        } else {
            Button { vm.populateVersionItem(for: key, retry: true) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).foregroundStyle(.secondary)
                        if let error = vm.metadataErrors[key] {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    Spacer()
                    if vm.loadingIDs.contains(key) { ProgressView() }
                    else if vm.metadataErrors[key] != nil {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onAppear { vm.populateVersionItem(for: key) }
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .automatic
        #endif
    }
}
