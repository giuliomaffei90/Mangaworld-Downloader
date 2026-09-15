import Foundation

/// Safari's own user agent: URLSession speaks Apple's TLS, and another browser's agent on top of it is
/// the mismatch a bot check looks for.
let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

/// Where the site lives today. It moves now and then (.so became .mx); the old name redirecting to the
/// new one is followed by URLSession on its own, and a dead one is typed in the settings.
let defaultDomain = "www.mangaworld.mx"

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct HTTPStatus: LocalizedError {
    let code: Int
    let host: String
    var errorDescription: String? { "HTTP \(code) da \(host)" }
}

/// One request, retried while the source is merely unwell — a timeout, a dropped connection, 429 or
/// 5xx. Any other status is a verdict, and repeating it only delays the same answer.
func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for attempt in 0..<3 {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if attempt == 2 || ![429, 500, 502, 503, 504].contains(status) {
                throw HTTPStatus(code: status, host: url.host ?? "?")
            }
        } catch let error as URLError where attempt < 2 && error.code != .cancelled {}
        try await Task.sleep(for: .seconds(1 << attempt))
    }
    throw URLError(.unknown)  // unreachable: the last attempt returns or throws
}

extension String {
    /// One level of HTML escaping undone: numeric entities, then the named ones, `&amp;` last.
    var htmlUnescaped: String {
        let numeric = replacing(#/&#(\d+);/#) { match in
            UInt32(match.1).flatMap { Unicode.Scalar($0) }.map { String($0) } ?? String(match.0)
        }
        return [("&quot;", "\""), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
            .reduce(numeric) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

struct Manga: Identifiable, Hashable, Codable {
    var url: URL
    var name: String
    var cover: URL? = nil
    var id: URL { url }
}

struct Chapter: Hashable, Codable {
    var name: String
    var url: URL
}

/// What becomes one .cbz. A manga the site keeps without volumes is a single one, named after it.
struct Volume: Identifiable, Hashable, Codable {
    var name: String
    var chapters: [Chapter]
    var id: String { name }
}

/// A row of the start page: a list the site itself curates.
struct Shelf: Identifiable {
    let id: String
    let mangas: [Manga]
}

/// The site is server-rendered, minified HTML with attributes quoted only when they must be. The parsers
/// take the page as text, so the tests can hold them to what the site sends.
enum Mangaworld {
    struct Details {
        var plot: String?
        var year: String?
        var genres: [String]
        var volumes: [Volume]
    }

    /// Values are encoded by hand down to the unreserved characters, so nothing in a name — a "+", an "&", a
    /// space, as in "Jae-Hwan Kim & Balo" — is left for the server to read as query syntax.
    static func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents()
        components.scheme = "https"
        components.host = configuredDomain
        components.path = path
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
            }
        }
        guard let url = components.url else { throw Failure("Dominio non valido: «\(configuredDomain)»") }
        return url
    }

    static func text(_ url: URL) async throws -> String {
        String(decoding: try await fetch(url), as: UTF8.self)
    }

    /// One page of the archive, how many pages it has and how many manga in all (the site leaves the count out
    /// for one result or none). A title, filters, or both: the archive answers to filters alone.
    static func search(_ query: String, filters: Filters, page: Int) async throws -> (mangas: [Manga], pages: Int, total: Int?) {
        var items = filters.queryItems
        if !query.isEmpty { items.insert(URLQueryItem(name: "keyword", value: query), at: 0) }
        items.append(URLQueryItem(name: "page", value: "\(page)"))
        let html = try await text(url("/archive", items))
        return (mangas(in: html),
                html.firstMatch(of: #/"totalPages":(\d+)/#).flatMap { Int($0.1) } ?? 1,
                html.firstMatch(of: #/([\d.]+) risultati trovati/#).flatMap { Int(String($0.1).replacingOccurrences(of: ".", with: "")) })
    }

    static func home() async throws -> [Shelf] {
        shelves(in: try await text(url("/")))
    }

    static func filterOptions() async throws -> FilterOptions {
        filterOptions(in: try await text(url("/archive")))
    }

    static func details(_ manga: Manga) async throws -> Details {
        details(in: try await text(manga.url), name: manga.name)
    }

    /// Every page of a chapter, from its "list" view, which shows them all at once.
    static func pages(of chapter: Chapter) async throws -> [URL] {
        guard var components = URLComponents(url: chapter.url, resolvingAgainstBaseURL: false) else { throw Failure("Indirizzo non valido") }
        components.queryItems = [URLQueryItem(name: "style", value: "list")]
        let found = pages(in: try await text(components.url ?? chapter.url))
        guard !found.isEmpty else { throw Failure("Nessuna pagina trovata in «\(chapter.name)»") }
        return found
    }

    // MARK: Parsers

    private static func uncommented(_ html: String) -> String {
        html.replacing(#/<!--[\s\S]*?-->/#, with: "")
    }

    /// An attribute's value, quoted or not.
    static func attribute(_ name: String, in tag: some StringProtocol) -> String? {
        guard let match = String(tag).firstMatch(of: try! Regex("\\b\(name)=(?:\"([^\"]*)\"|([^\\s>]+))")),
              let value = match.output[1].substring ?? match.output[2].substring else { return nil }
        return String(value).htmlUnescaped
    }

    /// Every manga a page shows with its cover: a link to the manga wrapped around the picture. The search
    /// results and all the home page's lists draw them this way.
    static func mangas(in html: String) -> [Manga] {
        var seen = Set<URL>()
        return uncommented(html).matches(of: #/<a\b([^>]*)>(?:<div class=thumb>)?<img\b([^>]*)>/#).compactMap { match in
            guard let href = attribute("href", in: match.1), href.wholeMatch(of: #/https?:\/\/[^\/]+\/manga\/\d+\/[^\/?#]+/#) != nil,
                  let url = URL(string: href), seen.insert(url).inserted,
                  let name = (attribute("title", in: match.1) ?? attribute("alt", in: match.2))?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { return nil }
            return Manga(url: url, name: name, cover: attribute("src", in: match.2).flatMap { URL(string: $0) })
        }
    }

    /// The home page, cut at its headings; the ones with no manga under them (login, socials) drop out.
    static func shelves(in html: String) -> [Shelf] {
        let html = uncommented(html)
        let headings = html.matches(of: #/<h3[^>]*>([^<]+)<\/h3>/#)
        return headings.indices.compactMap { index in
            let end = index + 1 < headings.count ? headings[index + 1].range.lowerBound : html.endIndex
            let found = mangas(in: String(html[headings[index].range.upperBound..<end]))
            return found.isEmpty ? nil : Shelf(id: String(headings[index].1).htmlUnescaped, mangas: found)
        }
    }

    /// The page lists the newest volume and chapter first; these come back in reading order.
    static func details(in html: String, name: String) -> Details {
        let html = uncommented(html)
        let plot = html.firstMatch(of: #/<div id=noidungm[^>]*>([\s\S]*?)<\/div>/#)
            .map { String($0.1).replacing(#/<[^>]+>/#, with: "").htmlUnescaped.trimmingCharacters(in: .whitespacesAndNewlines) }
        let list = html.range(of: "chapters-wrapper").map { html[$0.upperBound...] } ?? html[...]

        func chapters(_ text: Substring) -> [Chapter] {
            Array(text.matches(of: #/<a class=chap href="?([^\s>"]+)"?[^>]*><span class=d-inline-block>([^<]+)<\/span>/#)
                .compactMap { m in URL(string: String(m.1)).map { Chapter(name: String(m.2).htmlUnescaped, url: $0) } }
                .reversed())
        }

        let pieces = list.split(separator: #/class="volume-element/#, omittingEmptySubsequences: false)
        let volumes = pieces.count > 1
            ? pieces.dropFirst().reversed().map { piece in
                // The name follows an icon whose attribute holds a whole <img … />, so no tag pattern gets past it.
                Volume(name: piece.firstMatch(of: #/<p class="volume-name[^"]*">[\s\S]*?([^<>"]+)<\/p>/#)
                    .map { String($0.1).htmlUnescaped.trimmingCharacters(in: .whitespaces) } ?? "Volume",
                       chapters: chapters(piece))
            }
            : [Volume(name: name, chapters: chapters(list))]

        return Details(plot: plot?.isEmpty == false ? plot : nil,
                       year: html.firstMatch(of: #/archive\?year=(\d{4})/#).map { String($0.1) },
                       genres: html.matches(of: #/class="badge badge-primary[^"]*">([^<]+)<\/a>/#).map { String($0.1).htmlUnescaped },
                       volumes: volumes.filter { !$0.chapters.isEmpty })
    }

    static func pages(in html: String) -> [URL] {
        html.matches(of: #/<img id=page-\d+[^>]*\bsrc="?([^\s>"]+)/#).compactMap { URL(string: String($0.1)) }
    }

    /// The archive's filter form: each <select>, known by the heading just before it.
    static func filterOptions(in html: String) -> FilterOptions {
        let html = uncommented(html)
        var options = FilterOptions()
        for select in html.matches(of: #/<select\b[^>]*>([\s\S]*?)<\/select>/#) {
            let start = html.index(select.range.lowerBound, offsetBy: -300, limitedBy: html.startIndex) ?? html.startIndex
            let heading = html[start..<select.range.lowerBound].matches(of: #/>([^<>]*[^<>\s][^<>]*)</#).last
                .map { String($0.1).trimmingCharacters(in: .whitespaces) }
            let found = select.1.matches(of: #/<option\b([^>]*)>([^<]*)/#).compactMap { option in
                attribute("data-name", in: option.1).map {
                    FilterOptions.Option(value: $0, name: String(option.2).htmlUnescaped.trimmingCharacters(in: .whitespaces))
                }
            }
            switch heading {
            case "Generi": options.genres = found
            case "Tipo": options.types = found
            case "Stato": options.statuses = found
            case "Autore": options.authors = found
            case "Artista": options.artists = found
            case "Anno": options.years = found
            case "Ordina per": options.sorts = found
            default: break
            }
        }
        return options
    }
}

/// The archive's filters. Values of one kind are alternatives (horror or drama) and the kinds all apply at once
/// (horror and manhwa), which is the site's own rule: it repeats a parameter once per value.
struct Filters: Hashable {
    var genres: Set<String> = []
    var types: Set<String> = []
    var statuses: Set<String> = []
    var years: Set<String> = []
    /// Exactly as the site spells it, capitals included: "okada shunpei" finds nothing.
    var author = ""
    var artist = ""
    /// Empty for the site's own order, A-Z.
    var sort = ""

    var count: Int {
        genres.count + types.count + statuses.count + years.count
            + [author, artist, sort].filter { !$0.isEmpty }.count
    }

    var isEmpty: Bool { count == 0 }

    var queryItems: [URLQueryItem] {
        func each(_ name: String, _ values: Set<String>) -> [URLQueryItem] {
            values.sorted().map { URLQueryItem(name: name, value: $0) }
        }
        var items = each("genre", genres) + each("type", types) + each("status", statuses) + each("year", years)
        for (name, value) in [("author", author), ("artist", artist), ("sort", sort)] where !value.isEmpty {
            items.append(URLQueryItem(name: name, value: value))
        }
        return items
    }
}

/// What the filter form offers, read from the site so a new genre or author shows up by itself.
struct FilterOptions {
    struct Option: Hashable {
        let value: String
        let name: String
    }
    var genres: [Option] = []
    var types: [Option] = []
    var statuses: [Option] = []
    var authors: [Option] = []
    var artists: [Option] = []
    var years: [Option] = []
    var sorts: [Option] = []
}
