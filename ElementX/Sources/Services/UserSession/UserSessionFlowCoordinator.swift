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

import SwiftUI

enum UserSessionFlowCoordinatorAction {
    case signOut
}

class UserSessionFlowCoordinator: CoordinatorProtocol {
    private let stateMachine: UserSessionFlowCoordinatorStateMachine
    
    private let userSession: UserSessionProtocol
    private let navigationSplitCoordinator: NavigationSplitCoordinator
    private let bugReportService: BugReportServiceProtocol
    private let roomTimelineControllerFactory: RoomTimelineControllerFactoryProtocol
    private let emojiProvider: EmojiProviderProtocol = EmojiProvider()
    
    private let sidebarNavigationStackCoordinator: NavigationStackCoordinator
    private let detailNavigationStackCoordinator: NavigationStackCoordinator

    var callback: ((UserSessionFlowCoordinatorAction) -> Void)?
    
    init(userSession: UserSessionProtocol,
         navigationSplitCoordinator: NavigationSplitCoordinator,
         bugReportService: BugReportServiceProtocol,
         roomTimelineControllerFactory: RoomTimelineControllerFactoryProtocol) {
        stateMachine = UserSessionFlowCoordinatorStateMachine()
        self.userSession = userSession
        self.navigationSplitCoordinator = navigationSplitCoordinator
        self.bugReportService = bugReportService
        self.roomTimelineControllerFactory = roomTimelineControllerFactory
        
        sidebarNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        detailNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        
        navigationSplitCoordinator.setSidebarCoordinator(sidebarNavigationStackCoordinator)
        
        setupStateMachine()
    }
    
    func start() {
        stateMachine.processEvent(.start)
    }
    
    func stop() { }

    func isDisplayingRoomScreen(withRoomId roomId: String) -> Bool {
        stateMachine.isDisplayingRoomScreen(withRoomId: roomId)
    }

    func tryDisplayingRoomScreen(roomId: String) {
        stateMachine.processEvent(.selectRoom(roomId: roomId))
    }

    // MARK: - Private
    
    // swiftlint:disable:next cyclomatic_complexity
    private func setupStateMachine() {
        stateMachine.addTransitionHandler { [weak self] context in
            guard let self else { return }
            
            switch (context.fromState, context.event, context.toState) {
            case (.initial, .start, .roomList):
                self.presentHomeScreen()
                
            case(.roomList(let currentRoomId), .selectRoom, .roomList(let selectedRoomId)):
                guard let selectedRoomId,
                      selectedRoomId != currentRoomId else {
                    return
                }
                
                self.presentRoomWithIdentifier(selectedRoomId)
            case(.roomList, .deselectRoom, .roomList):
                break

            case (.roomList, .showSessionVerificationScreen, .sessionVerificationScreen):
                self.presentSessionVerification()
            case (.sessionVerificationScreen, .dismissedSessionVerificationScreen, .roomList):
                break
                
            case (.roomList, .showSettingsScreen, .settingsScreen):
                self.presentSettingsScreen()
            case (.settingsScreen, .dismissedSettingsScreen, .roomList):
                break
                
            case (.roomList, .feedbackScreen, .feedbackScreen):
                self.presentFeedbackScreen()
            case (.feedbackScreen, .dismissedFeedbackScreen, .roomList):
                break
                
            case (.roomList, .showStartChatScreen, .startChatScreen):
                self.presentStartChat()
            case (.startChatScreen, .dismissedStartChatScreen, .roomList):
                break
            default:
                fatalError("Unknown transition: \(context)")
            }
        }
        
        stateMachine.addErrorHandler { context in
            fatalError("Failed transition with context: \(context)")
        }
    }
    
    private func presentHomeScreen() {
        userSession.clientProxy.startSync()

        let parameters = HomeScreenCoordinatorParameters(userSession: userSession,
                                                         attributedStringBuilder: AttributedStringBuilder(),
                                                         bugReportService: bugReportService,
                                                         navigationStackCoordinator: detailNavigationStackCoordinator)
        let coordinator = HomeScreenCoordinator(parameters: parameters)

        coordinator.callback = { [weak self] action in
            guard let self else { return }

            switch action {
            case .presentRoom(let roomIdentifier):
                self.stateMachine.processEvent(.selectRoom(roomId: roomIdentifier))
            case .presentSettingsScreen:
                self.stateMachine.processEvent(.showSettingsScreen)
            case .presentFeedbackScreen:
                self.stateMachine.processEvent(.feedbackScreen)
            case .presentSessionVerificationScreen:
                self.stateMachine.processEvent(.showSessionVerificationScreen)
            case .presentStartChatScreen:
                self.stateMachine.processEvent(.showStartChatScreen)
            case .signOut:
                self.callback?(.signOut)
            }
        }
        
        sidebarNavigationStackCoordinator.setRootCoordinator(coordinator)
    }
    
    // MARK: Rooms

    private func presentRoomWithIdentifier(_ roomIdentifier: String) {
        Task { @MainActor in
            guard let roomProxy = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                MXLog.error("Invalid room identifier: \(roomIdentifier)")
                return
            }
            let userId = userSession.clientProxy.userID

            let timelineItemFactory = RoomTimelineItemFactory(userID: userId,
                                                              mediaProvider: userSession.mediaProvider,
                                                              attributedStringBuilder: AttributedStringBuilder(),
                                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: userId))
            
            let timelineController = roomTimelineControllerFactory.buildRoomTimelineController(userId: userId,
                                                                                               roomProxy: roomProxy,
                                                                                               timelineItemFactory: timelineItemFactory,
                                                                                               mediaProvider: userSession.mediaProvider)

            let parameters = RoomScreenCoordinatorParameters(navigationStackCoordinator: detailNavigationStackCoordinator,
                                                             roomProxy: roomProxy,
                                                             timelineController: timelineController,
                                                             mediaProvider: userSession.mediaProvider,
                                                             emojiProvider: emojiProvider)
            let coordinator = RoomScreenCoordinator(parameters: parameters)
            coordinator.callback = { [weak self] action in
                switch action {
                case .leftRoom:
                    self?.dismissRoom()
                }
            }
            
            detailNavigationStackCoordinator.setRootCoordinator(coordinator) { [weak self, roomIdentifier] in
                guard let self else { return }
                
                // Move the state machine to no room selected if the room currently being dimissed
                // is the same as the one selected in the state machine.
                // This generally happens when popping the room screen while in a compact layout
                if case let .roomList(selectedRoomId) = self.stateMachine.state, selectedRoomId == roomIdentifier {
                    self.stateMachine.processEvent(.deselectRoom)
                    self.detailNavigationStackCoordinator.setRootCoordinator(nil)
                }
            }
            
            if navigationSplitCoordinator.detailCoordinator == nil {
                navigationSplitCoordinator.setDetailCoordinator(detailNavigationStackCoordinator)
            }
        }
    }

    private func dismissRoom() {
        detailNavigationStackCoordinator.popToRoot(animated: true)
        navigationSplitCoordinator.setDetailCoordinator(nil)
    }
        
    // MARK: Settings
    
    private func presentSettingsScreen() {
        let settingsNavigationStackCoordinator = NavigationStackCoordinator()
        
        let userIndicatorController = UserIndicatorController(rootCoordinator: settingsNavigationStackCoordinator)
        
        let parameters = SettingsScreenCoordinatorParameters(navigationStackCoordinator: settingsNavigationStackCoordinator,
                                                             userIndicatorController: userIndicatorController,
                                                             userSession: userSession,
                                                             bugReportService: bugReportService)
        let settingsScreenCoordinator = SettingsScreenCoordinator(parameters: parameters)
        settingsScreenCoordinator.callback = { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                self.navigationSplitCoordinator.setSheetCoordinator(nil)
            case .logout:
                self.navigationSplitCoordinator.setSheetCoordinator(nil)
                self.callback?(.signOut)
            }
        }
        
        settingsNavigationStackCoordinator.setRootCoordinator(settingsScreenCoordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(userIndicatorController) { [weak self] in
            self?.stateMachine.processEvent(.dismissedSettingsScreen)
        }
    }
    
    // MARK: Session verification
    
    private func presentSessionVerification() {
        guard let sessionVerificationController = userSession.sessionVerificationController else {
            fatalError("The sessionVerificationController should aways be valid at this point")
        }
        
        let parameters = SessionVerificationCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController)
        
        let coordinator = SessionVerificationCoordinator(parameters: parameters)
        
        coordinator.callback = { [weak self] in
            self?.navigationSplitCoordinator.setSheetCoordinator(nil)
        }
        
        navigationSplitCoordinator.setSheetCoordinator(coordinator) { [weak self] in
            self?.stateMachine.processEvent(.dismissedSessionVerificationScreen)
        }
    }
    
    // MARK: Start Chat
    
    private func presentStartChat() {
        let startChatNavigationStackCoordinator = NavigationStackCoordinator()
        
        let userIndicatorController = UserIndicatorController(rootCoordinator: startChatNavigationStackCoordinator)
        
        let parameters = StartChatCoordinatorParameters(userSession: userSession, userIndicatorController: userIndicatorController)
        let coordinator = StartChatCoordinator(parameters: parameters)
        coordinator.callback = { [weak self] action in
            guard let self else { return }
            switch action {
            case .close:
                self.navigationSplitCoordinator.setSheetCoordinator(nil)
            case .openRoom(let identifier):
                self.navigationSplitCoordinator.setSheetCoordinator(nil)
                self.stateMachine.processEvent(.selectRoom(roomId: identifier))
            }
        }

        startChatNavigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(userIndicatorController) { [weak self] in
            self?.stateMachine.processEvent(.dismissedStartChatScreen)
        }
    }
        
    // MARK: Bug reporting
    
    private func presentFeedbackScreen(for image: UIImage? = nil) {
        let feedbackNavigationStackCoordinator = NavigationStackCoordinator()
        
        let userIndicatorController = UserIndicatorController(rootCoordinator: feedbackNavigationStackCoordinator)
        
        let parameters = BugReportCoordinatorParameters(bugReportService: bugReportService,
                                                        userID: userSession.userID,
                                                        deviceID: userSession.deviceID,
                                                        userIndicatorController: userIndicatorController,
                                                        screenshot: image,
                                                        isModallyPresented: true)
        let coordinator = BugReportCoordinator(parameters: parameters)
        coordinator.completion = { [weak self] _ in
            self?.navigationSplitCoordinator.setSheetCoordinator(nil)
        }

        feedbackNavigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(userIndicatorController) { [weak self] in
            self?.stateMachine.processEvent(.dismissedFeedbackScreen)
        }
    }
}
