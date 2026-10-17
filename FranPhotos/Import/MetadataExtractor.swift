import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything the import pipeline needs to know about a photo's metadata.
struct PhotoMetadata: Sendable, Equatable {
    var capturedAt: Date?
    var tzOffsetSeconds: Int?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
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
    var title: String?
    var caption: String?
    var hdrType: HDRType = .sdr
    var isScreenshot: Bool = false
}

struct VideoMetadata: Sendable, Equatable {
    var capturedAt: Date?
    var durationMs: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var codec: String?
    var colorSpace: String?
    var hasAudio: Bool = false
    var frameRate: Double?
    var hdrType: HDRType = .sdr
    /// For the video component of a live photo: position of the still frame.
    var stillImageTimeMs: Int?
}

enum MetadataExtractor {
    // MARK: - Photos (ImageIO)

    static func photo(from url: URL) -> PhotoMetadata {
        var meta = PhotoMetadata()
        guard let props = ImageDecoder.properties(at: url) else {
            return meta
        }
        meta.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        meta.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]

        meta.cameraMake = tiff?[kCGImagePropertyTIFFMake] as? String
        meta.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        meta.lensModel = exif?[kCGImagePropertyExifLensModel] as? String

        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
            meta.iso = isoArray.first
        } else if let iso = exif?[kCGImagePropertyExifISOSpeed] as? Int {
            meta.iso = iso
        }
        meta.aperture = exif?[kCGImagePropertyExifFNumber] as? Double
        meta.shutterSpeed = exif?[kCGImagePropertyExifExposureTime] as? Double
        meta.focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double

        // Real-world files put OffsetTimeOriginal in ExifAux; some writers put it
        // directly in the Exif dict — accept both.
        let offsetString = (exifAux?["OffsetTimeOriginal" as CFString] as? String)
            ?? (exif?["OffsetTimeOriginal" as CFString] as? String)
        meta.tzOffsetSeconds = parseOffset(offsetString)
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        if let dateString {
            meta.capturedAt = parseExifDate(dateString, tzOffsetSeconds: meta.tzOffsetSeconds)
        }

        if let gps {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
                meta.latitude = ref.uppercased() == "S" ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
                meta.longitude = ref.uppercased() == "W" ? -lon : lon
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                let ref = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) ?? 0
                meta.altitude = ref == 1 ? -alt : alt
            }
        }

        meta.title = iptc?[kCGImagePropertyIPTCObjectName] as? String
        meta.caption = iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String

        // Screenshot heuristic (like Apple Photos' Screenshots media type):
        // PNG with no camera make/model. Refined later with actual display metadata.
        meta.isScreenshot = meta.cameraMake == nil && meta.cameraModel == nil
            && url.pathExtension.lowercased() == "png"

        meta.hdrType = ImageDecoder.inferredHDRType(at: url)
        return meta
    }

    // MARK: - Videos (AVFoundation)

    static func video(from url: URL) async -> VideoMetadata {
        var meta = VideoMetadata()
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            meta.durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        }
        if let creation = try? await asset.load(.creationDate)?.dateValue {
            meta.capturedAt = creation
        } else if let item = try? await asset.load(.commonMetadata).first(where: {
            $0.commonKey == .commonKeyCreationDate
        }), let string = try? await item.load(.stringValue) {
            meta.capturedAt = ISO8601DateFormatter().date(from: string)
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = size.applying(transform)
                meta.pixelWidth = Int(abs(transformed.width).rounded())
                meta.pixelHeight = Int(abs(transformed.height).rounded())
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                meta.frameRate = Double(rate)
            }
            if let descriptions = try? await track.load(.formatDescriptions) {
                for desc in descriptions {
                    let fd = desc as CMFormatDescription
                    let subType = CMFormatDescriptionGetMediaSubType(fd)
                    meta.codec = fourCC(subType)
                    if let ext = CMFormatDescriptionGetExtension(fd, extensionKey: kCVImageBufferColorPrimariesKey) {
                        meta.colorSpace = "\(ext)"
                    }
                    if let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCVImageBufferTransferFunctionKey) {
                        let tf = "\(transfer)"
                        if tf.contains("2100") || tf.localizedCaseInsensitiveContains("hlg") {
                            meta.hdrType = .hlg
                        } else if tf.localizedCaseInsensitiveContains("PQ")
                                    || tf.contains("2084")
                                    || tf.localizedCaseInsensitiveContains("perceptual") {
                            meta.hdrType = .pq
                        }
                    }
                    // Dolby Vision profiles are also HDR; treat as PQ-family for display flags.
                    if let sub = meta.codec?.lowercased(), sub.hasPrefix("dvh") || sub == "dvhe" {
                        meta.hdrType = .pq
                    }
                }
            }
        }
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
            meta.hasAudio = !audioTracks.isEmpty
        }

        // Live photo still time (QuickTime user data written by iOS Camera).
        if let items = try? await asset.load(.metadata) {
            for item in items {
                if let key = item.key as? String,
                   key == "com.apple.quicktime.still-image-time",
                   let value = try? await item.load(.numberValue) {
                    let seconds = value.doubleValue
                    if seconds >= 0 {
                        meta.stillImageTimeMs = Int(seconds * 1000)
                    } else {
                        meta.stillImageTimeMs = meta.durationMs / 2  // -1: midpoint
                    }
                }
            }
        }
        return meta
    }

    // MARK: - Parsing helpers

    /// "2024:06:15 14:30:00" interpreted in the timezone of `tzOffsetSeconds`
    /// (or the device timezone when absent).
    static func parseExifDate(_ string: String, tzOffsetSeconds: Int?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = tzOffsetSeconds {
            formatter.timeZone = TimeZone(secondsFromGMT: offset)
        } else {
            formatter.timeZone = .current
        }
        return formatter.date(from: string)
    }

    /// "+08:00" / "-05:30" → seconds. nil or malformed → nil.
    static func parseOffset(_ string: String?) -> Int? {
        guard let string, string.count == 6 else { return nil }
        let sign: Int = string.hasPrefix("-") ? -1 : 1
        guard string.hasPrefix("+") || string.hasPrefix("-") else { return nil }
        let hours = Int(string.dropFirst().prefix(2))
        let minutes = Int(string.suffix(2))
        guard let hours, let minutes else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(String(decoding: [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ], as: UTF8.self)).trimmingCharacters(in: .whitespaces)
    }
}

/// Classifies files into photos / videos / unsupported.
enum MediaClassifier {
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "raw", "pef", "srw",
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "3gp",
    ]

    static func mediaType(for url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) || videoExtensions.contains(ext) {
            return rawExtensions.contains(ext) ? .photo : .video
        }
        guard let ut = UTType(filenameExtension: ext) else { return nil }
        if ut.conforms(to: .movie) { return .video }
        if ut.conforms(to: .image) { return .photo }
        return nil
    }
}
