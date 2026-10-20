import SwiftUI

/// Отдельное окно приветствия (без sidebar и тулбара), пока вход не выполнен.
struct WelcomeWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WelcomeView()
            .frame(width: 480, height: 600)
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

/// Первый запуск / нет входа: иконка, название, что делает приложение и выбор облака для подключения.
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
                Text("Download and upload Google Drive and Dropbox files reliably — even very large ones, with resume after interruptions.")
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

            Text("Choose what to connect. You can add the other one later.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                CloudConnectRow(cloud: .googleDrive)
                CloudConnectRow(cloud: .dropbox)
            }
            .frame(maxWidth: 400)

            Text("Google will show an “unverified app” warning — click Advanced → Go to NaviDrive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Кнопка подключения облака, ожидание входа в браузере и ошибка входа.
private struct CloudConnectRow: View {
    @Environment(AppModel.self) private var model
    let cloud: CloudProviderKind

    private var state: CloudAccountState { model.account(cloud) }

    var body: some View {
        VStack(spacing: 8) {
            if state.isSigningIn {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in in your browser…")
                    }
                    HStack(spacing: 12) {
                        Button("Cancel") { model.cancelSignIn(cloud) }
                        Button("Open Sign-In Page Again") { model.reopenSignInPage(cloud) }
                            .disabled(state.signInURL == nil)
                    }
                }
            } else {
                Button { model.signIn(cloud) } label: {
                    Label(String(localized: "Connect \(cloud.displayName)"), systemImage: cloud.systemImage)
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(model.providers[cloud]?.canSignIn ?? false))
            }
            if let error = state.signInError {
                VStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if cloud == .googleDrive, !model.hasBundledCredentials || model.useCustomCredentials {
                        Button("Open Account Settings") { model.openSettings(.account) }
                            .buttonStyle(.link)
                    }
                }
            } else if !(model.providers[cloud]?.canSignIn ?? false) {
                Text("This copy of NaviDrive was built without a Dropbox app key (DROPBOX_APP_KEY in Config/Secrets.xcconfig).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
