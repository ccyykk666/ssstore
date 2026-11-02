//
//  ProductView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import Kingfisher
import SwiftUI

struct ProductView: View {
    @State private var archive: AppPackageArchive
    @Binding var navigationPath: NavigationPath
    private let openDownload: ((PackageManifest) -> Void)?

    var region: String {
        archive.region
    }

    init(archive: AppStore.AppPackage, region: String, navigationPath: Binding<NavigationPath>, openDownload: ((PackageManifest) -> Void)? = nil) {
        _archive = State(initialValue: AppPackageArchive(accountID: nil, region: region, package: archive))
        _navigationPath = navigationPath
        self.openDownload = openDownload
    }

    @State private var vm = AppStore.this
    @State private var dvm = Downloads.this

    var eligibleAccounts: [AppStore.UserAccount] {
        vm.eligibleAccounts(for: region)
    }

    var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == selection }
    }

    @State private var selection: AppStore.UserAccount.ID = .init()
    @State private var licenseHint: Hint?
    @State private var showLicenseAlert = false
    @State private var hint: Hint?

    let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    var formattedSize: String? {
        guard let sizeBytes = archive.package.software.fileSizeBytes.flatMap(Int64.init(_:)) else {
            return nil
        }
        return sizeFormatter.string(fromByteCount: sizeBytes)
    }

    var body: some View {
        Form {
            packageHeader
            packageDetails
            packageDescription
            if account == nil {
                Section {
                    Text("No account available for this region.")
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                } footer: {
                    Text("Please add an account in the Accounts page.")
                }
            }
            pricing
        }
        .formStyle(.grouped)
        .onAppear {
            if !eligibleAccounts.contains(where: { $0.id == selection }) {
                selection = eligibleAccounts.first?.id ?? .init()
            }
        }
        .navigationDestination(for: PackageManifest.self) { manifest in
            PackageView(pkg: manifest)
        }
        .navigationTitle(archive.package.software.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { accountSelector }
        }
        .alert("License Required", isPresented: $showLicenseAlert) {
            var confirmRole: ButtonRole?
            #if compiler(>=6.2)
                if #available(iOS 26.0, macOS 26.0, *) {
                    confirmRole = .confirm
                }
            #endif

            return Group {
                Button("Acquire License", role: confirmRole) {
                    Task {
                        do {
                            try await acquireLicense()
                        } catch {
                            licenseHint = Hint(message: error.localizedDescription, color: .red)
                        }
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
        } message: {}
    }

    /// Rotates the password token and requests a license for the current
    /// account. Sets `licenseHint` to a success message; callers handle errors.
    private func acquireLicense() async throws {
        guard let account else { return }
        try await vm.withAccount(id: account.id) { userAccount in
            try await ApplePackage.Authenticator.rotatePasswordToken(for: &userAccount.account)
            try await ApplePackage.Purchase.purchase(
                account: &userAccount.account,
                app: archive.package.software,
            )
        }
        licenseHint = Hint(message: String(localized: "Request Succeeded"), color: .green)
    }

    var packageHeader: some View {
        Section {
            PackageDisplayView(archive: archive.package, trailingText: archive.formattedPrice ?? "—")
            NavigationLink {
                // Build the archive lazily: constructing it eagerly here runs
                // two synchronous file reads + a JSON decode on every body
                // evaluation, even before the user navigates.
                LazyView(ProductHistoryView(vm: AppPackageArchive(accountID: selection, region: region, package: archive.package)))
            } label: {
                let badgeText = archive.releaseDate.flatMap { date in
                    Text(date.formatted(.relative(presentation: .numeric)))
                }

                Text("Version \(archive.package.software.version)")
                    .badge(badgeText)
            }
            buttons
        } footer: {
            if let hint { Text(hint.message).foregroundStyle(hint.color ?? .primary) }
        }
    }

    var packageDetails: some View {
        Section {
            CopyableRow(label: "Bundle ID", value: archive.package.software.bundleID, monospaced: true)
            CopyableRow(label: "Developer", value: archive.package.software.sellerName)
            if !archive.package.software.primaryGenreName.isEmpty {
                CopyableRow(label: "Category", value: archive.package.software.primaryGenreName)
            }
            if let formattedSize {
                CopyableRow(label: "Size", value: formattedSize)
            }
            CopyableRow(label: "Compatibility", value: "\(archive.package.software.minimumOsVersion)+")
            if archive.package.software.userRatingCount > 0 {
                CopyableRow(label: "Rating", value: "\(String(format: "%.1f", archive.package.software.averageUserRating)) (\(archive.package.software.userRatingCount))")
            }
        } header: {
            Text("Details")
        }
    }

    var packageDescription: some View {
        Section {
            Text(archive.package.software.releaseNotes ?? "")
        } header: {
            Text("What's New")
        }
    }

    var pricing: some View {
        if archive.price == 0 {
            Section {
                AsyncButton {
                    try await acquireLicense()
                } label: {
                    Text("Acquire License")
                }
                .disabledWhenLoading()
                .disabled(account == nil)
            } footer: {
                if let licenseHint {
                    Text(licenseHint.message)
                        .foregroundStyle(licenseHint.color ?? .primary)
                }
            }
        }
    }

    var accountSelector: some View {
        Menu {
            Picker("Account", selection: $selection) {
                ForEach(eligibleAccounts) { account in
                    Text(account.account.email).tag(account.id)
                }
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .disabled(eligibleAccounts.isEmpty)
    }

    var buttons: some View {
        Group {
            if let req = dvm.downloadRequest(forArchive: archive.package) {
                NavigationLink(value: req) {
                    Text("Show Download")
                }
            } else {
                AsyncButton {
                    guard let account else { return }
                    do {
                        try await dvm.startDownload(for: archive.package, accountID: account.id)
                        hint = Hint(message: String(localized: "Download Requested"), color: nil)
                        if let req = dvm.downloadRequest(forArchive: archive.package) {
                            if let openDownload { openDownload(req) }
                            else { navigationPath.append(req) }
                        }
                    } catch {
                        if case ApplePackageError.licenseRequired = error, archive.package.software.price == 0 {
                            showLicenseAlert = true
                        } else {
                            hint = Hint(message: String(localized: "Unable to retrieve download URL. Please try again later.") + "\n" + error.localizedDescription, color: .red)
                        }
                        throw error
                    }
                } label: {
                    Text("下载")
                }
                .disabledWhenLoading()
                .disabled(account == nil)
            }
        }
    }
}

extension AppStore.AppPackage {
    var displaySupportedDevicesIcon: String {
        // TODO: assuming iPhone for now
        "iphone"
    }
}

/// Defers building its content until the view is actually rendered, so an
/// expensive destination is not constructed eagerly inside a NavigationLink.
struct LazyView<Content: View>: View {
    private let build: () -> Content

    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }

    var body: Content {
        build()
    }
}


