import Foundation

@propertyWrapper
public struct UserDefault<T> {
    let key: String
    let defaultValue: T

    public init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }
    
    public var wrappedValue: T {
        get { DefaultsStore.current.object(forKey: key) as? T ?? defaultValue }
        set { DefaultsStore.current.set(newValue, forKey: key) }
    }
}

@propertyWrapper
public struct OptionalUserDefault<T> {
    let key: String

    public init(key: String) {
        self.key = key
    }
    
    public var wrappedValue: T? {
        get { DefaultsStore.current.object(forKey: key) as? T }
        set { DefaultsStore.current.set(newValue, forKey: key) }
    }
}
