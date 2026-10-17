import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FranPhotos

struct ExportTests {
    // MARK: - XMP

    @Test func xmpRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let meta = XMP.Metadata(
            title: "Sunset <&>", caption: "Golden hour", keywords: ["beach", "sunset"],
            rating: 4, dateCreated: Date(timeIntervalSince1970: 1_741_919_400),
            latitude: 31.2304, longitude: -121.4737)
        let file = dir.appending(path: "IMG_0001.xmp")
        try XMP.write(meta, to: file)

        let parsed = try #require(XMP.parse(url: file))
        #expect(parsed.title == "Sunset <&>")
        #expect(parsed.caption == "Golden hour")
        #expect(parsed.keywords == ["beach", "sunset"])
        #expect(parsed.rating == 4)
        #expect(abs((parsed.dateCreated?.timeIntervalSince1970 ?? 0) - 1_741_919_400) < 2)
        #expect(abs(parsed.latitude! - 31.2304) < 0.001)
        #expect(abs(parsed.longitude! - (-121.4737)) < 0.001)
    }

    @Test func xmpCoordinates() {
        #expect(XMP.xmpCoordinate(31.2304, positive: "N", negative: "S") == "31,13.8240N")
        #expect(abs(XMP.parseCoordinate("31,13.8240N")! - 31.2304) < 0.0001)
        #expect(XMP.parseCoordinate("-45.5") == -45.5)
        #expect(abs(XMP.parseCoordinate("121,28.4220W")! + 121.4737) < 0.0001)
    }

    // MARK: - Photo format export

    private func makeLibrary() async throws -> (LibraryStore, DatabaseActor, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore.create(at: dir.appending(path: "Lib.franphotoslibrary"))
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        return (store, db, dir)
    }

    private func importOne(_ store: LibraryStore, _ db: DatabaseActor, dir: URL) async throws -> UUID {
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = try TestFixtures.makeJPEG(in: src, name: "exp.jpg")
        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([src]) { _ in }
        return try #require(outcome.importedUUIDs.first)
    }

    @Test func exportsPhotoInAllFormats() async throws {
        let (store, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let uuid = try await importOne(store, db, dir: dir)
        let engine = ExportEngine(db: db, paths: store.paths)

        for format in [ExportOptions.PhotoFormat.jpeg, .png, .heic, .tiff, .original] {
            let dest = dir.appending(path: "out-\(format.rawValue)")
            var options = ExportOptions()
            options.photoFormat = format
            options.writeXMPSidecars = true
            let result = await engine.export(uuids: [uuid], destination: dest,
                                             options: options) { _, _ in }
            #expect(result.exported == 1, "format \(format)")
            #expect(result.failed == 0)
            let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            let media = files.filter { $0 != ".DS_Store" && !$0.hasSuffix(".xmp") }
            #expect(media.count == 1)
            // XMP sidecar written.
            #expect(files.contains { $0.hasSuffix(".xmp") })
            // Valid image of the requested type (except original = copy of JPEG).
            let file = dest.appending(path: media[0])
            if format != .original,
               let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let type = CGImageSourceGetType(source) as String? {
                let expected: UTType = switch format {
                case .jpeg: .jpeg
                case .png: .png
                case .heic: .heic
                case .tiff: .tiff
                case .original: .jpeg
                }
                #expect(type == expected.identifier, "\(type) != \(expected.identifier)")
            }
        }
    }

    @Test func transcodesVideoToHEVC() async throws {
        let (store, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = try await TestFixtures.makeVideo(in: src, name: "clip.mov", durationSeconds: 1.0)
        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([src]) { _ in }
        let uuid = try #require(outcome.importedUUIDs.first)

        let export = ExportEngine(db: db, paths: store.paths)
        var options = ExportOptions()
        options.videoMode = .transcode
        options.videoCodec = .hevc
        options.videoResolution = .hd720
        options.videoContainer = .mp4
        let dest = dir.appending(path: "out-video")
        let result = await export.export(uuids: [uuid], destination: dest,
                                         options: options) { _, _ in }
        #expect(result.failed == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            .filter { $0.hasSuffix(".mp4") }
        #expect(files.count == 1)

        // Verify the transcode: HEVC codec, 720p-class height, duration preserved.
        let asset = AVURLAsset(url: dest.appending(path: files[0]))
        let track = try await #require(asset.loadTracks(withMediaType: .video).first)
        let descriptions = try await track.load(.formatDescriptions)
        let subType = CMFormatDescriptionGetMediaSubType(descriptions[0] as! CMFormatDescription)
        #expect(MetadataExtractor.fourCC(subType) == "hvc1")
        let size = try await track.load(.naturalSize)
        #expect(Int(size.height) <= 720)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.5)
    }

    @Test func importReadsXMPSidecar() async throws {
        let (store, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let photo = try TestFixtures.makeJPEG(in: src, name: "withxmp.jpg")
        try XMP.write(.init(title: "Sidecar Title", keywords: ["mountain", "lake"], rating: 5),
                      to: src.appending(path: "withxmp.xmp"))

        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([photo]) { _ in }
        let uuid = try #require(outcome.importedUUIDs.first)
        let row = try await db.query("SELECT * FROM assets WHERE uuid = ?",
                                     [.text(uuid.uuidString)]).first
        let asset = try #require(row.map(Asset.init))
        #expect(asset.title == "Sidecar Title")
        #expect(asset.rating == 5)
        let keywords = try await AssetActions(db: db).keywords(for: uuid)
        #expect(Set(keywords) == ["mountain", "lake"])
    }
}
