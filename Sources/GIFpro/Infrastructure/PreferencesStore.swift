import Foundation
import CoreFoundation

struct PreferencesStore {
    private enum Key {
        static let scale = "recording.scale"
        static let fps = "recording.fps"
        static let duration = "recording.duration"
        static let showsCursor = "recording.showsCursor"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingSettings {
        let fallback = RecordingSettings.default
        return RecordingSettings(
            scaleRawValue: strictInteger(forKey: Key.scale) ?? fallback.scale.rawValue,
            fpsRawValue: strictInteger(forKey: Key.fps) ?? fallback.fps.rawValue,
            durationRawValue: strictInteger(forKey: Key.duration) ?? fallback.duration.rawValue,
            showsCursor: strictBoolean(forKey: Key.showsCursor) ?? fallback.showsCursor
        )
    }

    func save(_ settings: RecordingSettings) {
        defaults.set(settings.scale.rawValue, forKey: Key.scale)
        defaults.set(settings.fps.rawValue, forKey: Key.fps)
        defaults.set(settings.duration.rawValue, forKey: Key.duration)
        defaults.set(settings.showsCursor, forKey: Key.showsCursor)
    }

    private func strictInteger(forKey key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        return number.intValue
    }

    private func strictBoolean(forKey key: String) -> Bool? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
