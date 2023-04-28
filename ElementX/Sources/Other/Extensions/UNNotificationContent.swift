//
// Copyright 2023 New Vector Ltd
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

import Foundation
import Intents
import UserNotifications

extension UNNotificationContent {
    @objc var receiverID: String? {
        userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] as? String
    }
}

extension UNMutableNotificationContent {
    override var receiverID: String? {
        get {
            userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] as? String
        }
        set {
            userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] = newValue
        }
    }
    
    func addMediaAttachment(using mediaProvider: MediaProviderProtocol?,
                            mediaSource: MediaSourceProxy) async -> UNMutableNotificationContent {
        guard let mediaProvider else {
            return self
        }
        switch await mediaProvider.loadFileFromSource(mediaSource) {
        case .success(let file):
            do {
                let identifier = ProcessInfo.processInfo.globallyUniqueString
                let newURL = try FileManager.default.copyFileToTemporaryDirectory(file: file.url, with: "\(identifier).\(file.url.pathExtension)")
                let attachment = try UNNotificationAttachment(identifier: identifier,
                                                              url: newURL,
                                                              options: nil)
                attachments.append(attachment)
            } catch {
                MXLog.error("Couldn't add media attachment:: \(error)")
                return self
            }
        case .failure(let error):
            MXLog.error("Couldn't load the file for media attachment: \(error)")
        }

        return self
    }

    // swiftlint:disable:next function_parameter_count
    func addSenderIcon(using mediaProvider: MediaProviderProtocol?,
                       senderId: String,
                       receiverId: String,
                       senderName: String,
                       groupName: String?,
                       mediaSource: MediaSourceProxy?,
                       roomId: String) async throws -> UNMutableNotificationContent {
        var image: INImage?
        if let mediaSource {
            switch await mediaProvider?.loadFileFromSource(mediaSource) {
            case .success(let mediaFile):
                image = try INImage(imageData: Data(contentsOf: mediaFile.url))
            case .failure(let error):
                MXLog.error("Couldn't add sender icon: \(error)")
            case .none:
                break
            }
        }

        let senderHandle = INPersonHandle(value: senderId, type: .unknown)
        let sender = INPerson(personHandle: senderHandle,
                              nameComponents: nil,
                              displayName: senderName,
                              image: image,
                              contactIdentifier: nil,
                              customIdentifier: nil)

        // These are required to show the group name as subtitle
        var speakableGroupName: INSpeakableString?
        var recipients: [INPerson]?
        if let groupName {
            let meHandle = INPersonHandle(value: receiverId, type: .unknown)
            let me = INPerson(personHandle: meHandle, nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
            speakableGroupName = INSpeakableString(spokenPhrase: groupName)
            recipients = [sender, me]
        }

        let intent = INSendMessageIntent(recipients: recipients,
                                         outgoingMessageType: .outgoingMessageText,
                                         content: nil,
                                         speakableGroupName: speakableGroupName,
                                         conversationIdentifier: roomId,
                                         serviceName: nil,
                                         sender: sender,
                                         attachments: nil)
        intent.setImage(image, forParameterNamed: \.speakableGroupName)

        // Use the intent to initialize the interaction.
        let interaction = INInteraction(intent: intent, response: nil)

        // Interaction direction is incoming because the user is
        // receiving this message.
        interaction.direction = .incoming

        // Donate the interaction before updating notification content.
        try await interaction.donate()
        // Update notification content before displaying the
        // communication notification.
        let updatedContent = try updating(from: intent)

        // swiftlint:disable:next force_cast
        return updatedContent.mutableCopy() as! UNMutableNotificationContent
    }
}