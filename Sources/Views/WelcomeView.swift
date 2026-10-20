import SwiftUI

/// Отдельное окно приветствия (без sidebar и тулбара), пока вход не выполнен.
struct WelcomeWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WelcomeView()
            .frame(width: 460, height: 520)
            .alert("NaviDrive", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

/// Первый запуск / нет входа: иконка, название, что делает приложение, и одна крупная кнопка входа.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(verbatim: "NaviDrive").font(.largeTitle.weight(.semibold))
                Text("Download and upload Google Drive files reliably — even very large ones, with resume after interruptions.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            if let notice = model.welcomeNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isSigningIn {
                waiting
            } else {
                Button { model.signIn() } label: {
                    Label(model.signInError == nil ? "Sign In with Google" : "Try Again", systemImage: "person.crop.circle")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            Text("Google will show an “unverified app” warning — click Advanced → Go to NaviDrive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.signInError {
                VStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460)
                    if !model.hasBundledCredentials || model.useCustomCredentials {
                        Button("Open Account Settings") { model.openSettings(.account) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in in your browser…")
            }
            HStack(spacing: 12) {
                Button("Cancel") { model.cancelSignIn() }
                Button("Open Sign-In Page Again") { model.reopenSignInPage() }
                    .disabled(model.signInURL == nil)
            }
        }
    }
}
