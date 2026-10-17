import Foundation

/// People data: face scan orchestration, person CRUD, naming.
@MainActor
@Observable
final class PeopleStore {
    private(set) var persons: [Person] = []
    private(set) var isScanning = false
    private(set) var scanProgress: String = ""

    private let db: DatabaseActor
    private let paths: LibraryPaths

    init(db: DatabaseActor, paths: LibraryPaths) {
        self.db = db
        self.paths = paths
    }

    // MARK: - Scanning

    /// Detects faces in every not-yet-scanned photo. Safe to re-run.
    func scanLibrary() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let rows = (try? await db.query("""
            SELECT uuid, original_relpath, media_type FROM assets
            WHERE faces_scanned = 0 AND is_deleted = 0 AND media_type = 'photo'
            ORDER BY captured_at DESC
            """)) ?? []
        var done = 0
        for row in rows {
            guard let uuidString = row.text("uuid"),
                  let relpath = row.text("original_relpath") else { continue }
            done += 1
            scanProgress = "\(done)/\(rows.count)"
            let url = paths.url(forRelativePath: relpath)
            let libraryPaths = paths
            // Detect + thumbnail off the DB transaction.
            let detected = await Task.detached(priority: .utility) {
                FaceScanner.detect(in: url).map { face -> (UUID, FaceScanner.DetectedRect, String?) in
                    let faceUUID = UUID()
                    var thumbRel: String?
                    if let thumb = FaceScanner.faceThumbnail(
                        from: url, centerX: face.centerX, centerY: face.centerY, size: face.size) {
                        thumbRel = "faces/\(faceUUID.uuidString).jpg"
                        ImageDecoder.writeJPEG(thumb, to: libraryPaths.url(forRelativePath: thumbRel!),
                                               quality: 0.85)
                    }
                    return (faceUUID, face, thumbRel)
                }
            }.value
            do {
                try await db.transaction { db in
                    for (faceUUID, face, thumbRel) in detected {
                        try db.execute("""
                            INSERT INTO faces(uuid, asset_uuid, person_uuid, center_x, center_y, size, thumbnail_relpath)
                            VALUES (?, ?, NULL, ?, ?, ?, ?)
                            """, [.text(faceUUID.uuidString), .text(uuidString),
                                  .double(face.centerX), .double(face.centerY),
                                  .double(face.size), .optionalText(thumbRel)])
                    }
                    try db.execute(
                        "UPDATE assets SET faces_scanned = 1 WHERE uuid = ?",
                        [.text(uuidString)])
                }
            } catch {
                // Keep scanning other assets.
            }
        }
        await reload()
    }

    // MARK: - People CRUD

    func reload() async {
        persons = ((try? await db.query("""
            SELECT p.*, (SELECT COUNT(*) FROM faces f WHERE f.person_uuid = p.uuid) AS fc
            FROM persons p ORDER BY fc DESC, name
            """)) ?? []).map { row in
            Person(
                uuid: UUID(uuidString: row.text("uuid") ?? "") ?? UUID(),
                name: row.text("name"),
                faceCount: Int(row.int("fc") ?? 0),
                coverFaceUUID: row.text("cover_face_uuid").flatMap(UUID.init(uuidString:))
            )
        }
    }

    /// Faces not yet assigned to a person.
    func unnamedFaces() async throws -> [DetectedFace] {
        try await db.query(
            "SELECT * FROM faces WHERE person_uuid IS NULL ORDER BY uuid")
            .map(Self.face(from:))
    }

    func faces(of personUUID: UUID) async throws -> [DetectedFace] {
        try await db.query(
            "SELECT * FROM faces WHERE person_uuid = ? ORDER BY uuid",
            [.text(personUUID.uuidString)]).map(Self.face(from:))
    }

    func faces(in assetUUID: UUID) async throws -> [DetectedFace] {
        try await db.query(
            "SELECT * FROM faces WHERE asset_uuid = ?", [.text(assetUUID.uuidString)])
            .map(Self.face(from:))
    }

    /// Assigns a face to a person with `name`, creating the person if needed.
    @discardableResult
    func name(faceUUID: UUID, name: String) async throws -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let existing = try await db.query(
            "SELECT uuid FROM persons WHERE name = ?", [.text(trimmed)]).first?.text("uuid")
        let personUUID: String
        if let existing {
            personUUID = existing
        } else {
            personUUID = UUID().uuidString
            try await db.execute("INSERT INTO persons(uuid, name) VALUES (?, ?)",
                                 [.text(personUUID), .text(trimmed)])
        }
        try await db.execute("UPDATE faces SET person_uuid = ? WHERE uuid = ?",
                             [.text(personUUID), .text(faceUUID.uuidString)])
        try await db.execute(
            "UPDATE persons SET cover_face_uuid = COALESCE(cover_face_uuid, ?) WHERE uuid = ?",
            [.text(faceUUID.uuidString), .text(personUUID)])
        await reload()
        return persons.first { $0.uuid.uuidString == personUUID }
    }

    /// Removes the person assignment from a face (back to unnamed).
    func unassign(faceUUID: UUID) async throws {
        try await db.execute("UPDATE faces SET person_uuid = NULL WHERE uuid = ?",
                             [.text(faceUUID.uuidString)])
        await reload()
    }

    /// Merges `source` person into `target` (moves all faces, deletes source).
    func mergePerson(source: UUID, into target: UUID) async throws {
        try await db.transaction { db in
            try db.execute("UPDATE faces SET person_uuid = ? WHERE person_uuid = ?",
                           [.text(target.uuidString), .text(source.uuidString)])
            try db.execute("DELETE FROM persons WHERE uuid = ?", [.text(source.uuidString)])
        }
        await reload()
    }

    func renamePerson(_ uuid: UUID, to name: String) async throws {
        try await db.execute("UPDATE persons SET name = ? WHERE uuid = ?",
                             [.text(name), .text(uuid.uuidString)])
        await reload()
    }

    func coverThumbnailRelpath(for personUUID: UUID) async throws -> String? {
        try await db.query("""
            SELECT thumbnail_relpath FROM faces
            WHERE uuid = (SELECT cover_face_uuid FROM persons WHERE uuid = ?)
            """, [.text(personUUID.uuidString)]).first?.text("thumbnail_relpath")
    }

    /// All assets showing a person.
    func assets(of personUUID: UUID) async throws -> [Asset] {
        try await db.query("""
            SELECT a.* FROM assets a
            JOIN faces f ON f.asset_uuid = a.uuid
            WHERE f.person_uuid = ? AND a.is_deleted = 0
            GROUP BY a.uuid ORDER BY a.captured_at DESC
            """, [.text(personUUID.uuidString)]).map(Asset.init)
    }

    static func face(from row: SQLRow) -> DetectedFace {
        DetectedFace(
            uuid: UUID(uuidString: row.text("uuid") ?? "") ?? UUID(),
            assetUUID: UUID(uuidString: row.text("asset_uuid") ?? "") ?? UUID(),
            personUUID: row.text("person_uuid").flatMap(UUID.init(uuidString:)),
            centerX: row.double("center_x") ?? 0,
            centerY: row.double("center_y") ?? 0,
            size: row.double("size") ?? 0,
            thumbnailRelpath: row.text("thumbnail_relpath")
        )
    }
}
