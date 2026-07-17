import AppKit
import ImageIO
import OSLog

enum TemplateControlImageAsset: String, CaseIterable {
    case recordButton = "RecordButton.png"
    case stopButton = "StopButton.png"

    fileprivate var resourceName: String {
        URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
    }

    fileprivate var resourceExtension: String {
        URL(fileURLWithPath: rawValue).pathExtension
    }

    fileprivate var systemSymbolName: String {
        switch self {
        case .recordButton:
            "record.circle"
        case .stopButton:
            "stop.circle.fill"
        }
    }
}

struct LoadedTemplateImage {
    enum Source: Equatable {
        case bundlePNG
        case systemSymbol
        case vectorFallback
    }

    let image: NSImage
    let source: Source
}

@MainActor
protocol TemplateControlImageLoading {
    func load(_ asset: TemplateControlImageAsset) -> LoadedTemplateImage
}

protocol TemplateControlImageResourceLocating {
    func url(for asset: TemplateControlImageAsset) -> URL?
}

@MainActor
protocol TemplateControlSymbolProviding {
    func image(named name: String) -> NSImage?
}

struct BundleResourceLocator: TemplateControlImageResourceLocating {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func url(for asset: TemplateControlImageAsset) -> URL? {
        bundle.url(
            forResource: asset.resourceName,
            withExtension: asset.resourceExtension
        )
    }
}

struct DirectoryResourceLocator: TemplateControlImageResourceLocating {
    let directoryURL: URL

    func url(for asset: TemplateControlImageAsset) -> URL? {
        directoryURL.appendingPathComponent(asset.rawValue, isDirectory: false)
    }
}

struct AppKitTemplateControlSymbolProvider: TemplateControlSymbolProviding {
    @MainActor
    func image(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

@MainActor
final class TemplateControlImageLoader: TemplateControlImageLoading {
    private let locator: any TemplateControlImageResourceLocating
    private let symbols: any TemplateControlSymbolProviding

    init(
        locator: any TemplateControlImageResourceLocating = BundleResourceLocator(),
        symbols: (any TemplateControlSymbolProviding)? = nil
    ) {
        self.locator = locator
        self.symbols = symbols ?? AppKitTemplateControlSymbolProvider()
    }

    func load(_ asset: TemplateControlImageAsset) -> LoadedTemplateImage {
        if let resourceURL = locator.url(for: asset) {
            if let image = decodedPNG(at: resourceURL) {
                return LoadedTemplateImage(
                    image: preparedTemplateCopy(of: image),
                    source: .bundlePNG
                )
            }
            Logger.templateControlImages.error(
                "Could not decode template control image: \(asset.rawValue, privacy: .public)"
            )
        } else {
            Logger.templateControlImages.error(
                "Template control image is missing: \(asset.rawValue, privacy: .public)"
            )
        }

        if let symbol = symbols.image(named: asset.systemSymbolName) {
            return LoadedTemplateImage(
                image: preparedTemplateCopy(of: symbol),
                source: .systemSymbol
            )
        }

        Logger.templateControlImages.error(
            "System symbol is unavailable; drawing vector fallback: \(asset.systemSymbolName, privacy: .public)"
        )
        return LoadedTemplateImage(
            image: preparedTemplateCopy(of: vectorFallback(for: asset)),
            source: .vectorFallback
        )
    }

    private func decodedPNG(at url: URL) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetType(source) as String? == "public.png",
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func preparedTemplateCopy(of image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? NSImage(size: image.size)
        copy.size = CGSize(width: 24, height: 24)
        copy.isTemplate = true
        return copy
    }

    private func vectorFallback(for asset: TemplateControlImageAsset) -> NSImage {
        NSImage(size: CGSize(width: 24, height: 24), flipped: false) { bounds in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 2
            ring.stroke()

            switch asset {
            case .recordButton:
                NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8)).fill()
            case .stopButton:
                NSBezierPath(rect: bounds.insetBy(dx: 8, dy: 8)).fill()
            }
            return true
        }
    }
}

private extension Logger {
    static let templateControlImages = Logger(
        subsystem: "com.gifpro.app",
        category: "TemplateControlImages"
    )
}
