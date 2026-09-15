import AppKit
import SwiftUI

struct ContentView: View {
    enum Page: Hashable { case search, downloads }
    @State private var page = Page.search
    @Environment(Downloads.self) private var downloads

    var body: some View {
        // The system's own sidebar of tabs, which also keeps each tab's state while another is shown.
        TabView(selection: $page) {
            Tab("Cerca", systemImage: "magnifyingglass", value: .search) { NavigationStack { SearchView() } }
            Tab("Download", systemImage: "arrow.down.circle", value: .downloads) { NavigationStack { DownloadsView() } }
                .badge(downloads.activeCount)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            SettingsLink {
                Label("Impostazioni", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)  // a bottom bar would otherwise reduce it to the icon
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: Search

struct SearchView: View {
    /// What a search answers to: the title, the filters, and the domain, which may hold other results.
    struct Key: Hashable {
        var text: String
        var filters: Filters
        var domain: String
    }

    @AppStorage("domain") private var domain = ""
    @State private var query = ""
    @State private var filters = Filters()
    @State private var showsFilters = false
    @State private var results: [Manga] = []
    @State private var total: Int?
    @State private var searchedFor: Key?
    @State private var lastSearch: Key?
    @State private var searching = false
    @State private var error: String?
    @State private var shelves: [Shelf] = []
    @State private var shelvesFor: String?
    @State private var shelvesError: String?
    @State private var selected: Manga?
    @State private var page = 1
    @State private var pages = 1
    @State private var loadingMore = false
    @State private var moreError: String?

    private var key: Key { Key(text: query.trimmingCharacters(in: .whitespaces), filters: filters, domain: domain) }
    /// A title of three letters or more, or any filter at all: the horror genre alone lists every horror manga.
    private var showsShelves: Bool { key.text.count < 3 && filters.isEmpty }

    private var subtitle: String {
        guard !showsShelves, searchedFor != nil, !searching else { return "" }
        let count = total ?? results.count
        return count == 1 ? "1 manga" : "\(count) manga"
    }

    var body: some View {
        ScrollView {
            if showsShelves {
                // Nothing typed yet: what the site itself puts on its front page.
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(shelves) { shelf in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(shelf.id).font(.title2.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(shelf.mangas) { manga in
                                        Button { selected = manga } label: { Card(manga: manga).frame(width: 150) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(results) { manga in
                        Button { selected = manga } label: { Card(manga: manga) }.buttonStyle(.plain)
                    }
                }
                .padding()
                if page < pages && !results.isEmpty {
                    VStack(spacing: 6) {
                        Button { Task { await loadMore() } } label: {
                            if loadingMore { ProgressView().controlSize(.small) } else { Text("Carica altri") }
                        }
                        .disabled(loadingMore)
                        if let moreError { Text(moreError).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .overlay { overlay }
        .searchable(text: $query, placement: .toolbar, prompt: "Cerca un manga…")
        .toolbar {
            Button { showsFilters.toggle() } label: {
                Label("Filtri", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(filters.isEmpty ? "Filtri di ricerca" : "Filtri di ricerca: \(filters.count) attivi")
            .popover(isPresented: $showsFilters, arrowEdge: .bottom) { FiltersView(filters: $filters) }
        }
        // Every keystroke or ticked filter restarts this, cancelling the previous run mid-sleep: that is the debounce.
        .task(id: key) { await search() }
        .task(id: domain) { await loadShelves() }
        .task { _ = try? await FilterCatalogue.options() }  // under way before the panel is first opened
        .sheet(item: $selected) { MangaSheet(manga: $0) }
        .navigationTitle("Cerca")
        .navigationSubtitle(subtitle)
    }

    @ViewBuilder private var overlay: some View {
        if searching {
            ProgressView()
        } else if showsShelves, let shelvesError {
            ContentUnavailableView("Mangaworld non raggiungibile", systemImage: "exclamationmark.triangle",
                                   description: Text(shelvesError))
        } else if !showsShelves, let error {
            ContentUnavailableView("Ricerca non riuscita", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if showsShelves && shelves.isEmpty {
            ProgressView()
        } else if !showsShelves, results.isEmpty, let searchedFor {
            if searchedFor.text.isEmpty {
                ContentUnavailableView("Nessun manga con questi filtri", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Togline qualcuno, o scegline altri."))
            } else {
                ContentUnavailableView.search(text: searchedFor.text)
            }
        }
    }

    private func search() async {
        let key = key
        guard key != lastSearch else { return }  // back on this tab: what is on screen already answers it
        guard !showsShelves else { results = []; total = nil; searchedFor = nil; error = nil; lastSearch = key; return }
        do {
            try await Task.sleep(for: .milliseconds(400))
            searching = true
            defer { searching = false }
            let found = try await Mangaworld.search(key.text, filters: key.filters, page: 1)
            results = found.mangas
            total = found.total
            page = 1
            pages = found.pages
            moreError = nil
            searchedFor = key
            error = nil
            lastSearch = key
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription; results = [] }
        }
    }

    private func loadMore() async {
        guard let key = lastSearch else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let found = try await Mangaworld.search(key.text, filters: key.filters, page: page + 1)
            guard key == lastSearch else { return }  // the search changed while this page was on its way
            page += 1
            let known = Set(results.map(\.id))
            results += found.mangas.filter { !known.contains($0.id) }
            moreError = nil
        } catch {
            moreError = error.localizedDescription
        }
    }

    private func loadShelves() async {
        let key = configuredDomain
        guard key != shelvesFor else { return }
        shelves = []
        shelvesError = nil
        do {
            shelves = try await Mangaworld.home()
            shelvesFor = key
        } catch {
            if !Task.isCancelled { shelvesError = error.localizedDescription }
        }
    }
}

/// The site's own filters. Several values of one kind let any of them through; the kinds all apply together.
/// The filter form's options, fetched once a launch and shared by every opening of the panel. The fetch is a
/// task of its own, so a view that goes away mid-way does not cancel it for the next one.
@MainActor enum FilterCatalogue {
    private static var loading: Task<FilterOptions, Error>?

    static func options() async throws -> FilterOptions {
        let task = loading ?? Task { try await Mangaworld.filterOptions() }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil  // the next opening asks again
            throw error
        }
    }
}

/// The site's own filters. Several values of one kind let any of them through; the kinds all apply together.
/// It loads its options itself: handed in from the search, they never reached a panel opened before they arrived.
struct FiltersView: View {
    @Binding var filters: Filters
    @State private var options: FilterOptions?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Filtri non disponibili", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Riprova") { Task { await load() } }
                }
            } else if let options {
                Form {
                    Section {
                        LabeledContent {
                            Button("Azzera") { filters = Filters() }.disabled(filters.isEmpty)
                        } label: {
                            Text(filters.isEmpty ? "Nessun filtro" : "\(filters.count) filtri attivi")
                        }
                        Picker("Ordina per", selection: $filters.sort) {
                            Text("Predefinito").tag("")
                            ForEach(options.sorts, id: \.self) { Text($0.name).tag($0.value) }
                        }
                    }
                    choices("Generi", options.genres, $filters.genres, width: 130)
                    choices("Tipo", options.types, $filters.types, width: 110)
                    choices("Stato", options.statuses, $filters.statuses, width: 110)
                    Section("Autori") {
                        person("Autore", $filters.author, options.authors)
                        person("Artista", $filters.artist, options.artists)
                    }
                    choices("Anno", options.years, $filters.years, width: 90)
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 580, height: 660)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            options = try await FilterCatalogue.options()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func choices(_ title: String, _ values: [FilterOptions.Option], _ selection: Binding<Set<String>>, width: CGFloat) -> some View {
        Section(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(values, id: \.self) { option in
                    Toggle(option.name, isOn: Binding {
                        selection.wrappedValue.contains(option.value)
                    } set: { isOn in
                        if isOn { selection.wrappedValue.insert(option.value) } else { selection.wrappedValue.remove(option.value) }
                    })
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                }
            }
        }
    }

    /// The site matches a name exactly, so it is picked from the site's own list; one typed in lower case is
    /// matched to that list on Return.
    private func person(_ title: String, _ name: Binding<String>, _ known: [FilterOptions.Option]) -> some View {
        TextField(title, text: name, prompt: Text("Come sul sito"))
            .textInputSuggestions {
                let typed = name.wrappedValue.trimmingCharacters(in: .whitespaces)
                if typed.count >= 2 {
                    ForEach(known.filter { $0.value != name.wrappedValue && $0.name.localizedCaseInsensitiveContains(typed) }.prefix(8),
                            id: \.self) {
                        Text($0.name).textInputCompletion($0.value)
                    }
                }
            }
            .onSubmit {
                let typed = name.wrappedValue.trimmingCharacters(in: .whitespaces)
                if let exact = known.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) { name.wrappedValue = exact.value }
            }
    }
}

struct Card: View {
    let manga: Manga

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Poster(url: manga.cover)
            Text(manga.name).font(.headline).lineLimit(2)
        }
        .contentShape(Rectangle())
    }
}

struct Poster: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Not AsyncImage: in a lazy grid, a load cut short while the grid lays itself out again ends in
            // its failure state for good. This asks again whenever the cover comes back on screen.
            .task(id: url) { image = await Covers.image(url) }
    }
}

/// Covers already fetched, for the session; the system trims it when memory runs short.
enum Covers {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let kept = cache.object(forKey: url as NSURL) { return kept }
        guard let data = try? await fetch(url), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: One manga

struct MangaSheet: View {
    let manga: Manga
    @Environment(\.dismiss) private var dismiss
    @Environment(Downloads.self) private var downloads
    @State private var details: Mangaworld.Details?
    @State private var error: String?
    @State private var confirmAll = false

    private var volumes: [Volume] { details?.volumes ?? [] }
    private var missing: [Volume] { volumes.filter { !onDisk($0) && !downloads.isQueued(request($0)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                Poster(url: manga.cover).frame(width: 150)
                VStack(alignment: .leading, spacing: 8) {
                    Text(manga.name).font(.title2.bold())
                    if !meta.isEmpty { Text(meta).foregroundStyle(.secondary) }
                    if let plot = details?.plot {
                        ScrollView { Text(plot).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text(volumes.count == 1 ? "1 volume" : "\(volumes.count) volumi").foregroundStyle(.secondary)
                Spacer()
                Button("Scarica tutti") { confirmAll = true }.disabled(missing.isEmpty)
            }
            List(volumes) { volume in
                HStack {
                    Text(volume.name)
                    Text(volume.chapters.count == 1 ? "1 capitolo" : "\(volume.chapters.count) capitoli").foregroundStyle(.secondary)
                    Spacer()
                    if downloads.isQueued(request(volume)) {
                        Image(systemName: "clock").foregroundStyle(.secondary).help("In coda")
                    } else if onDisk(volume) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Già scaricato")
                    } else {
                        Button("Scarica", systemImage: "arrow.down.circle") { downloads.enqueue([request(volume)]) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if details == nil && error == nil { ProgressView() } }
            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
        .task { await load() }
        .confirmationDialog("Aggiungere alla coda \(missing.count) volumi?", isPresented: $confirmAll) {
            Button("Aggiungi alla coda") { downloads.enqueue(missing.map(request)); dismiss() }
        }
    }

    private var meta: String {
        ([details?.year] + (details?.genres ?? [])).compactMap { $0 }.joined(separator: " · ")
    }

    private func request(_ volume: Volume) -> DownloadRequest { DownloadRequest(manga: manga, volume: volume) }

    private func onDisk(_ volume: Volume) -> Bool {
        FileManager.default.fileExists(atPath: destination(request(volume), in: libraryFolder).path)
    }

    private func load() async {
        do {
            details = try await Mangaworld.details(manga)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

// MARK: Downloads

struct DownloadsView: View {
    @Environment(Downloads.self) private var downloads

    var body: some View {
        List(downloads.jobs.reversed()) { JobRow(job: $0) }
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle",
                                           description: Text("I volumi che scarichi compaiono qui."))
                }
            }
            .toolbar {
                Button("Apri la cartella", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(libraryFolder)
                }
                Button("Togli i terminati", systemImage: "checklist.checked") { downloads.clearFinished() }
            }
            .navigationTitle("Download")
    }
}

struct JobRow: View {
    let job: Job
    @Environment(Downloads.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            Poster(url: job.request.manga.cover).frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.label).fontWeight(.medium).lineLimit(1)
                ProgressView(value: job.status == .done ? 1 : job.fraction).tint(tint)
                Text(caption).font(.caption).foregroundStyle(job.status == .failed ? .red : .secondary).lineLimit(2)
            }
            if job.status.isActive {
                Button("Interrompi", systemImage: "stop.circle") { downloads.cancel(job.id) }
            } else {
                if job.status == .failed || job.status == .cancelled {
                    Button("Riprova", systemImage: "arrow.clockwise") { downloads.retry(job.id) }
                }
                if let file = job.output {
                    Button("Mostra nel Finder", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
                Button("Togli dalla lista", systemImage: "xmark") { downloads.remove(job.id) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch job.status {
        case .done: .green
        case .failed: .red
        case .queued, .cancelled: .gray
        case .running: .blue
        }
    }

    private var caption: String {
        switch job.status {
        case .queued: "In coda"
        case .running, .failed, .cancelled: job.phase
        case .done: job.output?.lastPathComponent ?? "Completato"
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @AppStorage("domain") private var domain = ""
    @AppStorage("folder") private var folder = ""
    @AppStorage("maxDownloads") private var maxDownloads = 2

    var body: some View {
        Form {
            Section {
                TextField("Dominio", text: $domain, prompt: Text(defaultDomain))
            } header: {
                Text("Sorgente")
            } footer: {
                Text("Vuoto usa \(defaultDomain). Se il sito cambia indirizzo, incolla qui quello nuovo, anche copiato dal browser.")
                    .foregroundStyle(.secondary)
            }
            Section("Download") {
                LabeledContent("Cartella") {
                    HStack {
                        Text(folder.isEmpty ? libraryFolder.path : folder).lineLimit(1).truncationMode(.middle)
                        Button("Scegli…", action: chooseFolder)
                    }
                }
                Stepper("Volumi contemporanei: \(maxDownloads)", value: $maxDownloads, in: 1...8)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Impostazioni")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = libraryFolder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
