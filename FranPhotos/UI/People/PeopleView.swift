import SwiftUI

/// People overview: named persons grid + unnamed faces strip + scan control.
struct PeopleView: View {
    @Environment(LibraryManager.self) private var manager
    @State private var store: PeopleStore?
    @State private var unnamedFaces: [DetectedFace] = []
    @State private var selectedPerson: Person?
    @State private var namingFace: DetectedFace?
    @State private var newName = ""

    var body: some View {
        Group {
            if let store {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !store.persons.isEmpty {
                            personGrid(store)
                        }
                        if !unnamedFaces.isEmpty {
                            unnamedSection(store)
                        }
                        if store.persons.isEmpty && unnamedFaces.isEmpty {
                            emptyState(store)
                        }
                    }
                    .padding(20)
                }
                .sheet(item: $selectedPerson) { person in
                    PersonDetailView(store: store, person: person)
                }
                .sheet(item: $namingFace) { face in
                    namingSheet(store: store, face: face)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard let db = manager.db, let paths = manager.library?.paths else { return }
            let store = PeopleStore(db: db, paths: paths)
            self.store = store
            await store.reload()
            unnamedFaces = (try? await store.unnamedFaces()) ?? []
        }
    }

    private func personGrid(_ store: PeopleStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 14) {
                ForEach(store.persons) { person in
                    VStack(spacing: 6) {
                        PersonCoverThumbnail(store: store, person: person,
                                             paths: manager.library?.paths)
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                        Text(person.name ?? String(localized: "Unnamed"))
                            .font(.caption)
                        Text(String(localized: "\(person.faceCount) photos"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture { selectedPerson = person }
                }
            }
        }
    }

    private func unnamedSection(_ store: PeopleStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Unnamed Faces").font(.title3.weight(.semibold))
                Spacer()
                scanButton(store)
            }
            Text("Tap a face to name it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(unnamedFaces) { face in
                    FaceThumbnail(thumbnailRelpath: face.thumbnailRelpath,
                                  paths: manager.library?.paths)
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .onTapGesture {
                            namingFace = face
                            newName = ""
                        }
                }
            }
        }
    }

    private func emptyState(_ store: PeopleStore) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No faces found yet")
                .font(.headline)
            Text("Scan your library to detect faces in photos.")
                .foregroundStyle(.secondary)
            scanButton(store)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func scanButton(_ store: PeopleStore) -> some View {
        Button {
            Task {
                await store.scanLibrary()
                unnamedFaces = (try? await store.unnamedFaces()) ?? []
            }
        } label: {
            if store.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.scanProgress)
                }
            } else {
                Label(String(localized: "Scan for Faces"), systemImage: "person.badge.plus")
            }
        }
        .disabled(store.isScanning)
    }

    private func namingSheet(store: PeopleStore, face: DetectedFace) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                FaceThumbnail(thumbnailRelpath: face.thumbnailRelpath,
                              paths: manager.library?.paths)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                Text("Who is this?").font(.headline)
            }
            TextField(String(localized: "Name"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { assignName(store: store, face: face) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { namingFace = nil }
                Button(String(localized: "Name")) { assignName(store: store, face: face) }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func assignName(store: PeopleStore, face: DetectedFace) {
        Task {
            _ = try? await store.name(faceUUID: face.uuid, name: newName)
            namingFace = nil
            unnamedFaces = (try? await store.unnamedFaces()) ?? []
        }
    }
}

/// Circular face thumbnail from a `faces/` relative path.
struct FaceThumbnail: View {
    let thumbnailRelpath: String?
    let paths: LibraryPaths?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill").foregroundStyle(.tertiary)
            }
        }
        .task(id: thumbnailRelpath) {
            guard let thumbnailRelpath, let paths else { return }
            image = NSImage(contentsOf: paths.url(forRelativePath: thumbnailRelpath))
        }
    }
}

/// Resolves a person's cover face and renders it.
private struct PersonCoverThumbnail: View {
    let store: PeopleStore
    let person: Person
    let paths: LibraryPaths?
    @State private var relpath: String?

    var body: some View {
        FaceThumbnail(thumbnailRelpath: relpath, paths: paths)
            .task(id: person.id) {
                relpath = try? await store.coverThumbnailRelpath(for: person.uuid)
            }
    }
}

/// Person detail: rename, assets grid, faces strip with unassign.
struct PersonDetailView: View {
    let store: PeopleStore
    let person: Person
    @Environment(LibraryManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var faces: [DetectedFace] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PersonCoverThumbnail(store: store, person: person,
                                     paths: manager.library?.paths)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                VStack(alignment: .leading) {
                    TextField(String(localized: "Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { try? await store.renamePerson(person.uuid, to: name) }
                        }
                    Text(String(localized: "\(person.faceCount) photos"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !faces.isEmpty {
                Text("Faces").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(faces) { face in
                            FaceThumbnail(thumbnailRelpath: face.thumbnailRelpath,
                                          paths: manager.library?.paths)
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .contextMenu {
                                    Button(String(localized: "Remove from Person")) {
                                        Task {
                                            try? await store.unassign(faceUUID: face.uuid)
                                            faces = (try? await store.faces(of: person.uuid)) ?? []
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            if let cache = manager.derivativeCache, let db = manager.db,
               let paths = manager.library?.paths {
                FilteredAssetGridView(cache: cache, db: db, paths: paths,
                                      filter: .init(kind: .person(person.uuid)))
                .frame(minHeight: 300)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .task {
            name = person.name ?? ""
            faces = (try? await store.faces(of: person.uuid)) ?? []
        }
    }
}
