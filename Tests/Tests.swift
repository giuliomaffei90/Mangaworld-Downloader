import ImageIO
import XCTest
@testable import MangaworldDownloader

/// The fixtures are cut from what the site sent in September 2026: unquoted attributes, Marko comments and all.
final class Tests: XCTestCase {
    func testSearchResultsAndShelves() {
        let search = #"<div class=comics-grid><!--F#p_16[0]--><!--M#s0-16[0]--><div class=entry><a class="thumb position-relative" href=https://www.mangaworld.mx/manga/4666/eden title=Eden><img src=https://cdn.mangaworld.mx/mangas/a.jpg?1789 alt=Eden loading=lazy></a><div class=content><p class="name m-0"><a class=manga-title href=https://www.mangaworld.mx/manga/4666/eden title=Eden>Eden</a></p></div></div><div class=entry><a class="thumb position-relative" href=https://www.mangaworld.mx/manga/1580/eden-s-zero title="Edens &amp; Zero"><img src=https://cdn.mangaworld.mx/mangas/b.jpg alt="Edens Zero" loading=lazy></a></div>"#
        let found = Mangaworld.mangas(in: search)
        XCTAssertEqual(found.map(\.name), ["Eden", "Edens & Zero"])
        XCTAssertEqual(found.first?.cover?.absoluteString, "https://cdn.mangaworld.mx/mangas/a.jpg?1789")

        let home = #"<h3>Capitoli di tendenza</h3></div><div class="entry vertical"><a href=https://www.mangaworld.mx/manga/1891/nano-machine class="thumb position-relative" title="Nano Machine"><img src=https://cdn.mangaworld.mx/x.png alt="Nano Machine" loading=lazy><div class=chapter>Capitolo 306</div></a></div><h3 class=cate-title>Socials</h3><a href=https://t.me/x><img src=https://t.png></a><h3>Manga del mese</h3></div><div class=top-wrapper><div class=entry><div class=short><a href=https://www.mangaworld.mx/manga/1708/one-piece title="One Piece" class=chap>Leggi!</a></div><div class=long><a href=https://www.mangaworld.mx/manga/1708/one-piece title="One Piece"><div class=thumb><img src=https://cdn.mangaworld.mx/op.jpg alt="One Piece" class=img-fluid loading=lazy></div></a></div></div>"#
        let shelves = Mangaworld.shelves(in: home)
        XCTAssertEqual(shelves.map(\.id), ["Capitoli di tendenza", "Manga del mese"])
        XCTAssertEqual(shelves.last?.mangas.map(\.name), ["One Piece"])
    }

    func testFilters() throws {
        let form = #"<form><div class=col-12><span class=font-weight-bold>Generi</span><select class=filter-select style="height: 38px!important;" multiple><option data-name=horror>Horror</option><option data-name=sci-fi>Sci-fi</option></select></div><div class=col-12><span class=font-weight-bold>Autore</span><select class=filter-select multiple><option data-name="  Ohagi-san">  Ohagi-san</option><option data-name=" Jae-Hwan Kim & Balo"> Jae-Hwan Kim &amp; Balo</option></select></div><div class=col-12><span>Ordina per</span><select class=filter-select><option data-name=most_read>Più letti</option><option data-name=a-z selected>A-Z</option></select></div></form>"#
        let options = Mangaworld.filterOptions(in: form)
        XCTAssertEqual(options.genres.map(\.value), ["horror", "sci-fi"])
        XCTAssertEqual(options.authors.map(\.value), ["  Ohagi-san", " Jae-Hwan Kim & Balo"])
        XCTAssertEqual(options.authors.last?.name, "Jae-Hwan Kim & Balo")
        XCTAssertEqual(options.sorts.map(\.value), ["most_read", "a-z"])

        // One parameter per value, and nothing in a name left to read as query syntax.
        var filters = Filters()
        XCTAssertTrue(filters.isEmpty)
        filters.genres = ["horror", "drammatico"]
        filters.artist = "Jae-Hwan Kim & Balo+"
        XCTAssertEqual(filters.count, 3)
        XCTAssertEqual(try Mangaworld.url("/archive", filters.queryItems).query(percentEncoded: true),
                       "genre=drammatico&genre=horror&artist=Jae-Hwan%20Kim%20%26%20Balo%2B")
    }

    func testVolumesComeInReadingOrder() {
        let page = #"<div id=noidungm class=mb-3>Anno 2029. L&#39;ex poliziotto <b>Hibino</b>.</div><a href=https://www.mangaworld.mx/archive?year=2007>2007</a><a href=x class="badge badge-primary ml-1 mt-1 p-1">Mistero</a><a href=y class="badge badge-primary ml-1 mt-1 p-1">Sci-fi</a><div class="chapters-wrapper py-2 pl-0"><div class="volume-element pl-2"><p class="volume-name d-inline"><i class="far fa-file-image mr-2" id=volume-image-0 aria-hidden=true data-volume-image="<img src=https://cdn.mangaworld.mx/volumes/v.jpg class=&#34;img-fluid volume-thumb&#34; />"></i>Volume 02</p><div class=chapter><a class=chap href=https://www.mangaworld.mx/manga/1/x/read/c4 title="X Capitolo 04 Scan ITA"><span class=d-inline-block>Capitolo 04</span><i class="text-right text-muted chap-date">11 Marzo 2026</i></a></div><div class=chapter><a class=chap href=https://www.mangaworld.mx/manga/1/x/read/c3 title="X Capitolo 03 Scan ITA"><span class=d-inline-block>Capitolo 03</span></a></div></div><div class="volume-element pl-2"><p class="volume-name d-inline">Volume 01</p><div class=chapter><a class=chap href=https://www.mangaworld.mx/manga/1/x/read/c1 title="X Capitolo 01"><span class=d-inline-block>Capitolo 01</span></a></div></div></div>"#
        let details = Mangaworld.details(in: page, name: "X")
        XCTAssertEqual(details.plot, "Anno 2029. L'ex poliziotto Hibino.")
        XCTAssertEqual(details.year, "2007")
        XCTAssertEqual(details.genres, ["Mistero", "Sci-fi"])
        XCTAssertEqual(details.volumes.map(\.name), ["Volume 01", "Volume 02"])
        XCTAssertEqual(details.volumes.last?.chapters.map(\.name), ["Capitolo 03", "Capitolo 04"])

        // No volumes on the site: one file, named after the manga.
        let loose = #"<div class="chapters-wrapper py-2 pl-0"><div class="chapter pl-2"><a class=chap href=https://www.mangaworld.mx/manga/4227/your-ryan/read/b?style=list title="Your Ryan Capitolo 02 Scan ITA"><span class=d-inline-block>Capitolo 02</span></a></div><div class="chapter pl-2"><a class=chap href=https://www.mangaworld.mx/manga/4227/your-ryan/read/a?style=list title="Your Ryan Capitolo 01 Scan ITA"><span class=d-inline-block>Capitolo 01</span></a></div></div>"#
        let single = Mangaworld.details(in: loose, name: "Your Ryan").volumes
        XCTAssertEqual(single.map(\.name), ["Your Ryan"])
        XCTAssertEqual(single.first?.chapters.map(\.name), ["Capitolo 01", "Capitolo 02"])
    }

    func testChapterPages() {
        let page = #"<img src=https://www.mangaworld.mx/public/assets/svg/MangaWorldLogo.svg?6 class="custom-logo img-fluid"><img id=page-0 class="page-image img-fluid" src=https://cdn.mangaworld.mx/chapters/eden/capitolo-02/1.png><img id=page-1 class="page-image img-fluid" src=https://cdn.mangaworld.mx/chapters/eden/capitolo-02/2.jpg>"#
        XCTAssertEqual(Mangaworld.pages(in: page).map(\.lastPathComponent), ["1.png", "2.jpg"])
    }

    /// The layout is also how a volume already on disk is recognised.
    func testLibraryLayout() {
        let manga = Manga(url: URL(string: "https://www.mangaworld.mx/manga/2278/berserk")!, name: "Berserk: Deluxe")
        XCTAssertEqual(destination(DownloadRequest(manga: manga, volume: Volume(name: "Volume 01", chapters: [])), in: URL(filePath: "/L")).path,
                       "/L/Berserk Deluxe/Volume 01.cbz")
        XCTAssertEqual(sanitize(" ../.. "), "senza-nome")
    }

    func testCBZHoldsOnlyThePagesInOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = ["0001.jpg", "0002.png"].map { folder.appending(path: $0) }
        for page in pages { try Data("x".utf8).write(to: page) }
        let archive = folder.appending(path: "v.cbz")
        try await writeCBZ(pages, to: archive)
        XCTAssertEqual(try entries(of: archive), ["0001.jpg", "0002.png"])
    }

    /// A spread whose halves sit right before it goes; a spread with nothing matching around it stays.
    func testRedundantSpreadsAreLeftOut() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let layout: [[UInt64]] = [[1], [2], [1, 2], [3], [4, 5], [6]]
        let files = try layout.enumerated().map { index, seeds in
            let file = folder.appending(path: String(format: "%04d.png", index + 1))
            try writePage(seeds, to: file)
            return file
        }
        XCTAssertEqual(redundantSpreads(files), [2])
        // Right to left, as a manga reads it.
        try writePage([2, 1], to: files[2])
        XCTAssertEqual(redundantSpreads(files), [2])
    }

    /// One page per seed, side by side: rectangles of grey, the same for the same seed.
    private func writePage(_ seeds: [UInt64], to url: URL) throws {
        let width = 200, height = 300
        let context = try XCTUnwrap(CGContext(data: nil, width: width * seeds.count, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for (index, seed) in seeds.enumerated() {
            let frame = CGRect(x: index * width, y: 0, width: width, height: height)
            context.saveGState()
            context.clip(to: frame)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(frame)
            var state = seed
            for _ in 0..<60 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = Int(state >> 33)
                context.setFillColor(gray: CGFloat(v % 256) / 255, alpha: 1)
                context.fill(CGRect(x: Int(frame.minX) + v % width, y: (v >> 8) % height, width: 20 + (v >> 16) % 80, height: 20 + (v >> 20) % 120))
            }
            context.restoreGState()
        }
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }

    private func entries(of archive: URL) throws -> [String] {
        let unzip = Process(), pipe = Pipe()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", archive.path]
        unzip.standardOutput = pipe
        try unzip.run()
        unzip.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Against the real site: `LIVE=1 swift test`.
    func testLiveSite() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] != nil, "LIVE=1 swift test to run it against the site")
        let shelves = try await Mangaworld.home()
        XCTAssertFalse(shelves.isEmpty)
        // Filters alone are a search: every horror manga.
        var horror = Filters()
        horror.genres = ["horror"]
        let scary = try await Mangaworld.search("", filters: horror, page: 1)
        XCTAssertGreaterThan(scary.total ?? 0, 100)
        XCTAssertFalse(scary.mangas.isEmpty)
        let options = try await Mangaworld.filterOptions()
        XCTAssertTrue(options.genres.contains { $0.value == "horror" })
        XCTAssertGreaterThan(options.authors.count, 1000)
        XCTAssertFalse(options.types.isEmpty || options.statuses.isEmpty || options.years.isEmpty || options.sorts.isEmpty || options.artists.isEmpty)

        let results = try await Mangaworld.search("berserk", filters: Filters(), page: 1)
        let berserk = try XCTUnwrap(results.mangas.first { $0.name == "Berserk" })
        let details = try await Mangaworld.details(berserk)
        XCTAssertGreaterThan(details.volumes.count, 40)
        XCTAssertEqual(details.volumes.first?.name, "Volume 01")
        let pages = try await Mangaworld.pages(of: try XCTUnwrap(details.volumes.first?.chapters.first))
        XCTAssertFalse(pages.isEmpty)

        // The whole engine, on a one-chapter volume: every page, in order, in a .cbz in its place.
        // The site matches the whole phrase against the title only, so "oneshot" cannot go in the query.
        let witches = try await Mangaworld.search("burn the witch", filters: Filters(), page: 1)
        let oneshot = try XCTUnwrap(witches.mangas.first { $0.name.hasSuffix("Oneshot") })
        let smallest = try await Mangaworld.details(oneshot).volumes.min { $0.chapters.count < $1.chapters.count }
        let volume = try XCTUnwrap(smallest)
        var expected = 0
        for chapter in volume.chapters { expected += try await Mangaworld.pages(of: chapter).count }
        let library = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let file = try await download(DownloadRequest(manga: oneshot, volume: volume), library: library,
                                      temp: library.appending(path: "temp"), report: { _, _ in })
        XCTAssertEqual(file.path, destination(DownloadRequest(manga: oneshot, volume: volume), in: library).path)
        let names = try entries(of: file)
        XCTAssertEqual(names.count, expected)
        XCTAssertEqual(names.first?.prefix(5), "0001.")
    }
}
