import SwiftUI

struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AppleAccount
    var reason: String?
    let onSubmit: (AppleIDCredentials) -> Void

    @State private var email = AppleIDStore.email
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Toggle("Remember password", isOn: $remember)
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text(reason ?? String(localized: "iContain signs in to Apple directly, with anisette from the server chosen in Account. Your password is only kept, in this iPhone's Keychain, if you choose to remember it."))
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
                        let credentials = AppleIDCredentials(email: email.trimmingCharacters(in: .whitespaces), password: password)
                        account.use(credentials, remember: remember)
                        dismiss()
                        onSubmit(credentials)
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }
            }
            .slateScreen()
        }
    }
}

struct TwoFactorSheet: View {
    @EnvironmentObject private var account: AppleAccount
    let prompt: TwoFactorPrompt
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit())
                } header: {
                    Text("Verification Code")
                } footer: {
                    Text(prompt.sms
                         ? String(localized: "Enter the code Apple sent by text message.")
                         : String(localized: "Enter the code shown on your other Apple devices."))
                }
                if let error = prompt.lastError, !error.isEmpty {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
                Section("Didn't get a code?") {
                    Button("Send Again") { account.respond("resend") }
                    ForEach(prompt.numbers) { number in
                        Button("Text \(number.number)") { account.respond("sms:\(number.id)") }
                    }
                }
            }
            .navigationTitle("Two-Factor Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { account.respond("abort") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") { account.respond("code:\(code)") }
                        .disabled(code.count < 6)
                }
            }
            .interactiveDismissDisabled()
            .slateScreen()
        }
    }
}

struct RevokeSheet: View {
    @EnvironmentObject private var account: AppleAccount
    let prompt: RevokePrompt
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(prompt.certificates) { cert in
                        Button {
                            if chosen.contains(cert.serial) { chosen.remove(cert.serial) } else { chosen.insert(cert.serial) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cert.machine.isEmpty ? cert.name : cert.machine).foregroundStyle(.white)
                                    Text(cert.serial).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(cert.serial) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                } footer: {
                    Text("Your Apple ID has as many certificates as Apple allows. Revoking one stops apps signed with it from opening, including apps installed by the tool that made it, until they're signed again.")
                }
            }
            .navigationTitle("Revoke a Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { account.respond("[]") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Revoke", role: .destructive) {
                        let json = (try? JSONEncoder().encode(Array(chosen))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                        account.respond(json)
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .interactiveDismissDisabled()
            .slateScreen()
        }
    }
}
