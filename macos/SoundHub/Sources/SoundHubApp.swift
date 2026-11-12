import SwiftUI
import AVFoundation
import AppKit
import Darwin
import UniformTypeIdentifiers

@main
struct SoundHubApp: App {
    @NSApplicationDelegateAdaptor(SoundHubSingleInstanceDelegate.self) private var singleInstanceDelegate
    @StateObject private var viewModel = SoundHubViewModel()

    var body: some Scene {
        WindowGroup {
            SoundHubWindow()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
    }
}

/// Keeps a single SoundHub process active for the current macOS user.
private final class SoundHubSingleInstanceDelegate: NSObject, NSApplicationDelegate {
    private var lockDescriptor: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let dockIcon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = dockIcon
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "org.soundhub.mac"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        if let existing = otherInstances.first {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        guard let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSApp.terminate(nil)
            return
        }
        let appSupportURL = supportURL.appendingPathComponent("SoundHub", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        } catch {
            NSApp.terminate(nil)
            return
        }

        let lockURL = appSupportURL.appendingPathComponent("instance.lock")
        lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else {
            NSApp.terminate(nil)
            return
        }

        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != currentPID }
            existing?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }
}

private enum SoundHubPalette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.075)
    static let sidebar = Color(red: 0.075, green: 0.09, blue: 0.10)
    static let panel = Color(red: 0.105, green: 0.125, blue: 0.13)
    static let raised = Color(red: 0.14, green: 0.16, blue: 0.16)
    static let accent = Color(red: 0.49, green: 0.88, blue: 0.49)
    static let muted = Color.white.opacity(0.58)
}

@MainActor
private final class SoundHubViewModel: ObservableObject {
    @Published private(set) var songs: [Song]
    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var votes: [String: Int]
    @Published private(set) var createdSongIDs: Set<String>
    @Published private(set) var forkedSongIDs: Set<String>
    @Published private(set) var isSignedIn = false
    @Published private(set) var displayName: String
    @Published private(set) var profileImageURL: String?
    @Published private(set) var profileMessage: String?
    @Published var apiBaseURLText = UserDefaults.standard.string(forKey: "SoundHubAPIBaseURL") ?? ""
    @Published private(set) var serviceMessage = "Not connected to a SoundHub server."
    @Published private(set) var isLoadingService = false
    @Published private(set) var isLoadingMoreServiceSongs = false
    @Published private(set) var loadedServicePages = 0
    @Published private(set) var serviceSongCount = 0
    private var serviceSort: SoundHubCatalogSort = .mostBranched

    private let persistence = SoundHubLocalPersistence()

    var hasMoreServiceSongs: Bool {
        serviceSongCount > songs.filter { !createdSongIDs.contains($0.id) && !$0.isSample }.count
    }

    var loadedServiceSongCount: Int {
        songs.filter { !createdSongIDs.contains($0.id) && !$0.isSample }.count
    }

    init() {
        if let state = persistence.load() {
            songs = state.songs
            favoriteIDs = state.favoriteIDs
            votes = state.votes
            createdSongIDs = state.createdSongIDs
            forkedSongIDs = state.forkedSongIDs
            displayName = state.displayName
            profileImageURL = state.profileImageURL
        } else {
            songs = SampleCatalog.songs
            favoriteIDs = ["root-02"]
            votes = [:]
            createdSongIDs = []
            forkedSongIDs = []
            displayName = "Guest"
            profileImageURL = nil
        }
    }

    func signIn(as name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        displayName = cleaned
        isSignedIn = true
        persist()
    }

    func signOut() {
        displayName = "Guest"
        isSignedIn = false
    }

    func toggleFavorite(_ songID: String) {
        if favoriteIDs.contains(songID) { favoriteIDs.remove(songID) }
        else { favoriteIDs.insert(songID) }
        persist()
    }

    func vote(_ value: Int, for songID: String) {
        let oldValue = votes[songID] ?? 0
        // The legacy service keeps the current vote until the user switches direction.
        let nextValue = value
        votes[songID] = nextValue
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        var song = songs[index]
        song.likes = max(0, song.likes + nextValue - oldValue)
        songs[index] = song
        persist()
    }

    func addSong(title: String, creator: String? = nil, genre: String, description: String, mediaURL: URL?, sourceURL: String? = nil, parent: Song?) {
        let id = UUID().uuidString
        let cleanCreator = creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSong = Song(
            id: id,
            title: title,
            creator: cleanCreator.flatMap { $0.isEmpty ? nil : $0 } ?? displayName,
            genre: genre.isEmpty ? "Uncategorized" : genre,
            branches: 0,
            likes: 0,
            color: SampleCatalog.apiColors[songs.count % SampleCatalog.apiColors.count],
            parentID: parent?.id,
            rootID: parent?.rootID ?? id,
            description: description,
            mediaURL: mediaURL,
            isSample: false,
            sourceURL: sourceURL
        )
        songs.append(newSong)
        createdSongIDs.insert(id)
        if let parentIndex = songs.firstIndex(where: { $0.id == parent?.id }), parent != nil {
            songs[parentIndex].branches += 1
            forkedSongIDs.insert(id)
        }
        profileMessage = "Saved on this Mac. It has not been sent to the SoundHub server."
        persist()
    }

    func saveProfile(name: String, imageURL: String? = nil) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let cleanedImageURL = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedImageURL, !cleanedImageURL.isEmpty {
            guard let url = URL(string: cleanedImageURL),
                  url.scheme?.lowercased() == "https", url.host != nil else {
                profileMessage = "Profile image must use a valid HTTPS URL."
                return
            }
            profileImageURL = cleanedImageURL
        } else {
            profileImageURL = nil
        }
        displayName = cleaned
        for index in songs.indices where createdSongIDs.contains(songs[index].id) {
            songs[index].creator = cleaned
        }
        profileMessage = "Profile saved on this Mac."
        persist()
    }

    func connectToService() {
        let value = apiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            serviceMessage = "Enter a valid HTTP or HTTPS SoundHub service address."
            return
        }

        UserDefaults.standard.set(url.absoluteString, forKey: "SoundHubAPIBaseURL")
        loadRemoteCatalog(sort: serviceSort, from: url)
    }

    func updateRemoteSort(_ sort: DiscoverySort) {
        let apiSort: SoundHubCatalogSort
        switch sort {
        case .newest: apiSort = .newest
        case .mostBranches: apiSort = .mostBranched
        case .mostLiked: apiSort = .mostLiked
        case .title: apiSort = .title
        }
        serviceSort = apiSort
        guard let value = UserDefaults.standard.string(forKey: "SoundHubAPIBaseURL"),
              let url = URL(string: value) else { return }
        loadRemoteCatalog(sort: apiSort, from: url)
    }

    func loadMoreRemoteSongs() {
        guard !isLoadingService, !isLoadingMoreServiceSongs,
              let value = UserDefaults.standard.string(forKey: "SoundHubAPIBaseURL"),
              let url = URL(string: value),
              loadedServicePages < (serviceSongCount + SoundHubSongPage.pageSize - 1) / SoundHubSongPage.pageSize else { return }
        isLoadingMoreServiceSongs = true
        Task {
            do {
                let nextPage = loadedServicePages + 1
                let response = try await SoundHubAPI(baseURL: url).sortedSongs(sort: serviceSort, page: nextPage)
                let converted = convertRemoteSongs(response.songs)
                let knownIDs = Set(songs.map(\.id))
                songs.append(contentsOf: converted.filter { !knownIDs.contains($0.id) })
                loadedServicePages = nextPage
                serviceSongCount = response.number
                serviceMessage = "Loaded \(min(songs.count, serviceSongCount)) of \(serviceSongCount) server songs."
                persist()
            } catch {
                serviceMessage = "Couldn't load more songs: \(error.localizedDescription)"
            }
            isLoadingMoreServiceSongs = false
        }
    }

    private func loadRemoteCatalog(sort: SoundHubCatalogSort, from url: URL) {
        serviceSort = sort
        loadedServicePages = 0
        isLoadingService = true
        serviceMessage = "Connecting and loading the catalog…"
        Task {
            do {
                let response = try await SoundHubAPI(baseURL: url).sortedSongs(sort: sort, page: 1)
                let localSongs = songs.filter { createdSongIDs.contains($0.id) }
                let converted = convertRemoteSongs(response.songs)
                let remoteIDs = Set(converted.map(\.id))
                songs = converted + localSongs.filter { !remoteIDs.contains($0.id) }
                loadedServicePages = 1
                serviceSongCount = response.number
                persist()
                serviceMessage = "Connected. Loaded \(converted.count) of \(serviceSongCount) server songs. Member actions stay on this Mac."
            } catch {
                serviceMessage = "Couldn't load the SoundHub catalog: \(error.localizedDescription)"
            }
            isLoadingService = false
        }
    }

    private func convertRemoteSongs(_ remoteSongs: [SoundHubSong]) -> [Song] {
        remoteSongs.enumerated().map { index, remote in
            Song(id: remote.uuid, title: remote.title,
                 creator: remote.authorName ?? "SoundHub member",
                 genre: remote.genre ?? "Uncategorized", branches: remote.forks,
                 likes: remote.like, color: SampleCatalog.apiColors[index % SampleCatalog.apiColors.count],
                 parentID: remote.parentId, rootID: remote.rootId,
                 description: remote.description ?? "",
                 mediaURL: remote.url.flatMap { URL(string: $0) }, isSample: false)
        }
    }

    func loadRemoteTree(rootID: String) {
        guard let value = UserDefaults.standard.string(forKey: "SoundHubAPIBaseURL"),
              let url = URL(string: value) else { return }
        Task {
            do {
                let remoteTree = try await SoundHubAPI(baseURL: url).tree(rootID: rootID)
                let localTreeSongs = songs.filter { createdSongIDs.contains($0.id) && $0.rootID == rootID }
                let converted = convertRemoteSongs(remoteTree)
                songs.removeAll { $0.rootID == rootID }
                songs.append(contentsOf: converted)
                let remoteIDs = Set(converted.map(\.id))
                songs.append(contentsOf: localTreeSongs.filter { !remoteIDs.contains($0.id) })
                persist()
            } catch {
                serviceMessage = "Couldn't load this song tree: \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        do {
            try persistence.save(LocalSoundHubState(
                songs: songs,
                favoriteIDs: favoriteIDs,
                votes: votes,
                createdSongIDs: createdSongIDs,
                forkedSongIDs: forkedSongIDs,
                displayName: displayName,
                profileImageURL: profileImageURL
            ))
        } catch {
            profileMessage = "Couldn't save SoundHub data on this Mac: \(error.localizedDescription)"
        }
    }
}

private struct LocalSoundHubState {
    var songs: [Song]
    var favoriteIDs: Set<String>
    var votes: [String: Int]
    var createdSongIDs: Set<String>
    var forkedSongIDs: Set<String>
    var displayName: String
    var profileImageURL: String?
}

private struct StoredSoundHubState: Codable {
    var songs: [StoredSong]
    var favoriteIDs: [String]
    var votes: [String: Int]
    var createdSongIDs: [String]
    var forkedSongIDs: [String]
    var displayName: String
    var profileImageURL: String?
}

private struct StoredSong: Codable {
    var id: String
    var title: String
    var creator: String
    var genre: String
    var branches: Int
    var likes: Int
    var red: Double
    var green: Double
    var blue: Double
    var parentID: String?
    var rootID: String
    var description: String
    var mediaURL: String?
    var isSample: Bool
    var sourceURL: String?

    init(_ song: Song) {
        id = song.id
        title = song.title
        creator = song.creator
        genre = song.genre
        branches = song.branches
        likes = song.likes
        let color = NSColor(song.color).usingColorSpace(.deviceRGB) ?? .white
        red = Double(color.redComponent)
        green = Double(color.greenComponent)
        blue = Double(color.blueComponent)
        parentID = song.parentID
        rootID = song.rootID
        description = song.description
        mediaURL = song.mediaURL?.absoluteString
        isSample = song.isSample
        sourceURL = song.sourceURL
    }

    var song: Song {
        Song(id: id, title: title, creator: creator, genre: genre, branches: branches,
             likes: likes, color: Color(red: red, green: green, blue: blue),
             parentID: parentID, rootID: rootID, description: description,
             mediaURL: mediaURL.flatMap { URL(string: $0) }, isSample: isSample,
             sourceURL: sourceURL)
    }
}

private struct SoundHubLocalPersistence {
    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("SoundHub", isDirectory: true)
            .appendingPathComponent("SoundHubStore.json")
    }

    func load() -> LocalSoundHubState? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(StoredSoundHubState.self, from: data) else { return nil }
        return LocalSoundHubState(songs: stored.songs.map(\.song),
                                  favoriteIDs: Set(stored.favoriteIDs), votes: stored.votes,
                                  createdSongIDs: Set(stored.createdSongIDs),
                                  forkedSongIDs: Set(stored.forkedSongIDs),
                                  displayName: stored.displayName,
                                  profileImageURL: stored.profileImageURL)
    }

    func save(_ state: LocalSoundHubState) throws {
        guard let fileURL else { throw CocoaError(.fileWriteNoSuchFile) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let stored = StoredSoundHubState(songs: state.songs.map(StoredSong.init),
                                         favoriteIDs: state.favoriteIDs.sorted(), votes: state.votes,
                                         createdSongIDs: state.createdSongIDs.sorted(),
                                         forkedSongIDs: state.forkedSongIDs.sorted(),
                                         displayName: state.displayName,
                                         profileImageURL: state.profileImageURL)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum HubPage: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case tree = "Song Tree"
    case library = "MyHub"
    case create = "Create"
    case importTrack = "SoundCloud Import"
    case profile = "Profile"
    case about = "About"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .discover: "sparkles"
        case .tree: "point.3.connected.trianglepath.dotted"
        case .library: "square.stack"
        case .create: "square.and.arrow.up"
        case .importTrack: "arrow.down.circle"
        case .profile: "person.crop.circle"
        case .about: "info.circle"
        }
    }
}

private enum DiscoverySort: String, CaseIterable, Identifiable {
    case newest
    case mostBranches
    case mostLiked
    case title

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest"
        case .mostBranches: "Most branched"
        case .mostLiked: "Most liked"
        case .title: "Title"
        }
    }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case myMusic = "My Music"
    case branches = "Branches"
    case favorites = "Favorites"
    case votes = "My Votes"
    var id: String { rawValue }
}

private struct TreeEntry: Identifiable {
    let song: Song
    let depth: Int
    var id: String { song.id }
}

/// Local preview catalog used while matching the legacy app's interface and workflows.
private struct Song: Identifiable, Hashable {
    let id: String
    let title: String
    var creator: String
    let genre: String
    var branches: Int
    var likes: Int
    let color: Color
    let parentID: String?
    let rootID: String
    let description: String
    let mediaURL: URL?
    let isSample: Bool
    var sourceURL: String? = nil

    var canPlay: Bool { ["https", "file"].contains(mediaURL?.scheme?.lowercased() ?? "") }
}

private enum SampleCatalog {
    static let songs: [Song] = [
        Song(id: "root-01", title: "After the Rain", creator: "Mira Sol", genre: "Ambient", branches: 8, likes: 24, color: Color(red: 0.40, green: 0.70, blue: 0.60), parentID: nil, rootID: "root-01", description: "", mediaURL: nil, isSample: true),
        Song(id: "branch-01", title: "After the Rain · piano study", creator: "Northline", genre: "Neo-classical", branches: 3, likes: 12, color: Color(red: 0.76, green: 0.52, blue: 0.34), parentID: "root-01", rootID: "root-01", description: "", mediaURL: nil, isSample: true),
        Song(id: "branch-02", title: "After the Rain · slow bloom", creator: "june.wav", genre: "Downtempo", branches: 1, likes: 8, color: Color(red: 0.48, green: 0.52, blue: 0.78), parentID: "root-01", rootID: "root-01", description: "", mediaURL: nil, isSample: true),
        Song(id: "root-02", title: "Soft Machines", creator: "Kite Assembly", genre: "Electronic", branches: 5, likes: 17, color: Color(red: 0.70, green: 0.42, blue: 0.57), parentID: nil, rootID: "root-02", description: "", mediaURL: nil, isSample: true),
        Song(id: "root-03", title: "Small Hours", creator: "Amari Blue", genre: "Indie", branches: 2, likes: 11, color: Color(red: 0.77, green: 0.64, blue: 0.37), parentID: nil, rootID: "root-03", description: "", mediaURL: nil, isSample: true),
        Song(id: "branch-03", title: "Soft Machines · field recording", creator: "Loam", genre: "Experimental", branches: 0, likes: 4, color: Color(red: 0.43, green: 0.68, blue: 0.72), parentID: "root-02", rootID: "root-02", description: "", mediaURL: nil, isSample: true),
    ]

    static let apiColors: [Color] = [
        Color(red: 0.40, green: 0.70, blue: 0.60),
        Color(red: 0.76, green: 0.52, blue: 0.34),
        Color(red: 0.48, green: 0.52, blue: 0.78),
        Color(red: 0.70, green: 0.42, blue: 0.57),
        Color(red: 0.77, green: 0.64, blue: 0.37),
        Color(red: 0.43, green: 0.68, blue: 0.72),
    ]
}

private struct SoundHubWindow: View {
    @EnvironmentObject private var model: SoundHubViewModel
    @State private var page: HubPage = .discover
    @State private var selectedSongID = SampleCatalog.songs[0].id
    @State private var searchText = ""
    @State private var discoverySort: DiscoverySort = .mostBranches
    @State private var librarySection: LibrarySection = .myMusic
    @State private var showingSignIn = false
    @State private var branchParent: Song?
    @State private var profileName = "Guest"
    @State private var profileImageText = ""
    @StateObject private var playback = SoundHubPlaybackModel()

    private var catalogSongs: [Song] { model.songs }

    private var selectedSong: Song {
        catalogSongs.first(where: { $0.id == selectedSongID }) ?? catalogSongs.first ?? SampleCatalog.songs[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    topBar
                    Group {
                        switch page {
                        case .discover: discover
                        case .tree: songTree
                        case .library:
                            if model.isSignedIn { library } else { signInRequired }
                        case .create:
                            if model.isSignedIn {
                                CreateSongView(parent: branchParent) { song in
                                    selectSong(song)
                                    branchParent = nil
                                    page = .tree
                                }
                            } else { signInRequired }
                        case .importTrack: SoundCloudImportView()
                        case .profile:
                            if model.isSignedIn { profile } else { signInRequired }
                        case .about: about
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(SoundHubPalette.background)
            }
            playerBar
        }
        .background(SoundHubPalette.background)
        .foregroundStyle(.white)
        .sheet(isPresented: $showingSignIn) {
            LocalSignInView()
                .environmentObject(model)
        }
    }

    private func openSongTree(_ song: Song) {
        selectSong(song)
        model.loadRemoteTree(rootID: song.rootID)
        page = .tree
    }

    private func performMemberAction(_ action: () -> Void) {
        guard model.isSignedIn else {
            showingSignIn = true
            return
        }
        action()
    }

    private func selectSong(_ song: Song) {
        if selectedSongID != song.id { playback.stop() }
        selectedSongID = song.id
    }

    private func moveSelection(by offset: Int) {
        let songs = catalogSongs
        guard songs.count > 1,
              let index = songs.firstIndex(where: { $0.id == selectedSongID }) else { return }
        let nextIndex = (index + offset + songs.count) % songs.count
        selectSong(songs[nextIndex])
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image("SoundHubMark").resizable().scaledToFit().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SoundHub").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("OPEN MUSIC").font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(SoundHubPalette.muted)
                }
            }
            .padding(.bottom, 32)

            Text("LISTEN & EXPLORE").font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(SoundHubPalette.muted).padding(.horizontal, 11).padding(.bottom, 8)
            navigationButton(.discover)
            navigationButton(.tree)
            navigationButton(.importTrack)
            Text("YOUR HUB").font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(SoundHubPalette.muted).padding(.horizontal, 11).padding(.top, 20).padding(.bottom, 8)
            navigationButton(.library)
            navigationButton(.create)
            navigationButton(.profile)
            Text("INFO").font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(SoundHubPalette.muted).padding(.horizontal, 11).padding(.top, 20).padding(.bottom, 8)
            navigationButton(.about)

            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Local preview", systemImage: "hammer")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(SoundHubPalette.accent)
                Text("Explore SoundHub’s workflows locally. Preview changes stay in this session until API integration is added.")
                    .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                if model.isSignedIn {
                    Text("Signed in locally as \(model.displayName)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Button("Sign out") { model.signOut() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(SoundHubPalette.accent)
                } else {
                    Button("Sign in / Create account") { showingSignIn = true }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(SoundHubPalette.accent)
                }
            }
            .padding(12).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20).frame(width: 225).background(SoundHubPalette.sidebar)
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(SoundHubPalette.muted)
                TextField("Search songs, creators, or genres", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Search songs, creators, or genres")
            }
            .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: 350)
            .background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 9))
            Spacer()
            Label("Local preview", systemImage: "hammer")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(SoundHubPalette.muted)
        }
        .padding(.horizontal, 28).padding(.vertical, 17)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private func navigationButton(_ item: HubPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).frame(width: 17)
                Text(item.rawValue)
                Spacer()
            }
            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
            .foregroundStyle(page == item ? .white : SoundHubPalette.muted)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(minHeight: 38)
            .background(page == item ? Color.white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(page == item ? "Current page" : "")
    }

    private var discover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("MUSIC GROWS\nWHEN IT'S SHARED")
                            .font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.8)
                        Text("Explore open songs, follow the branches, and see where a shared idea can go.")
                            .font(.system(size: 13)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                        Button { openSongTree(selectedSong) } label: {
                            Label("Explore song tree", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 9)
                                .background(SoundHubPalette.accent, in: Capsule()).foregroundStyle(SoundHubPalette.background)
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    heroArtwork
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color(red: 0.12, green: 0.23, blue: 0.20), SoundHubPalette.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))

                HStack {
                    sectionHeader("Growing songs", detail: "Ideas with active branches")
                    Picker("Sort songs", selection: $discoverySort) {
                        ForEach(DiscoverySort.allCases) { sort in Text(sort.title).tag(sort) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 145)
                }
                .onChange(of: discoverySort) { newSort in model.updateRemoteSort(newSort) }
                if discoverRoots.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "waveform").font(.system(size: 24)).foregroundStyle(SoundHubPalette.muted)
                        Text("No songs found").font(.system(size: 13, weight: .semibold))
                        Text("The SoundHub catalog is empty or no songs match this search.").font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                    }
                    .frame(maxWidth: .infinity).padding(28).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 13)], spacing: 13) {
                        ForEach(discoverRoots) { song in
                            SongCard(
                                song: song,
                                isSelected: selectedSongID == song.id,
                                isFavorite: model.favoriteIDs.contains(song.id),
                                vote: model.votes[song.id] ?? 0,
                                action: { openSongTree(song) },
                                onPlay: { selectSong(song); playback.toggle(song: song) },
                                onFavorite: { performMemberAction { model.toggleFavorite(song.id) } },
                                onVote: { value in performMemberAction { model.vote(value, for: song.id) } },
                                onBranch: { performMemberAction { branchParent = song; page = .create } }
                            )
                        }
                    }
                }
                if model.hasMoreServiceSongs {
                    Button {
                        model.loadMoreRemoteSongs()
                    } label: {
                        HStack(spacing: 8) {
                            if model.isLoadingMoreServiceSongs { ProgressView().controlSize(.small) }
                            Text(model.isLoadingMoreServiceSongs ? "Loading…" : "Load more songs")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoadingMoreServiceSongs)
                    .accessibilityHint("Loads the next page of SoundHub songs")
                }
                Text(model.serviceSongCount > 0
                     ? "Showing \(model.loadedServiceSongCount) of \(model.serviceSongCount) server songs. Member actions save on this Mac."
                     : "Local catalog data · member actions save on this Mac")
                    .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
            }
            .padding(28)
        }
    }

    private var songTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading("Song tree", subtitle: "Follow how an original idea has been reworked and extended.")
                HStack(spacing: 14) {
                    artwork(for: selectedSong, size: 88)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ROOT SONG").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(SoundHubPalette.accent)
                        Text(rootSong(for: selectedSong).title).font(.system(size: 21, weight: .bold, design: .rounded))
                        Text("Started by \(rootSong(for: selectedSong).creator) · \(rootSong(for: selectedSong).genre)").font(.system(size: 11)).foregroundStyle(SoundHubPalette.muted)
                    }
                    Spacer()
                    Text("\(treeSize(for: selectedSong)) versions")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(SoundHubPalette.muted)
                        .padding(.horizontal, 11).padding(.vertical, 7).background(SoundHubPalette.panel, in: Capsule())
                }
                if !rootSong(for: selectedSong).description.isEmpty {
                    Text(rootSong(for: selectedSong).description)
                        .font(.system(size: 11)).foregroundStyle(SoundHubPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = selectedSong.sourceURL, let sourceURL = URL(string: source) {
                    Link(destination: sourceURL) {
                        Label("Open SoundCloud source", systemImage: "arrow.up.right.square")
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(SoundHubPalette.accent)
                }
                VStack(alignment: .leading, spacing: 0) {
                ForEach(treeRows(for: selectedSong)) { entry in
                        Button {
                            selectSong(entry.song)
                        } label: {
                            HStack(spacing: 12) {
                                artwork(for: entry.song, size: 38)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.song.title).font(.system(size: 12, weight: entry.song.id == selectedSong.id ? .semibold : .medium)).foregroundStyle(.white)
                                    Text("\(entry.song.creator) · \(entry.song.genre)").font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                                }
                                Spacer()
                                if entry.song.id == selectedSong.id { Image(systemName: "arrow.left.circle.fill").foregroundStyle(SoundHubPalette.accent) }
                                else { Image(systemName: "arrow.branch").foregroundStyle(SoundHubPalette.muted) }
                            }
                            .padding(.leading, CGFloat(entry.depth) * 24)
                            .padding(10).background(entry.song.id == selectedSong.id ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 14))
                Label("Select a version to play it, or use Create to add a local branch.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 10) {
                    Button { performMemberAction { model.toggleFavorite(selectedSong.id) } } label: {
                        Label(model.favoriteIDs.contains(selectedSong.id) ? "Favorited" : "Favorite", systemImage: model.favoriteIDs.contains(selectedSong.id) ? "star.fill" : "star")
                    }.buttonStyle(.bordered)
                    Button { performMemberAction { model.vote(1, for: selectedSong.id) } } label: {
                        Label("Upvote · \(selectedSong.likes)", systemImage: "hand.thumbsup")
                    }.buttonStyle(.bordered).tint(model.votes[selectedSong.id] == 1 ? SoundHubPalette.accent : nil)
                    Button { performMemberAction { model.vote(-1, for: selectedSong.id) } } label: {
                        Label("Downvote", systemImage: "hand.thumbsdown")
                    }.buttonStyle(.bordered).tint(model.votes[selectedSong.id] == -1 ? .red : nil)
                    Button { performMemberAction { branchParent = selectedSong; page = .create } } label: {
                        Label("Create branch", systemImage: "arrow.branch")
                    }.buttonStyle(.borderedProminent)
                    ShareLink(item: "SoundHub track: \(selectedSong.title) by \(selectedSong.creator)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered)
                    Spacer()
                }
            }.padding(28)
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                pageHeading("Your library", subtitle: "Your songs and branches, together in one place.")
                HStack(spacing: 12) {
                    libraryStat("Songs", value: "\(model.createdSongIDs.count)")
                    libraryStat("Branches", value: "\(model.forkedSongIDs.count)")
                    libraryStat("Favorites", value: "\(model.favoriteIDs.count)")
                    libraryStat("Votes", value: "\(model.votes.values.filter { $0 != 0 }.count)")
                }
                Picker("Library section", selection: $librarySection) {
                    ForEach(LibrarySection.allCases) { section in Text(section.rawValue).tag(section) }
                }.pickerStyle(.segmented).frame(maxWidth: 470)
                sectionHeader(librarySection.rawValue, detail: "Saved on this Mac")
                ForEach(librarySongs) { song in
                    HStack(spacing: 8) {
                        Button { openSongTree(song) } label: { SongRow(song: song) }.buttonStyle(.plain)
                        if librarySection == .favorites {
                            Button { model.toggleFavorite(song.id) } label: { Image(systemName: "star.slash") }
                                .buttonStyle(.bordered).help("Remove from favorites")
                        }
                        if librarySection == .votes {
                            Label(model.votes[song.id] == 1 ? "Upvoted" : "Downvoted",
                                  systemImage: model.votes[song.id] == 1 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(model.votes[song.id] == 1 ? SoundHubPalette.accent : .red)
                        }
                    }
                }
                if librarySongs.isEmpty {
                    Text(libraryEmptyMessage)
                        .font(.system(size: 12)).foregroundStyle(SoundHubPalette.muted)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(28)
        }
    }

    private var profile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading("Profile", subtitle: "Manage your SoundHub identity.")
                HStack(spacing: 16) {
                    AsyncImage(url: model.profileImageURL.flatMap { URL(string: $0) }) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit().foregroundStyle(SoundHubPalette.accent).padding(5)
                        }
                    }
                    .frame(width: 58, height: 58).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isSignedIn ? model.displayName : "Guest")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Local preview account")
                            .font(.system(size: 11)).foregroundStyle(SoundHubPalette.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Display name").font(.system(size: 12, weight: .semibold))
                    TextField("Your name", text: $profileName).textFieldStyle(.roundedBorder)
                    Text("Profile image URL").font(.system(size: 12, weight: .semibold))
                    TextField("https://…", text: $profileImageText).textFieldStyle(.roundedBorder)
                    Button("Save profile") {
                        model.saveProfile(name: profileName, imageURL: profileImageText)
                    }.buttonStyle(.borderedProminent)
                    if let message = model.profileMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                    }
                }
                .padding(20).frame(maxWidth: 520, alignment: .leading).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }
        .onAppear {
            profileName = model.displayName
            profileImageText = model.profileImageURL ?? ""
        }
    }

    private var signInRequired: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("Sign in to MyHub", subtitle: "Access your music, branches, favorites, and profile.")
            Text("Use the local preview account to explore these screens. Account authentication will connect in a later API phase.")
                .font(.system(size: 12)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
            Button("Sign in / Create account") { showingSignIn = true }.buttonStyle(.borderedProminent)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeading("About SoundHub", subtitle: "Open source music grows through collaboration.")
                Text("SoundHub lets musicians share an idea, branch from another song, and follow how each contribution grows into a song tree.")
                    .font(.system(size: 14)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                Label("Native macOS interface preview", systemImage: "macbook")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(SoundHubPalette.accent)
                Text("Songs, branches, favorites, votes, and profile name changes are saved on this Mac. Connect a SoundHub service below to load its catalog; member actions still stay local until the service supports authenticated writes.")
                    .font(.system(size: 11)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("SoundHub service").font(.system(size: 14, weight: .semibold))
                    TextField("https://your-soundhub-service", text: $model.apiBaseURLText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button { model.connectToService() } label: {
                            if model.isLoadingService { ProgressView().controlSize(.small) }
                            else { Text("Connect and load catalog") }
                        }.disabled(model.isLoadingService)
                        Text(model.serviceMessage).font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                    }
                }
                .padding(16).frame(maxWidth: 640, alignment: .leading)
                .background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                Link("SoundHub source on GitHub", destination: URL(string: "https://github.com/SoundHub/SoundHub")!)
            }.padding(28)
        }
    }

    private var librarySongs: [Song] {
        switch librarySection {
        case .myMusic: model.songs.filter { model.createdSongIDs.contains($0.id) && $0.parentID == nil }
        case .branches: model.songs.filter { model.forkedSongIDs.contains($0.id) }
        case .favorites: model.songs.filter { model.favoriteIDs.contains($0.id) }
        case .votes: model.songs.filter { (model.votes[$0.id] ?? 0) != 0 }
        }
    }

    private var libraryEmptyMessage: String {
        switch librarySection {
        case .myMusic: "Create a new song to see it in My Music."
        case .branches: "Create a branch from a song tree to see it here."
        case .favorites: "Favorite a song to save it here."
        case .votes: "Vote on a song to see it here."
        }
    }

    private var playerBar: some View {
        HStack(spacing: 15) {
            artwork(for: selectedSong, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSong.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(selectedSong.isSample ? "\(selectedSong.creator) · demo track" : "\(selectedSong.creator) · local track")
                    .font(.system(size: 9)).foregroundStyle(SoundHubPalette.muted).lineLimit(1)
            }.frame(width: 180, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 20) {
                Button { moveSelection(by: -1) } label: { Image(systemName: "backward.end.fill") }
                    .help("Select previous catalog song")
                    .accessibilityLabel("Previous song")
                    .frame(minWidth: 36, minHeight: 36)
                    .disabled(catalogSongs.count < 2)
                Button { playback.toggle(song: selectedSong) } label: {
                    Image(systemName: playback.currentSongID == selectedSong.id && playback.isPlaying ? "pause.fill" : "play.fill")
                }
                    .font(.system(size: 14)).help(selectedSong.canPlay ? "Play or pause this song" : "No audio file attached to this local preview song")
                    .accessibilityLabel(playback.currentSongID == selectedSong.id && playback.isPlaying ? "Pause song" : "Play song")
                    .frame(minWidth: 36, minHeight: 36)
                    .disabled(!selectedSong.canPlay)
                Button { moveSelection(by: 1) } label: { Image(systemName: "forward.end.fill") }
                    .help("Select next catalog song")
                    .accessibilityLabel("Next song")
                    .frame(minWidth: 36, minHeight: 36)
                    .disabled(catalogSongs.count < 2)
            }.buttonStyle(.plain).foregroundStyle(SoundHubPalette.muted)
            Spacer(minLength: 8)
            Text(playback.statusMessage ?? (selectedSong.canPlay ? "Ready to play" : "No audio attached in local preview"))
                .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20).frame(height: 68)
        .background(SoundHubPalette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private var heroArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [SoundHubPalette.accent.opacity(0.7), Color(red: 0.14, green: 0.38, blue: 0.32), Color(red: 0.25, green: 0.18, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "waveform.path").font(.system(size: 56, weight: .light)).foregroundStyle(.white.opacity(0.88))
            Circle().stroke(.white.opacity(0.18), lineWidth: 1).frame(width: 128, height: 128)
            Circle().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 160, height: 160)
        }.frame(width: 190, height: 150)
    }

    private var filteredSongs: [Song] {
        guard !searchText.isEmpty else { return catalogSongs }
        return catalogSongs.filter { "\($0.title) \($0.creator) \($0.genre)".localizedCaseInsensitiveContains(searchText) }
    }

    private var discoverRoots: [Song] {
        let matchingRoots = Set(filteredSongs.map(\.rootID))
        let roots = catalogSongs.filter { $0.parentID == nil && matchingRoots.contains($0.rootID) }
        // The service already applies the selected sort across the full result set.
        if model.loadedServicePages > 0 { return roots }
        let positions = Dictionary(uniqueKeysWithValues: catalogSongs.enumerated().map { ($0.element.id, $0.offset) })
        return roots.sorted {
            switch discoverySort {
            case .newest:
                return positions[$0.id, default: 0] > positions[$1.id, default: 0]
            case .mostBranches:
                if $0.branches != $1.branches { return $0.branches > $1.branches }
            case .mostLiked:
                if $0.likes != $1.likes { return $0.likes > $1.likes }
            case .title:
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(SoundHubPalette.muted)
        }
    }

    private func artwork(for song: Song, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.19)).fill(LinearGradient(colors: [song.color, song.color.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "waveform").font(.system(size: size * 0.35, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }.frame(width: size, height: size)
    }

    private func rootSong(for song: Song) -> Song {
        let indexed = Dictionary(uniqueKeysWithValues: catalogSongs.map { ($0.id, $0) })
        var current = song
        var visited = Set<String>()
        while let parentID = current.parentID,
              visited.insert(current.id).inserted,
              let parent = indexed[parentID] {
            current = parent
        }
        return current
    }

    private func treeRows(for song: Song) -> [TreeEntry] {
        let root = rootSong(for: song)
        let source = catalogSongs.filter { $0.rootID == root.rootID }
        let indexed = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var result: [TreeEntry] = []
        var visited = Set<String>()
        func append(_ node: Song, depth: Int) {
            guard visited.insert(node.id).inserted else { return }
            result.append(TreeEntry(song: node, depth: depth))
            source.filter { $0.parentID == node.id }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .forEach { append($0, depth: depth + 1) }
        }
        if let actualRoot = indexed[root.id] { append(actualRoot, depth: 0) }
        for orphan in source where !visited.contains(orphan.id) { append(orphan, depth: 0) }
        return result
    }

    private func treeSize(for song: Song) -> Int { treeRows(for: song).count }

    private func libraryStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(SoundHubPalette.muted)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct CreateSongView: View {
    @EnvironmentObject private var model: SoundHubViewModel
    @State private var title = ""
    @State private var genre = ""
    @State private var description = ""
    @State private var selectedAudioURL: URL?
    @State private var showingFilePicker = false

    private var titleValidationMessage: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count < 3 { return "Use at least 3 characters." }
        if value.count > 15 { return "Keep the title to 15 characters or fewer." }
        if value.range(of: "^[A-Za-z0-9 ]+$", options: .regularExpression) == nil {
            return "Use letters, numbers, and spaces only."
        }
        return nil
    }

    private var canCreateSong: Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (3...15).contains(value.count) && value.range(of: "^[A-Za-z0-9 ]+$", options: .regularExpression) != nil
    }

    let parent: Song?
    let onCreated: (Song) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading
                if let parent {
                    Label("Branching from: \(parent.title)", systemImage: "arrow.branch")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(SoundHubPalette.accent)
                }
                VStack(alignment: .leading, spacing: 15) {
                    labeledField("Song title", placeholder: "Give your idea a name") {
                        TextField("Give your idea a name", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: title) { newValue in
                                if newValue.count > 15 { title = String(newValue.prefix(15)) }
                            }
                    }
                    if let titleValidationMessage {
                        Text(titleValidationMessage).font(.system(size: 10)).foregroundStyle(.orange)
                    } else if !title.isEmpty {
                        Label("Title looks good", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(SoundHubPalette.accent)
                    }
                    labeledField("Genre", placeholder: "Ambient, indie, electronic…") {
                        TextField("Ambient, indie, electronic…", text: $genre).textFieldStyle(.roundedBorder)
                    }
                    labeledField("Description", placeholder: "What should listeners know?") {
                        TextEditor(text: $description).frame(minHeight: 90).padding(5)
                            .background(SoundHubPalette.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Button { showingFilePicker = true } label: {
                            Label(selectedAudioURL == nil ? "Choose audio file" : "Change audio file", systemImage: "waveform.badge.plus")
                        }.buttonStyle(.bordered)
                        Text(selectedAudioURL?.lastPathComponent ?? "No audio selected")
                            .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted).lineLimit(1)
                    }
                    Label("Songs are saved on this Mac. Server upload is not connected yet.", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted)
                    Button {
                        guard canCreateSong else { return }
                        model.addSong(title: title.trimmingCharacters(in: .whitespacesAndNewlines), genre: genre, description: description, mediaURL: selectedAudioURL, parent: parent)
                        if let created = model.songs.last { onCreated(created) }
                    } label: {
                        Label(parent == nil ? "Create song" : "Create branch", systemImage: parent == nil ? "plus" : "arrow.branch")
                    }
                    .buttonStyle(.borderedProminent).disabled(!canCreateSong)
                }
                .padding(20).frame(maxWidth: 610, alignment: .leading).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            selectedAudioURL = url
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(parent == nil ? "Create" : "Create a branch")
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(parent == nil ? "Start a new song tree with an original idea." : "Add your own version to this song tree.")
                .font(.system(size: 12)).foregroundStyle(SoundHubPalette.muted)
        }
    }

    private func labeledField<Field: View>(_ title: String, placeholder: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            field()
        }
    }
}

private struct SoundCloudImportView: View {
    @EnvironmentObject private var model: SoundHubViewModel
    @State private var soundCloudURL = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var genre = ""
    @State private var description = ""
    @State private var imported = false
    @State private var showingSignIn = false

    private var isValidSoundCloudURL: Bool {
        guard let url = URL(string: soundCloudURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SoundCloud Import").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Bring a track into a SoundHub song tree.").font(.system(size: 12)).foregroundStyle(SoundHubPalette.muted)
                }
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Paste a SoundCloud track link", text: $soundCloudURL)
                        .textFieldStyle(.roundedBorder)
                    Label("Track details will be filled from SoundCloud after API integration. For now, enter them below to preview the import flow.", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
                    TextField("Track title", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Artist", text: $artist).textFieldStyle(.roundedBorder)
                    TextField("Genre", text: $genre).textFieldStyle(.roundedBorder)
                    TextEditor(text: $description).frame(minHeight: 75).padding(5)
                        .background(SoundHubPalette.background, in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        guard model.isSignedIn,
                              isValidSoundCloudURL,
                              title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
                        model.addSong(title: title, creator: artist, genre: genre, description: description, mediaURL: nil, sourceURL: soundCloudURL, parent: nil)
                        imported = true
                    } label: {
                        Label(model.isSignedIn ? "Add local preview song" : "Sign in to add", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidSoundCloudURL || title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    .simultaneousGesture(TapGesture().onEnded {
                        if !model.isSignedIn { showingSignIn = true }
                    })
                    if imported {
                        Label("Added to the local preview catalog. It has not been sent to SoundHub.", systemImage: "checkmark.circle")
                            .font(.system(size: 10)).foregroundStyle(SoundHubPalette.accent)
                    }
                }
                .padding(20).frame(maxWidth: 610, alignment: .leading).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }
        .sheet(isPresented: $showingSignIn) { LocalSignInView().environmentObject(model) }
    }
}

private struct LocalSignInView: View {
    @EnvironmentObject private var model: SoundHubViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var isSignUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isSignUp ? "Create account" : "Sign in")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Picker("Account action", selection: $isSignUp) {
                Text("Sign in").tag(false)
                Text("Create account").tag(true)
            }.pickerStyle(.segmented)
            TextField("Username", text: $displayName).textFieldStyle(.roundedBorder)
            Text("Local demo only. No password is requested or sent, and this account will not sync with SoundHub.")
                .font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Continue in preview") {
                    model.signIn(as: displayName)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 400).background(SoundHubPalette.background)
    }
}

private struct SongCard: View {
    let song: Song
    let isSelected: Bool
    let isFavorite: Bool
    let vote: Int
    let action: () -> Void
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onVote: (Int) -> Void
    let onBranch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [song.color.opacity(0.9), song.color.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform.path").font(.system(size: 29, weight: .light)).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(song.isSample ? "PREVIEW SONG" : "LOCAL SONG").font(.system(size: 8, weight: .bold)).tracking(1.2).padding(8)
                }.frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(song.creator) · \(song.genre)").font(.system(size: 10)).foregroundStyle(SoundHubPalette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("\(song.branches)", systemImage: "arrow.branch")
                        Label("\(song.likes)", systemImage: "heart")
                    }.font(.system(size: 9)).foregroundStyle(SoundHubPalette.muted)
                }
            }
            .padding(11).background(SoundHubPalette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(isSelected ? SoundHubPalette.accent.opacity(0.65) : .clear, lineWidth: 1))
            }.buttonStyle(.plain)
            HStack(spacing: 8) {
                Button(action: onPlay) { Image(systemName: "play.fill").frame(minWidth: 28, minHeight: 28) }
                    .help("Play song").accessibilityLabel("Play \(song.title)")
                Button(action: onFavorite) {
                    Label(isFavorite ? "Saved" : "Favorite", systemImage: isFavorite ? "star.fill" : "star")
                }
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(isFavorite ? "Remove \(song.title) from favorites" : "Add \(song.title) to favorites")
                .accessibilityValue(isFavorite ? "Favorited" : "Not favorited")
                Button { onVote(1) } label: {
                    Label("\(song.likes)", systemImage: vote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .frame(minWidth: 28, minHeight: 28)
                }.help("Upvote").accessibilityLabel("Upvote \(song.title), \(song.likes) likes")
                Button { onVote(-1) } label: {
                    Image(systemName: vote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .help("Downvote")
                .accessibilityLabel(vote == -1 ? "Remove downvote from \(song.title)" : "Downvote \(song.title)")
                ShareLink(item: "SoundHub track: \(song.title) by \(song.creator)") {
                    Image(systemName: "square.and.arrow.up").frame(minWidth: 28, minHeight: 28)
                }.help("Share song").accessibilityLabel("Share \(song.title)")
                Spacer(minLength: 0)
                Button(action: onBranch) { Image(systemName: "arrow.branch").frame(minWidth: 28, minHeight: 28) }
                    .help("Create a branch").accessibilityLabel("Create a branch from \(song.title)")
            }
            .font(.system(size: 9, weight: .medium)).buttonStyle(.plain).foregroundStyle(SoundHubPalette.muted)
            .padding(.horizontal, 3)
        }
    }
}

private struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(song.color.opacity(0.75))
                Image(systemName: "waveform").foregroundStyle(.white.opacity(0.9))
            }.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Text("\(song.creator) · \(song.genre)").font(.system(size: 9)).foregroundStyle(SoundHubPalette.muted)
            }
            Spacer()
            HStack(spacing: 9) {
                Label("\(song.likes)", systemImage: "heart")
                Label("\(song.branches)", systemImage: "arrow.branch")
            }.font(.system(size: 9)).foregroundStyle(SoundHubPalette.muted)
        }.padding(8).background(SoundHubPalette.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private final class SoundHubPlaybackModel: ObservableObject {
    @Published private(set) var currentSongID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var statusMessage: String?

    private var player: AVPlayer?

    func toggle(song: Song) {
            guard let url = song.mediaURL,
                  ["https", "file"].contains(url.scheme?.lowercased() ?? ""),
                  url.scheme?.lowercased() == "file" || url.host != nil else {
            statusMessage = "No supported audio URL"
            return
        }

        if currentSongID == song.id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
                statusMessage = "Paused"
            } else {
                player.play()
                isPlaying = true
                statusMessage = "Playing"
            }
            return
        }

        player?.pause()
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        currentSongID = song.id
        newPlayer.play()
        isPlaying = true
        statusMessage = "Playing"
    }

    func stop() {
        player?.pause()
        player = nil
        currentSongID = nil
        isPlaying = false
        statusMessage = nil
    }
}
