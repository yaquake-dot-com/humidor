// SPDX-License-Identifier: GPL-3.0-or-later

import NicotineCore

extension Events {

    /// Connects a callback to a network message event. Messages the core
    /// decided to ignore are not passed to the callback.
    @MainActor
    @discardableResult
    func connectMessage<Message: SlskMessage>(_ event: EventName<Message>,
                                              _ function: @escaping @MainActor (Message) -> Void) -> EventConnection {
        connect(event) { message in
            if !message.isIgnored {
                function(message)
            }
        }
    }
}
