import Foundation

/// Converts between `Asset` and the flat JSON values exchanged with
/// `fpparquet` over stdio. Keys match the Go struct JSON tags exactly.
enum ParquetRowCodec {
    typealias Row = [String: JSONValue]

    static func row(from asset: Asset, albumSortIndex: Int32 = 0) -> Row {
        [
            "uuid": .string(asset.uuid.uuidString),
            "media_type": .string(asset.mediaType.rawValue),
            "captured_at": .int(Int64(asset.capturedAt.timeIntervalSince1970)),
            "captured_at_tz": opt(asset.capturedAtTZOffset.map { Int32($0) }),
            "added_at": .int(Int64(asset.addedAt.timeIntervalSince1970)),
            "duration_ms": opt(asset.durationMs.map { Int32($0) }),
            "width": .int(Int64(asset.width)),
            "height": .int(Int64(asset.height)),
            "file_size": .int(asset.fileSize),
            "sha256": .string(asset.sha256),
            "original_relpath": .string(asset.originalRelpath),
            "filename": .string(asset.filename),
            "uti": .string(asset.uti ?? ""),
            "title": opt(asset.title),
            "caption": opt(asset.caption),
            "is_favorite": .bool(asset.isFavorite),
            "is_hidden": .bool(asset.isHidden),
            "is_deleted": .bool(asset.isDeleted),
            "deleted_at": opt(asset.deletedAt.map { Int64($0.timeIntervalSince1970) }),
            "rating": .int(Int64(asset.rating)),
            "camera_make": opt(asset.cameraMake),
            "camera_model": opt(asset.cameraModel),
            "lens_model": opt(asset.lensModel),
            "iso": opt(asset.iso.map { Int32($0) }),
            "aperture": opt(asset.aperture),
            "shutter_speed": opt(asset.shutterSpeed),
            "focal_length": opt(asset.focalLength),
            "latitude": opt(asset.latitude),
            "longitude": opt(asset.longitude),
            "altitude": opt(asset.altitude),
            "hdr_type": .string(asset.hdrType.rawValue),
            "is_live_photo": .bool(asset.isLivePhoto),
            "live_photo_video_relpath": opt(asset.livePhotoVideoRelpath),
            "live_photo_still_time_ms": opt(asset.livePhotoStillTimeMs.map { Int32($0) }),
            "video_codec": opt(asset.videoCodec),
            "color_space": opt(asset.colorSpace),
            "has_audio": opt(asset.hasAudio),
            "frame_rate": opt(asset.frameRate),
            "edit_version": .int(Int64(asset.editVersion)),
            "album_sort_index": .int(Int64(albumSortIndex)),
        ]
    }

    static func asset(from row: Row) -> Asset? {
        guard let uuidString = row["uuid"]?.stringValue, let uuid = UUID(uuidString: uuidString)
        else { return nil }
        return Asset(
            uuid: uuid,
            mediaType: MediaType(rawValue: row["media_type"]?.stringValue ?? "photo") ?? .photo,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(row["captured_at"]?.intValue ?? 0)),
            capturedAtTZOffset: row["captured_at_tz"]?.intValue.map(Int.init),
            addedAt: Date(timeIntervalSince1970: TimeInterval(row["added_at"]?.intValue ?? 0)),
            durationMs: row["duration_ms"]?.intValue.map(Int.init),
            width: Int(row["width"]?.intValue ?? 0),
            height: Int(row["height"]?.intValue ?? 0),
            fileSize: row["file_size"]?.intValue ?? 0,
            sha256: row["sha256"]?.stringValue ?? "",
            originalRelpath: row["original_relpath"]?.stringValue ?? "",
            filename: row["filename"]?.stringValue ?? "",
            uti: row["uti"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            title: row["title"]?.stringValue,
            caption: row["caption"]?.stringValue,
            isFavorite: row["is_favorite"]?.boolValue ?? false,
            isHidden: row["is_hidden"]?.boolValue ?? false,
            isDeleted: row["is_deleted"]?.boolValue ?? false,
            deletedAt: row["deleted_at"]?.intValue.map { Date(timeIntervalSince1970: Double($0)) },
            rating: Int(row["rating"]?.intValue ?? 0),
            cameraMake: row["camera_make"]?.stringValue,
            cameraModel: row["camera_model"]?.stringValue,
            lensModel: row["lens_model"]?.stringValue,
            iso: row["iso"]?.intValue.map(Int.init),
            aperture: row["aperture"]?.doubleValue,
            shutterSpeed: row["shutter_speed"]?.doubleValue,
            focalLength: row["focal_length"]?.doubleValue,
            latitude: row["latitude"]?.doubleValue,
            longitude: row["longitude"]?.doubleValue,
            altitude: row["altitude"]?.doubleValue,
            hdrType: HDRType(rawValue: row["hdr_type"]?.stringValue ?? "sdr") ?? .sdr,
            isLivePhoto: row["is_live_photo"]?.boolValue ?? false,
            livePhotoVideoRelpath: row["live_photo_video_relpath"]?.stringValue,
            livePhotoStillTimeMs: row["live_photo_still_time_ms"]?.intValue.map(Int.init),
            videoCodec: row["video_codec"]?.stringValue,
            colorSpace: row["color_space"]?.stringValue,
            hasAudio: row["has_audio"]?.boolValue,
            frameRate: row["frame_rate"]?.doubleValue,
            editRecipeJSON: nil,  // recipes never leave the main DB
            editVersion: Int(row["edit_version"]?.intValue ?? 0)
        )
    }

    // MARK: - Index rows

    struct TimelineIndexEntry: Sendable, Equatable {
        var month: String
        var rowCount: Int
        var firstCaptured: Int64
        var lastCaptured: Int64
        var coverUUID: String
        var sha256: String
    }

    static func row(from entry: TimelineIndexEntry) -> Row {
        [
            "month": .string(entry.month),
            "row_count": .int(Int64(entry.rowCount)),
            "first_captured": .int(entry.firstCaptured),
            "last_captured": .int(entry.lastCaptured),
            "cover_uuid": .string(entry.coverUUID),
            "sha256": .string(entry.sha256),
        ]
    }

    static func indexEntry(from row: Row) -> TimelineIndexEntry? {
        guard let month = row["month"]?.stringValue else { return nil }
        return TimelineIndexEntry(
            month: month,
            rowCount: Int(row["row_count"]?.intValue ?? 0),
            firstCaptured: row["first_captured"]?.intValue ?? 0,
            lastCaptured: row["last_captured"]?.intValue ?? 0,
            coverUUID: row["cover_uuid"]?.stringValue ?? "",
            sha256: row["sha256"]?.stringValue ?? ""
        )
    }

    // MARK: - Helpers

    private static func opt(_ v: Any?) -> JSONValue {
        guard let v else { return .null }
        switch v {
        case let s as String: return .string(s)
        case let n as Int32: return .int(Int64(n))
        case let n as Int64: return .int(n)
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        default: return .null
        }
    }
}
