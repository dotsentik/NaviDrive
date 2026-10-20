import SwiftUI

/// Отдельное окно приветствия (без sidebar и тулбара), пока вход не выполнен.
/// Высота — по содержимому: окно (windowResizability .contentSize) подстраивается под кнопки.
struct WelcomeWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WelcomeView()
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(verbatim: "NaviDrive").font(.largeTitle.weight(.semibold))
                Text("Reliable downloads and uploads for Google Drive and Dropbox — even very large files, with resume after interruptions")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = model.welcomeNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Text("Choose a cloud to connect")
                    .font(.headline)
                CloudConnectRow(cloud: .googleDrive)
                CloudConnectRow(cloud: .dropbox)
                Text("You can connect the other cloud later from the sidebar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }
}

/// Кнопка «Continue with …», ожидание входа в браузере и ошибка входа.
private struct CloudConnectRow: View {
    @Environment(AppModel.self) private var model
    let cloud: CloudProviderKind

    private var state: CloudAccountState { model.account(cloud) }

    var body: some View {
        VStack(spacing: 8) {
            if state.isSigningIn {
                // Та же высота, что у кнопки: окно не прыгает при начале входа.
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in in the browser…")
                    }
                    HStack(spacing: 12) {
                        Button("Cancel") { model.cancelSignIn(cloud) }
                        Button("Open Sign-In Page Again") { model.reopenSignInPage(cloud) }
                            .disabled(state.signInURL == nil)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if cloud == .googleDrive {
                    Text("Google will show an “unverified app” warning — click Advanced → Go to NaviDrive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button { model.signIn(cloud) } label: {
                    HStack(spacing: 10) {
                        CloudLetterIcon(cloud: cloud)
                        Text(cloud == .dropbox ? String(localized: "Continue with Dropbox")
                                               : String(localized: "Continue with Google Drive"))
                            .font(.title3.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
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
