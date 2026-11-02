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

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordHidden = true
    @State private var codeRequired = false
    @State private var code = ""
    @State private var authenticator: ApplePackage.Authenticator?
    @State private var isAuthenticating = false
    @State private var error: Error?
    @State private var contentHeight: CGFloat = 220

    private var canConfirm: Bool {
        !isAuthenticating && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty && (!codeRequired || !code.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Apple ID").foregroundStyle(.secondary)
                            Spacer()
                            Button(isPasswordHidden ? "Show Password" : "Hide Password") {
                                isPasswordHidden.toggle()
                            }
                            .disabled(password.isEmpty)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            TextField("Email (Apple ID)", text: $email)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                            #endif
                                .padding(16)
                            Divider().padding(.leading, 16)
                            passwordField.padding(16)
                        }
                        .textFieldStyle(.plain)
                        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 20))
                    }

                    if codeRequired {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("2FA Code").font(.footnote).foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                            TextField("验证码", text: $code)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            #endif
                                .textFieldStyle(.plain)
                                .padding(16)
                                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 20))
                        }
                    }

                    if let error {
                        Text(error.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                    }
                }
                .disabled(isAuthenticating)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AccountContentHeight.self, value: geometry.size.height)
                    }
                }
            }
            .onPreferenceChange(AccountContentHeight.self) { height in
                if height > 0 && abs(contentHeight - height) > 1 { contentHeight = height }
            }
            .background(sheetBackground)
            .navigationTitle("Add Account")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isAuthenticating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton { try await authenticate() } label: { Text("确认") }
                        .disabledWhenLoading()
                        .disabled(!canConfirm)
                }
            }
        }
        .interactiveDismissDisabled(isAuthenticating)
        .onChange(of: email) { resetAuthentication() }
        .onChange(of: password) { resetAuthentication() }
        .onChange(of: code) { error = nil }
        #if os(iOS)
            .modifier(AccountSheetSizing(contentHeight: contentHeight))
        #endif
    }

    @ViewBuilder private var passwordField: some View {
        if isPasswordHidden {
            SecureField("Password", text: $password)
            #if os(iOS)
                .textContentType(.password)
            #endif
        } else {
            TextField("Password", text: $password)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            #endif
        }
    }

    private var fieldBackground: Color {
        #if os(iOS)
            Color(uiColor: .secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private var sheetBackground: Color {
        #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
        #else
            Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private func authenticate() async throws {
        guard canConfirm else { return }
        isAuthenticating = true
        error = nil
        defer { isAuthenticating = false }
        logger.info("starting authentication for user")
        do {
            let session: ApplePackage.Authenticator
            if let authenticator { session = authenticator }
            else {
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
    }

    private func resetAuthentication() {
        authenticator = nil
        codeRequired = false
        code = ""
        error = nil
    }
}

private struct AccountContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#if os(iOS)
private struct AccountSheetSizing: ViewModifier {
    let contentHeight: CGFloat
    private var height: CGFloat { max(240, contentHeight + 56) }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18.0, *) {
                content.frame(idealHeight: height)
                    .presentationSizing(.fitted)
            } else {
                content
            }
        }
        // Measure the fields rather than the NavigationStack, which expands to
        // its proposal. The scroll view still handles the keyboard, long errors,
        // large text, and landscape when the system caps the sheet height.
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
    }
}
#endif
