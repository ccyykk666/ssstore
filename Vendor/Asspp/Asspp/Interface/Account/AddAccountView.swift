//
//  AddAccountView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import SwiftUI

struct AddAccountView: View {
    @State private var vm = AppStore.this
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isPasswordHidden = true

    @State private var codeRequired: Bool = false
    @State private var code: String = ""

    @State private var authenticator: ApplePackage.Authenticator?
    @State private var isAuthenticating = false
    @State private var error: Error?

    var body: some View {
        Form {
            Section {
                TextField("Email (Apple ID)", text: $email)
                #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                #endif
                if isPasswordHidden {
                    SecureField("Password", text: $password)
                    #if os(iOS)
                        .textContentType(.password)
                    #endif
                } else {
                    TextField(text: $password) {
                        Text("Password")
                            .font(.body)
                    }
                    #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.password)
                    #endif
                    .font(.body.monospaced())
                }
            } header: {
                HStack {
                    Text("Apple ID")
                    Spacer()
                    Button(isPasswordHidden ? "Show Password" : "Hide Password") {
                        isPasswordHidden.toggle()
                    }
                    .disabled(password.isEmpty)
                }
            }
            if codeRequired {
                Section {
                    TextField("验证码", text: $code)
                    #if os(iOS)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.numberPad)
                    #endif
                } header: {
                    Text("2FA Code")
                } footer: {
                    Text("启用双重认证的账户需填写验证码。")
                }
                .transition(.opacity)
            }
            Section {
                AsyncButton {
                    isAuthenticating = true
                    defer { isAuthenticating = false }
                    logger.info("starting authentication for user")
                    do {
                        let session: ApplePackage.Authenticator
                        if let authenticator {
                            session = authenticator
                        } else {
                            session = try await ApplePackage.Authenticator()
                            authenticator = session
                        }
                        _ = try await vm.authenticate(email: email, password: password, code: code, using: session)
                        logger.info("authentication successful for user")
                        dismiss()
                    } catch {
                        logger.error("authentication failed: \(error.localizedDescription)")
                        self.error = error
                        if case ApplePackage.AuthenticationError.verificationCodeRequired = error {
                            codeRequired = true
                        }
                        throw error
                    }
                } label: {
                    Text("Authenticate")
                }
                .disabledWhenLoading()
                .disabled(email.isEmpty || password.isEmpty)
            } footer: {
                if let error {
                    Text(error.localizedDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
            }
        }
        .disabled(isAuthenticating)
        .formStyle(.grouped)
        .animation(.spring, value: codeRequired)
        .onChange(of: email) { resetAuthentication() }
        .onChange(of: password) { resetAuthentication() }
        #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .navigationTitle("Add Account")
    }

    private func resetAuthentication() {
        authenticator = nil
        codeRequired = false
        code = ""
        error = nil
    }
}


