import SZUNetCore

@MainActor
extension AppModel {
    func loginNow() {
        guard !automation.hasActiveOperation else { return }
        automation.cancelProbe()
        isRefreshing = false

        let coordinator = coordinator
        guard automation.startManualOperation(
            operation: { await coordinator.loginNow() },
            completion: { [weak self] result in
                self?.finishOperation(result, alwaysNotify: true)
            }
        ) else {
            return
        }
        isBusy = true
    }

    func logout() {
        guard !automation.hasManualOperation else { return }

        // Manual logout owns authentication until the portal confirms offline.
        // Invalidating both lanes prevents an older online probe or automatic
        // login result from being published after the user's explicit action.
        automation.cancelProbe()
        automation.cancelAutoLogin()
        isRefreshing = false
        isBusy = automation.hasActiveOperation

        let coordinator = coordinator
        guard automation.startManualOperation(
            operation: { await coordinator.logout() },
            completion: { [weak self] result in
                guard let self else { return }
                self.autoLoginEnabled = !coordinator.pauseStore.isPaused
                self.finishOperation(result, alwaysNotify: true)
            }
        ) else {
            return
        }
        isBusy = true
    }
}
