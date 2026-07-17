struct RecordingSettings: Equatable, Sendable {
    enum Scale: Int, CaseIterable, Sendable {
        case one = 1
        case two = 2
    }

    enum FramesPerSecond: Int, CaseIterable, Sendable {
        case eight = 8
        case twelve = 12
        case fifteen = 15
    }

    enum Duration: Int, CaseIterable, Sendable {
        case fifteen = 15
        case thirty = 30
        case sixty = 60
        case ninety = 90
    }

    static let `default` = RecordingSettings(
        scale: .one,
        fps: .twelve,
        duration: .thirty,
        showsCursor: true
    )

    var scale: Scale
    var fps: FramesPerSecond
    var duration: Duration
    var showsCursor: Bool

    init(scale: Scale, fps: FramesPerSecond, duration: Duration, showsCursor: Bool) {
        self.scale = scale
        self.fps = fps
        self.duration = duration
        self.showsCursor = showsCursor
    }

    init(scaleRawValue: Int, fpsRawValue: Int, durationRawValue: Int, showsCursor: Bool) {
        self.init(
            scale: Scale(rawValue: scaleRawValue) ?? Self.default.scale,
            fps: FramesPerSecond(rawValue: fpsRawValue) ?? Self.default.fps,
            duration: Duration(rawValue: durationRawValue) ?? Self.default.duration,
            showsCursor: showsCursor
        )
    }
}
