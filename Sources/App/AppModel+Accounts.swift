import AppKit
import Foundation

/// Входы в облака. Google Drive и Dropbox независимы: можно подключить одно, другое или оба;
/// очереди задач каждого облака останавливаются и продолжаются вместе с его входом.
extension AppModel {
    func account(_ cloud: CloudProviderKind) -> CloudAccountState { accounts[cloud] ?? CloudAccountState() }

    /// Облака с действующим входом.
    var connectedClouds: [CloudProviderKind] { CloudProviderKind.allCases.filter { account($0).isSignedIn } }
    /// Подключено хотя бы одно облако: показывается главное окно.
    var isSignedIn: Bool { !connectedClouds.isEmpty }
    var isActiveCloudSignedIn: Bool { account(activeCloud).isSignedIn }

    // MARK: - Учётные данные Google

    /// Сохраняет Client ID / Client Secret. false — Связка ключей не приняла запись (сообщение уже показано).
    @discardableResult
    func saveCredentials() -> Bool {
        clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try keychain.setCustomCredentials(clientId: clientId, clientSecret: clientSecret)
            return true
        } catch {
            errorMessage = String(localized: "Couldn’t save the Client ID / Client Secret to the Keychain: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Вход и выход

    /// Вход в облако: loopback + PKCE, страница входа — в браузере по умолчанию.
    func signIn(_ cloud: CloudProviderKind) {
        guard !account(cloud).isSigningIn, let provider = providers[cloud] else { return }
        accounts[cloud, default: CloudAccountState()].signInError = nil
        // Свои учётные данные Google сохраняются в Keychain: без них токен нельзя обновить после перезапуска.
        if cloud == .googleDrive, useCustomCredentials { guard saveCredentials() else { return } }
        accounts[cloud, default: CloudAccountState()].isSigningIn = true
        signInTasks[cloud] = Task {
            defer {
                accounts[cloud, default: CloudAccountState()].isSigningIn = false
                accounts[cloud, default: CloudAccountState()].signInURL = nil
                signInTasks[cloud] = nil
            }
            do {
                let result = try await provider.signIn { url in
                    AppModel.shared.accounts[cloud, default: CloudAccountState()].signInURL = url
                    NSWorkspace.shared.open(url)
                }
                if let failure = result.persistenceError {
                    errorMessage = String(localized: "Couldn’t save the sign-in to the Keychain: \(failure)\n\nYou stay signed in until you quit NaviDrive; after a restart you’ll need to sign in again.")
                }
                accounts[cloud, default: CloudAccountState()].isSignedIn = true
                welcomeNotice = nil
                // Только что подключённое облако открывается в главном окне.
                activeCloud = cloud
                selection = .myDrive
                driveReloadToken += 1
                if cloud == .googleDrive { showReauthPrompt = false }
                WindowOpener.closeWelcomeWindow()
                WindowOpener.showMainWindow()
                NSApp.activate()
                await loadUser(cloud)
                await resumeQueuesAfterSignIn(cloud)
            } catch is CancellationError {
            } catch LoopbackServer.ServerError.cancelled {
            } catch {
                accounts[cloud, default: CloudAccountState()].signInError = Self.describeSignInError(error, cloud: cloud)
                NSApp.activate()
            }
        }
    }

    /// Открыть страницу входа ещё раз (например, если вкладку закрыли).
    func reopenSignInPage(_ cloud: CloudProviderKind) {
        if let url = account(cloud).signInURL { NSWorkspace.shared.open(url) }
    }

    func cancelSignIn(_ cloud: CloudProviderKind) {
        signInTasks[cloud]?.cancel()
        signInTasks[cloud] = nil
        accounts[cloud, default: CloudAccountState()].isSigningIn = false
    }

    /// Ошибки входа — понятным текстом.
    static func describeSignInError(_ error: Error, cloud: CloudProviderKind) -> String {
        switch (error, cloud) {
        case (OAuthError.authorizationDenied(let reason), _) where reason == "access_denied":
            return String(localized: "Access wasn’t granted. To use NaviDrive, allow access to Google Drive on the Google page.")
        case (OAuthError.authorizationDenied(let reason), _):
            return String(localized: "Google refused the sign-in (\(reason)).")
        case (DropboxAuthError.authorizationDenied(let reason), _) where reason == "access_denied":
            return String(localized: "Access wasn’t granted. To use NaviDrive with Dropbox, click “Allow” on the Dropbox page.")
        case (DropboxAuthError.authorizationDenied(let reason), _):
            return String(localized: "Dropbox refused the sign-in (\(reason)).")
        case (LoopbackServer.ServerError.timedOut, .googleDrive):
            return String(localized: "Google didn’t respond within 5 minutes — perhaps the sign-in tab was closed. Try again.")
        case (LoopbackServer.ServerError.timedOut, .dropbox):
            return String(localized: "Dropbox didn’t respond within 5 minutes — perhaps the sign-in tab was closed. Try again.")
        case (let urlError as URLError, .googleDrive) where CloudNetwork.isTransientError(urlError):
            return String(localized: "Can’t reach Google. Check your internet connection and try again.")
        case (let urlError as URLError, .dropbox) where CloudNetwork.isTransientError(urlError):
            return String(localized: "Can’t reach Dropbox. Check your internet connection and try again.")
        default:
            return error.localizedDescription
        }
    }

    func signOut(_ cloud: CloudProviderKind) {
        guard let provider = providers[cloud] else { return }
        Task {
            await scheduler?.setAuthorized(cloud, false)
            await uploadScheduler?.setAuthorized(cloud, false)
            await provider.signOut()
            accounts[cloud] = CloudAccountState()
            welcomeNotice = nil
            disconnected(cloud)
        }
    }

    /// Без входа главное окно не показывается: только окно приветствия.
    func showWelcome() {
        WindowOpener.closeMainWindow()
        WindowOpener.showWelcomeWindow()
    }

    /// Облако отключено: браузер забывает путь, sidebar переходит к оставшемуся облаку,
    /// без подключённых облаков — окно приветствия.
    private func disconnected(_ cloud: CloudProviderKind) {
        browserStacks = browserStacks.filter { $0.key.cloud != cloud }
        driveReloadToken += 1
        if let other = connectedClouds.first {
            if activeCloud == cloud { activeCloud = other }
        } else {
            showWelcome()
        }
    }

    /// Облако отклонило refresh_token: вход уже удалён из Связки ключей.
    /// Очереди облака останавливаются с сохранением прогресса и продолжатся после входа тем же аккаунтом.
    func handleAccessRevoked(_ cloud: CloudProviderKind) {
        guard account(cloud).isSignedIn else { return }
        if AppSettings.queueOwnerAwaitingSignIn(for: cloud) == nil {
            AppSettings.setQueueOwnerAwaitingSignIn(account(cloud).userEmail ?? "", for: cloud)
        }
        accounts[cloud] = CloudAccountState()
        if cloud == .googleDrive { showReauthPrompt = false }
        if accountSwitch?.provider == cloud { accountSwitch = nil }
        welcomeNotice = cloud == .googleDrive
            ? String(localized: "Access to Google Drive has expired. Please sign in again.")
            : String(localized: "Access to Dropbox has expired. Please sign in again.")
        Task {
            await scheduler?.setAuthorized(cloud, false)
            await uploadScheduler?.setAuthorized(cloud, false)
        }
        if isSignedIn {
            errorMessage = welcomeNotice
            welcomeNotice = nil
        }
        disconnected(cloud)
    }

    /// После входа: тот же аккаунт (или очереди нет) — загрузки и отправки облака продолжаются;
    /// другой аккаунт — сначала спросить, что сделать с очередью предыдущего.
    func resumeQueuesAfterSignIn(_ cloud: CloudProviderKind) async {
        if let previous = AppSettings.queueOwnerAwaitingSignIn(for: cloud) {
            let current = account(cloud).userEmail ?? ""
            let sameAccount = !previous.isEmpty && previous.caseInsensitiveCompare(current) == .orderedSame
            let hasQueue = await hasUnfinishedTasks(cloud)
            if !sameAccount && hasQueue {
                accountSwitch = AccountSwitch(provider: cloud, previousEmail: previous)
                return
            }
            AppSettings.setQueueOwnerAwaitingSignIn(nil, for: cloud)
        }
        await scheduler?.setAuthorized(cloud, true)
        await uploadScheduler?.setAuthorized(cloud, true)
    }

    private func hasUnfinishedTasks(_ cloud: CloudProviderKind) async -> Bool {
        guard let db else { return false }
        return await Task.detached(priority: .userInitiated) {
            !db.tasks(statuses: TaskStatus.pending, limit: 1, provider: cloud).isEmpty
                || !db.uploads(statuses: UploadStatus.pending, provider: cloud).isEmpty
        }.value
    }

    /// Ответ на вопрос об очереди предыдущего аккаунта: оставить на паузе или удалить из очереди.
    func resolveAccountSwitch(keepPaused: Bool) {
        guard let change = accountSwitch else { return }
        accountSwitch = nil
        let cloud = change.provider
        AppSettings.setQueueOwnerAwaitingSignIn(nil, for: cloud)
        Task {
            if keepPaused {
                await scheduler?.pauseUnfinished(cloud)
                await uploadScheduler?.pauseUnfinished(cloud)
            } else {
                await scheduler?.cancelUnfinished(cloud)
                await uploadScheduler?.cancelUnfinished(cloud)
            }
            guard account(cloud).isSignedIn else { return }
            await scheduler?.setAuthorized(cloud, true)
            await uploadScheduler?.setAuthorized(cloud, true)
            await refresh()
        }
    }

    func loadUser(_ cloud: CloudProviderKind) async {
        guard let provider = providers[cloud], let user = try? await provider.currentAccount() else { return }
        accounts[cloud, default: CloudAccountState()].userName = user.displayName
        accounts[cloud, default: CloudAccountState()].userEmail = user.email
    }
}
