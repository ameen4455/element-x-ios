//
// Copyright 2022 New Vector Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import AppAuth
import SwiftUI

struct LoginScreenCoordinatorParameters {
    /// The service used to authenticate the user.
    let authenticationService: AuthenticationServiceProxyProtocol
    /// The navigation router used to present the server selection screen.
    let navigationStackCoordinator: NavigationStackCoordinator
}

enum LoginScreenCoordinatorAction {
    /// Login was successful.
    case signedIn(UserSessionProtocol)
}

final class LoginScreenCoordinator: CoordinatorProtocol {
    private let parameters: LoginScreenCoordinatorParameters
    private var viewModel: LoginScreenViewModelProtocol
    private let hostingController: UIViewController
    /// Passed to the OIDC service to provide a view controller from which to present the authentication session.
    private let oidcUserAgent: OIDExternalUserAgentIOS?
    
    private var currentTask: Task<Void, Error>? {
        willSet {
            currentTask?.cancel()
        }
    }
    
    private var authenticationService: AuthenticationServiceProxyProtocol { parameters.authenticationService }
    private var navigationStackCoordinator: NavigationStackCoordinator { parameters.navigationStackCoordinator }

    var callback: (@MainActor (LoginScreenCoordinatorAction) -> Void)?
    
    // MARK: - Setup
    
    init(parameters: LoginScreenCoordinatorParameters) {
        self.parameters = parameters
        
        viewModel = LoginScreenViewModel(homeserver: parameters.authenticationService.homeserver)
        
        hostingController = UIHostingController(rootView: LoginScreen(context: viewModel.context))
        oidcUserAgent = OIDExternalUserAgentIOS(presenting: hostingController)
    }
    
    // MARK: - Public

    func start() {
        viewModel.callback = { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .selectServer:
                self.presentServerSelectionScreen()
            case .parseUsername(let username):
                self.parseUsername(username)
            case .forgotPassword:
                self.showForgotPasswordScreen()
            case .login(let username, let password):
                self.login(username: username, password: password)
            case .continueWithOIDC:
                self.loginWithOIDC()
            }
        }
    }

    func stop() {
        stopLoading()
    }
    
    func toPresentable() -> AnyView {
        AnyView(LoginScreen(context: viewModel.context))
    }
    
    // MARK: - Private
    
    static let loadingIndicatorIdentifier = "LoginCoordinatorLoading"
    
    private func startLoading(isInteractionBlocking: Bool) {
        if isInteractionBlocking {
            ServiceLocator.shared.userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                                        type: .modal,
                                                                                        title: L10n.commonLoading,
                                                                                        persistent: true))
        } else {
            viewModel.update(isLoading: true)
        }
    }
    
    private func stopLoading() {
        viewModel.update(isLoading: false)
        ServiceLocator.shared.userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
    
    private func indicateSuccess() {
        ServiceLocator.shared.userIndicatorController.submitIndicator(UserIndicator(title: L10n.commonSuccess))
    }
    
    private func indicateFailure() {
        ServiceLocator.shared.userIndicatorController.submitIndicator(UserIndicator(title: L10n.commonError))
    }
    
    /// Processes an error to either update the flow or display it to the user.
    private func handleError(_ error: AuthenticationServiceError) {
        MXLog.info("Error occurred: \(error)")
        
        switch error {
        case .invalidCredentials:
            viewModel.displayError(.alert(L10n.screenLoginErrorInvalidCredentials))
        case .accountDeactivated:
            viewModel.displayError(.alert(L10n.screenLoginErrorDeactivatedAccount))
        case .slidingSyncNotAvailable:
            viewModel.displayError(.slidingSyncAlert)
        default:
            viewModel.displayError(.alert(L10n.errorUnknown))
        }
    }
    
    private func loginWithOIDC() {
        guard let oidcUserAgent else {
            handleError(AuthenticationServiceError.oidcError(.notSupported))
            return
        }
        
        startLoading(isInteractionBlocking: true)
        
        Task {
            switch await authenticationService.loginWithOIDC(userAgent: oidcUserAgent) {
            case .success(let userSession):
                callback?(.signedIn(userSession))
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Requests the authentication coordinator to log in using the specified credentials.
    private func login(username: String, password: String) {
        MXLog.info("Starting login with password.")
        startLoading(isInteractionBlocking: true)
        
        Task {
            switch await authenticationService.login(username: username,
                                                     password: password,
                                                     initialDeviceName: UIDevice.current.initialDeviceName,
                                                     deviceId: nil) {
            case .success(let userSession):
                callback?(.signedIn(userSession))
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Parses the specified username and looks up the homeserver when a Matrix ID is entered.
    private func parseUsername(_ username: String) {
        guard MatrixEntityRegex.isMatrixUserIdentifier(username) else { return }
        
        let homeserverDomain = String(username.split(separator: ":")[1])
        
        startLoading(isInteractionBlocking: false)
        
        Task {
            switch await authenticationService.configure(for: homeserverDomain) {
            case .success:
                updateViewModel()
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Updates the view model with a different homeserver.
    private func updateViewModel() {
        viewModel.update(homeserver: authenticationService.homeserver)
        indicateSuccess()
    }
    
    /// Presents the server selection screen as a modal.
    private func presentServerSelectionScreen() {
        let parameters = ServerSelectionScreenCoordinatorParameters(authenticationService: authenticationService,
                                                                    userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                    isModallyPresented: false)
        
        let coordinator = ServerSelectionScreenCoordinator(parameters: parameters)
        coordinator.callback = { [weak self, weak coordinator] action in
            guard let self, let coordinator else { return }
            self.serverSelectionCoordinator(coordinator, didCompleteWith: action)
        }
        
        navigationStackCoordinator.push(coordinator)
    }
    
    /// Handles the result from the server selection modal, dismissing it after updating the view.
    private func serverSelectionCoordinator(_ coordinator: ServerSelectionScreenCoordinator,
                                            didCompleteWith action: ServerSelectionScreenCoordinatorAction) {
        if action == .updated {
            updateViewModel()
        }
        
        navigationStackCoordinator.pop()
    }

    /// Shows the forgot password screen.
    private func showForgotPasswordScreen() {
        viewModel.displayError(.alert("Not implemented."))
    }
}