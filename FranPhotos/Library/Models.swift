import Foundation

enum MediaType: String, Codable, Sendable, CaseIterable {
    case photo
    case video
}

enum HDRType: String, Codable, Sendable, CaseIterable {
    case sdr
    case gainmap   // still image with ISO 21496-1 / Apple HDR gain map
    case hlg
    case pq
}

enum AlbumType: String, Codable, Sendable {
    case manual
    case smart
    case builtin
}

/// A photo or video. `original_relpath` points inside the library bundle —
/// media always lives inside the library, never by external reference.
struct Asset: Sendable, Equatable, Identifiable {
    var uuid: UUID
    var mediaType: MediaType
    var capturedAt: Date
    var capturedAtTZOffset: Int?
    var addedAt: Date
    var durationMs: Int?
    var width: Int
    var height: Int
    var fileSize: Int64
    var sha256: String
    var originalRelpath: String
    var filename: String
    var uti: String?
    var title: String?
    var caption: String?
    var isFavorite: Bool
    var isHidden: Bool
    var isDeleted: Bool
    var deletedAt: Date?
    var rating: Int
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var aperture: Double?
    var shutterSpeed: Double?
    var focalLength: Double?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var hdrType: HDRType
    var isLivePhoto: Bool
    var livePhotoVideoRelpath: String?
    var livePhotoStillTimeMs: Int?
    var videoCodec: String?
    var colorSpace: String?
    var hasAudio: Bool?
    var frameRate: Double?
    var editRecipeJSON: String?
    var editVersion: Int

    var id: UUID { uuid }

    var isVideo: Bool { mediaType == .video }

    /// Grid-sort key: newest first.
    static func librarySortPredicate(_ a: Asset, _ b: Asset) -> Bool {
        a.capturedAt > b.capturedAt
    }
}

extension Asset {
    init(row: SQLRow) {
        uuid = UUID(uuidString: row.text("uuid") ?? "") ?? UUID()
        mediaType = MediaType(rawValue: row.text("media_type") ?? "photo") ?? .photo
        capturedAt = row.date("captured_at") ?? Date(timeIntervalSince1970: 0)
        capturedAtTZOffset = row.int("captured_at_tz_offset").map(Int.init)
        addedAt = row.date("added_at") ?? Date()
        durationMs = row.int("duration_ms").map(Int.init)
        width = Int(row.int("width") ?? 0)
        height = Int(row.int("height") ?? 0)
        fileSize = row.int("file_size") ?? 0
        sha256 = row.text("sha256") ?? ""
        originalRelpath = row.text("original_relpath") ?? ""
        filename = row.text("filename") ?? ""
        uti = row.text("uti")
        title = row.text("title")
        caption = row.text("caption")
        isFavorite = row.bool("is_favorite")
        isHidden = row.bool("is_hidden")
        isDeleted = row.bool("is_deleted")
        deletedAt = row.date("deleted_at")
        rating = Int(row.int("rating") ?? 0)
        cameraMake = row.text("camera_make")
        cameraModel = row.text("camera_model")
        lensModel = row.text("lens_model")
        iso = row.int("iso").map(Int.init)
        aperture = row.double("aperture")
        shutterSpeed = row.double("shutter_speed")
        focalLength = row.double("focal_length")
        latitude = row.double("latitude")
        longitude = row.double("longitude")
        altitude = row.double("altitude")
        hdrType = HDRType(rawValue: row.text("hdr_type") ?? "sdr") ?? .sdr
        isLivePhoto = row.bool("is_live_photo")
        livePhotoVideoRelpath = row.text("live_photo_video_relpath")
        livePhotoStillTimeMs = row.int("live_photo_still_time_ms").map(Int.init)
        videoCodec = row.text("video_codec")
        colorSpace = row.text("color_space")
        hasAudio = row.int("has_audio").map { $0 != 0 }
        frameRate = row.double("frame_rate")
        editRecipeJSON = row.text("edit_recipe_json")
        editVersion = Int(row.int("edit_version") ?? 0)
    }

    static let insertSQL = """
    INSERT INTO assets (
        uuid, media_type, captured_at, captured_at_tz_offset, added_at, duration_ms,
        width, height, file_size, sha256, original_relpath, filename, uti,
        title, caption, is_favorite, is_hidden, is_deleted, deleted_at, rating,
        camera_make, camera_model, lens_model, iso, aperture, shutter_speed, focal_length,
        latitude, longitude, altitude,
        hdr_type, is_live_photo, live_photo_video_relpath, live_photo_still_time_ms,
        video_codec, color_space, has_audio, frame_rate,
        edit_recipe_json, edit_version
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    var insertBindings: [SQLValue] {
        [
            .text(uuid.uuidString), .text(mediaType.rawValue), .date(capturedAt),
            capturedAtTZOffset.map { .integer(Int64($0)) } ?? .null,
            .date(addedAt), durationMs.map { .integer(Int64($0)) } ?? .null,
            .integer(Int64(width)), .integer(Int64(height)), .integer(fileSize),
            .text(sha256), .text(originalRelpath), .text(filename), .optionalText(uti),
            .optionalText(title), .optionalText(caption),
            .bool(isFavorite), .bool(isHidden), .bool(isDeleted),
            deletedAt.map { .date($0) } ?? .null, .integer(Int64(rating)),
            .optionalText(cameraMake), .optionalText(cameraModel), .optionalText(lensModel),
            iso.map { .integer(Int64($0)) } ?? .null,
            aperture.map { .double($0) } ?? .null,
            shutterSpeed.map { .double($0) } ?? .null,
            focalLength.map { .double($0) } ?? .null,
            latitude.map { .double($0) } ?? .null,
            longitude.map { .double($0) } ?? .null,
            altitude.map { .double($0) } ?? .null,
            .text(hdrType.rawValue), .bool(isLivePhoto),
            .optionalText(livePhotoVideoRelpath),
            livePhotoStillTimeMs.map { .integer(Int64($0)) } ?? .null,
            .optionalText(videoCodec), .optionalText(colorSpace),
            hasAudio.map { .bool($0) } ?? .null,
            frameRate.map { .double($0) } ?? .null,
            .optionalText(editRecipeJSON), .integer(Int64(editVersion)),
        ]
    }
}

struct Album: Sendable, Equatable, Identifiable {
    var uuid: UUID
    var name: String
    var type: AlbumType
    var smartRulesJSON: String?
    var sortIndex: Int
    var coverAssetUUID: UUID?

    var id: UUID { uuid }
}

struct Keyword: Sendable, Equatable, Identifiable {
    var uuid: UUID
    var name: String
    var id: UUID { uuid }
}

struct Person: Sendable, Equatable, Identifiable {
    var uuid: UUID
    var name: String?
    var faceCount: Int
    var coverFaceUUID: UUID?
    var id: UUID { uuid }
}

struct DetectedFace: Sendable, Equatable, Identifiable {
    var uuid: UUID
    var assetUUID: UUID
    var personUUID: UUID?
    var centerX: Double
    var centerY: Double
    var size: Double
    var thumbnailRelpath: String?
    var id: UUID { uuid }
}

struct Memory: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case yearHighlight = "year_highlight"
        case trip
        case onThisDay = "on_this_day"
    }
    var uuid: UUID
    var kind: Kind
    var title: String
    var keyDate: Date?
    var assetUUIDs: [UUID]
    var id: UUID { uuid }
}
