import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class TemplateControlImageLoaderTests: XCTestCase {
    func testAssetFileNamesMatchApprovedResources() {
        XCTAssertEqual(TemplateControlImageAsset.recordButton.rawValue, "RecordButton.png")
        XCTAssertEqual(TemplateControlImageAsset.stopButton.rawValue, "StopButton.png")
    }

    func testBundleLocatorFindsDecodablePNG() throws {
        let bundleURL = temporaryDirectory.appendingPathComponent("Controls.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try bundleInfoPlist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        try validPNGData.write(to: bundleURL.appendingPathComponent("RecordButton.png"))
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        let loader = TemplateControlImageLoader(
            locator: BundleResourceLocator(bundle: bundle),
            symbols: StubSymbolProvider(images: [:])
        )

        let loaded = loader.load(.recordButton)

        XCTAssertEqual(loaded.source, .bundlePNG)
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(loaded.image.isTemplate)
    }

    func testDirectoryLocatorFindsDecodablePNG() throws {
        let loader = TemplateControlImageLoader(
            locator: DirectoryResourceLocator(directoryURL: repositoryResourcesDirectory),
            symbols: StubSymbolProvider(images: [:])
        )

        let loaded = loader.load(.stopButton)

        XCTAssertEqual(loaded.source, .bundlePNG)
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(loaded.image.isTemplate)
    }

    func testMissingPNGUsesNamedSystemSymbol() {
        let symbol = NSImage(size: CGSize(width: 18, height: 18))
        let provider = StubSymbolProvider(images: ["record.circle": symbol])
        let loader = TemplateControlImageLoader(
            locator: DirectoryResourceLocator(directoryURL: temporaryDirectory),
            symbols: provider
        )

        let loaded = loader.load(.recordButton)

        XCTAssertEqual(loaded.source, .systemSymbol)
        XCTAssertEqual(provider.requestedNames, ["record.circle"])
        XCTAssertFalse(loaded.image === symbol)
        XCTAssertTrue(loaded.image.isTemplate)
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
    }

    func testCorruptPNGUsesStopSystemSymbol() throws {
        let directory = temporaryDirectory
        try Data("not a decodable image".utf8)
            .write(to: directory.appendingPathComponent("StopButton.png"))
        let symbol = NSImage(size: CGSize(width: 18, height: 18))
        let provider = StubSymbolProvider(images: ["stop.circle.fill": symbol])
        let loader = TemplateControlImageLoader(
            locator: DirectoryResourceLocator(directoryURL: directory),
            symbols: provider
        )

        let loaded = loader.load(.stopButton)

        XCTAssertEqual(loaded.source, .systemSymbol)
        XCTAssertEqual(provider.requestedNames, ["stop.circle.fill"])
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(loaded.image.isTemplate)
    }

    func testNilSymbolProviderUsesRecordVectorFallback() {
        let loader = TemplateControlImageLoader(
            locator: DirectoryResourceLocator(directoryURL: temporaryDirectory),
            symbols: StubSymbolProvider(images: [:])
        )

        let loaded = loader.load(.recordButton)

        XCTAssertEqual(loaded.source, .vectorFallback)
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(loaded.image.isTemplate)
        XCTAssertNotNil(loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testNilSymbolProviderUsesStopVectorFallback() {
        let loader = TemplateControlImageLoader(
            locator: DirectoryResourceLocator(directoryURL: temporaryDirectory),
            symbols: StubSymbolProvider(images: [:])
        )

        let loaded = loader.load(.stopButton)

        XCTAssertEqual(loaded.source, .vectorFallback)
        XCTAssertEqual(loaded.image.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(loaded.image.isTemplate)
        XCTAssertNotNil(loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private var temporaryDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFpro-TemplateControlImageLoaderTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var validPNGData: Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return representation.representation(using: .png, properties: [:])!
    }

    private var repositoryResourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private var bundleInfoPlist: Data {
        try! PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.gifpro.tests.controls-\(UUID().uuidString)",
                "CFBundleName": "Controls",
                "CFBundlePackageType": "BNDL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
    }
}

@MainActor
private final class StubSymbolProvider: TemplateControlSymbolProviding {
    private let images: [String: NSImage]
    private(set) var requestedNames: [String] = []

    init(images: [String: NSImage]) {
        self.images = images
    }

    func image(named name: String) -> NSImage? {
        requestedNames.append(name)
        return images[name]
    }
}
