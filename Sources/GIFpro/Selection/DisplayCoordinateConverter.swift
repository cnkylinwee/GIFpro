import CoreGraphics

struct DisplayCoordinateConverter: Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidBackingScale
        case selectionTooSmall
        case selectionOutsideDisplay
        case unsupportedOutputScale
    }

    func convert(
        displayID: CGDirectDisplayID,
        displayFrame: CGRect,
        selection: CGRect,
        backingScale: CGFloat,
        outputScale: RecordingSettings.Scale
    ) throws -> CaptureRegion {
        guard backingScale >= 1 else { throw Error.invalidBackingScale }
        guard selection.width >= SelectionGeometry.minimumSize.width,
              selection.height >= SelectionGeometry.minimumSize.height else {
            throw Error.selectionTooSmall
        }
        guard displayFrame.contains(selection) else { throw Error.selectionOutsideDisplay }
        guard CGFloat(outputScale.rawValue) <= backingScale else { throw Error.unsupportedOutputScale }

        let sourceRect = CGRect(
            x: selection.minX - displayFrame.minX,
            y: displayFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        let logicalSize = CGSize(
            width: selection.width.rounded(),
            height: selection.height.rounded()
        )
        let scale = CGFloat(outputScale.rawValue)

        return CaptureRegion(
            displayID: displayID,
            globalRect: selection,
            sourceRect: sourceRect,
            logicalPixelSize: logicalSize,
            outputPixelSize: CGSize(
                width: (logicalSize.width * scale).rounded(),
                height: (logicalSize.height * scale).rounded()
            ),
            backingScale: backingScale
        )
    }
}
