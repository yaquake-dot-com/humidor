// SPDX-License-Identifier: GPL-3.0-or-later

/// A dictionary that preserves the insertion order of its keys.
public struct OrderedDictionary<Key: Hashable, Value>: Sequence, ExpressibleByDictionaryLiteral {
    private var storage: [Key: (index: Int, value: Value)] = [:]
    private var orderedKeys: [Key?] = []
    private var removedCount = 0

    public init() {}

    public init(dictionaryLiteral elements: (Key, Value)...) {
        for (key, value) in elements {
            self[key] = value
        }
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Keys in insertion order.
    public var keys: [Key] {
        orderedKeys.compactMap { $0 }
    }

    /// Values in insertion order.
    public var values: [Value] {
        orderedKeys.compactMap { key in key.flatMap { storage[$0]?.value } }
    }

    public var first: (key: Key, value: Value)? {
        for key in orderedKeys {
            if let key, let entry = storage[key] {
                return (key, entry.value)
            }
        }
        return nil
    }

    public var last: (key: Key, value: Value)? {
        for key in orderedKeys.reversed() {
            if let key, let entry = storage[key] {
                return (key, entry.value)
            }
        }
        return nil
    }

    public subscript(key: Key) -> Value? {
        get { storage[key]?.value }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }

            if let entry = storage[key] {
                storage[key] = (entry.index, newValue)
            } else {
                storage[key] = (orderedKeys.count, newValue)
                orderedKeys.append(key)
            }
        }
    }

    public subscript(key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        get { self[key] ?? defaultValue() }
        set { self[key] = newValue }
    }

    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        guard let entry = storage.removeValue(forKey: key) else {
            return nil
        }

        orderedKeys[entry.index] = nil
        removedCount += 1

        if removedCount > 64 && removedCount > orderedKeys.count / 2 {
            compact()
        }

        return entry.value
    }

    public mutating func removeAll() {
        storage.removeAll()
        orderedKeys.removeAll()
        removedCount = 0
    }

    private mutating func compact() {
        orderedKeys = orderedKeys.filter { $0 != nil }
        removedCount = 0

        for (index, key) in orderedKeys.enumerated() {
            if let key, let entry = storage[key] {
                storage[key] = (index, entry.value)
            }
        }
    }

    public func makeIterator() -> AnyIterator<(key: Key, value: Value)> {
        var iterator = orderedKeys.makeIterator()
        let storage = self.storage

        return AnyIterator {
            while let key = iterator.next() {
                if let key, let entry = storage[key] {
                    return (key, entry.value)
                }
            }
            return nil
        }
    }
}

/// A set that preserves insertion order.
public struct OrderedSet<Element: Hashable>: Sequence {
    private var dictionary = OrderedDictionary<Element, Void>()

    public init() {}

    public var count: Int { dictionary.count }
    public var isEmpty: Bool { dictionary.isEmpty }

    public func contains(_ element: Element) -> Bool {
        dictionary[element] != nil
    }

    public mutating func append(_ element: Element) {
        if dictionary[element] == nil {
            dictionary[element] = ()
        }
    }

    @discardableResult
    public mutating func remove(_ element: Element) -> Bool {
        dictionary.removeValue(forKey: element) != nil
    }

    public mutating func removeAll() {
        dictionary.removeAll()
    }

    public func makeIterator() -> AnyIterator<Element> {
        let iterator = dictionary.makeIterator()
        return AnyIterator { iterator.next()?.key }
    }
}
