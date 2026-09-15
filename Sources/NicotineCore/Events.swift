// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A typed event identifier. The payload type determines the type of value
/// passed to callbacks connected to the event.
///
/// Events are declared as static members in constrained extensions, e.g.
/// ``EventName/serverLogin``, so they can be referenced with implicit member
/// syntax: `events.connect(.serverLogin) { msg in ... }`.
public struct EventName<Payload>: Hashable, Sendable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var description: String { name }
}

/// Token returned by ``Events/connect(_:_:)``, used to disconnect a callback.
public struct EventConnection: Hashable, Sendable {
    fileprivate let name: String
    fileprivate let id: Int
}

/// Event dispatcher and scheduler.
///
/// All callbacks run on the main thread. Other threads (such as the network
/// thread) use ``emitMainThread(_:_:)`` to deliver events to the main thread.
public final class Events: @unchecked Sendable {

    private struct Callback {
        let id: Int
        let function: @MainActor (Any) -> Void
    }

    private var callbacks: [String: [Callback]] = [:]
    private var nextCallbackID = 0
    private var scheduledTimers: [Int: DispatchSourceTimer] = [:]
    private var nextScheduledEventID = 0
    private var isActive = false

    // MARK: Connecting

    @MainActor
    public func enable() {
        guard !isActive else {
            return
        }

        isActive = true
        connect(.quit, quit)
    }

    @MainActor
    @discardableResult
    public func connect<Payload>(_ event: EventName<Payload>,
                                 _ function: @escaping @MainActor (Payload) -> Void) -> EventConnection {
        nextCallbackID += 1

        let callback = Callback(id: nextCallbackID) { payload in
            function(payload as! Payload)  // swiftlint:disable:this force_cast
        }

        callbacks[event.name, default: []].append(callback)
        return EventConnection(name: event.name, id: nextCallbackID)
    }

    @MainActor
    @discardableResult
    public func connect(_ event: EventName<Void>, _ function: @escaping @MainActor () -> Void) -> EventConnection {
        connect(event) { (_: Void) in function() }
    }

    @MainActor
    public func disconnect(_ connection: EventConnection) {
        callbacks[connection.name]?.removeAll { $0.id == connection.id }
    }

    // MARK: Emitting

    @MainActor
    public func emit<Payload>(_ event: EventName<Payload>, _ payload: Payload) {
        guard var functions = callbacks[event.name] else {
            return
        }

        if event.name == EventName<Void>.quit.name {
            // Event and log modules register callbacks first, but need to quit last
            functions.reverse()
        }

        for callback in functions {
            callback.function(payload)
        }
    }

    @MainActor
    public func emit(_ event: EventName<Void>) {
        emit(event, ())
    }

    /// Emits an event on the main thread. Safe to call from any thread.
    public func emitMainThread<Payload: Sendable>(_ event: EventName<Payload>, _ payload: Payload) {
        invokeMainThread {
            self.emit(event, payload)
        }
    }

    public func emitMainThread(_ event: EventName<Void>) {
        emitMainThread(event, ())
    }

    /// Runs a function on the main thread. Safe to call from any thread.
    public func invokeMainThread(_ function: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                function()
            }
        }
    }

    // MARK: Scheduling

    /// Schedules a function to run on the main thread after a delay (in seconds).
    ///
    /// - Returns: an identifier that can be passed to ``cancelScheduled(_:)``
    @MainActor
    @discardableResult
    public func schedule(delay: TimeInterval, repeat shouldRepeat: Bool = false,
                         _ function: @escaping @MainActor () -> Void) -> Int {
        nextScheduledEventID += 1

        let eventID = nextScheduledEventID
        let timer = DispatchSource.makeTimerSource(queue: .main)

        if shouldRepeat {
            timer.schedule(deadline: .now() + delay, repeating: delay)
        } else {
            timer.schedule(deadline: .now() + delay)
        }

        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if !shouldRepeat {
                    self?.cancelScheduled(eventID)
                }
                function()
            }
        }

        scheduledTimers[eventID] = timer
        timer.resume()

        return eventID
    }

    @MainActor
    public func cancelScheduled(_ eventID: Int?) {
        guard let eventID, let timer = scheduledTimers.removeValue(forKey: eventID) else {
            return
        }
        timer.cancel()
    }

    // MARK: Quitting

    @MainActor
    private func quit() {
        isActive = false
        callbacks.removeAll()

        for timer in scheduledTimers.values {
            timer.cancel()
        }
        scheduledTimers.removeAll()
    }
}

public let events = Events()
