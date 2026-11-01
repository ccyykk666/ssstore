//
//  AccountDetailView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import SwiftUI

struct AccountDetailView: View {
    let accountId: AppStore.UserAccount.ID

    @State private var vm = AppStore.this
    @Environment(\.dismiss) var dismiss

    private var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == accountId }
    }

    @State private var rotatingHint: Hint?

    var body: some View {
        Form {
            Section {
                Button { copyToClipboard(account?.account.email) } label: {
                    Text(account?.account.email ?? "")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Apple ID")
            }
            Section {
                Button { copyToClipboard(account?.account.store) } label: {
                    Text("\(account?.account.store ?? "") - \(ApplePackage.Configuration.countryCode(for: account?.account.store ?? "") ?? "Unknown")")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Country Code")
            }
            Section {
                Button { copyToClipboard(account?.account.directoryServicesIdentifier) } label: {
                    Text(account?.account.directoryServicesIdentifier ?? "")
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Directory Services ID")
            }
            Section {
                SecureField(text: .constant(account?.account.passwordToken ?? "")) {
                    Text("Password Token")
                }
                AsyncButton {
                    rotatingHint = nil
                    do {
                        _ = try await vm.rotate(id: accountId)
                        rotatingHint = Hint(message: "已更新", color: .green)
                    } catch {
                        rotatingHint = Hint(message: error.localizedDescription, color: .red)
                        throw error
                    }
                } label: {
                    Text("Rotate Token")
                }
                .disabledWhenLoading()
            } header: {
                Text("Password Token")
            } footer: {
                if let rotatingHint {
                    Text(rotatingHint.message).foregroundStyle(rotatingHint.color ?? .secondary)
                }
            }
            Section {
                Button("Delete") {
                    vm.delete(id: account?.id ?? "")
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account Details")
    }
}


