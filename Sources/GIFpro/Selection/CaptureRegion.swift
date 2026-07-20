import CoreGraphics

struct CaptureRegion: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let globalRect: CGRect
    let sourceRect: CGRect
    let logicalPixelSize: CGSize
    let outputPixelSize: CGSize
    let backingScale: CGFloat
}

enum ResizeHandle: CaseIterable, Hashable, Sendable {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

enum SelectionGeometry {
    static let minimumSize = CGSize(width: 64, height: 64)
    static let defaultSize = CGSize(width: 300, height: 200)

    static func resized(
        _ rect: CGRect,
        handle: ResizeHandle,
        translation: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesLeft {
            minX = min(max(rect.minX + translation.x, bounds.minX), maxX - minimumSize.width)
        }
        if handle.movesRight {
            maxX = max(min(rect.maxX + translation.x, bounds.maxX), minX + minimumSize.width)
        }
        if handle.movesBottom {
            minY = min(max(rect.minY + translation.y, bounds.minY), maxY - minimumSize.height)
        }
        if handle.movesTop {
            maxY = max(min(rect.maxY + translation.y, bounds.maxY), minY + minimumSize.height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func moved(
        _ rect: CGRect,
        translation: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return CGRect(
            x: min(max(rect.minX + translation.x, bounds.minX), bounds.maxX - width),
            y: min(max(rect.minY + translation.y, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    static func defaultRect(within bounds: CGRect) -> CGRect {
        let width = min(defaultSize.width, bounds.width)
        let height = min(defaultSize.height, bounds.height)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

private extension ResizeHandle {
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
}
