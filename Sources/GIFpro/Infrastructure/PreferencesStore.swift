import Foundation

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
            scaleRawValue: defaults.object(forKey: Key.scale) as? Int ?? fallback.scale.rawValue,
            fpsRawValue: defaults.object(forKey: Key.fps) as? Int ?? fallback.fps.rawValue,
            durationRawValue: defaults.object(forKey: Key.duration) as? Int ?? fallback.duration.rawValue,
            showsCursor: defaults.object(forKey: Key.showsCursor) as? Bool ?? fallback.showsCursor
        )
    }

    func save(_ settings: RecordingSettings) {
        defaults.set(settings.scale.rawValue, forKey: Key.scale)
        defaults.set(settings.fps.rawValue, forKey: Key.fps)
        defaults.set(settings.duration.rawValue, forKey: Key.duration)
        defaults.set(settings.showsCursor, forKey: Key.showsCursor)
    }
}
