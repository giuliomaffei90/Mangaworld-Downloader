import AppKit
import Foundation
import ImageIO

struct DownloadRequest: Codable, Hashable {
    var manga: Manga
    var volume: Volume

    var label: String { volume.name == manga.name ? manga.name : "\(manga.name) · \(volume.name)" }
}

// MARK: Settings

/// What the user pasted, reduced to a host: an address copied from the browser works as well as a bare name.
var configuredDomain: String {
    let raw = (UserDefaults.standard.string(forKey: "domain") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let host = URL(string: raw.contains("//") ? raw : "https://" + raw)?.host() ?? raw
    return host.isEmpty ? defaultDomain : host
}

var libraryFolder: URL {
    let path = UserDefaults.standard.string(forKey: "folder") ?? ""
    return path.isEmpty ? URL.documentsDirectory.appending(path: "Mangaworld") : URL(filePath: path)
}

// MARK: Library layout

/// Strips what a file name cannot hold: names come from someone else's site, and a "../" in one must
/// not become a traversal.
func scrub(_ name: String) -> String {
    name.replacing(#/[\\\/:*?"<>|\x00-\x1F]/#, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
}

func sanitize(_ name: String) -> String {
    let cleaned = scrub(name)
    return cleaned.isEmpty ? "senza-nome" : String(cleaned.prefix(180))
}

/// `<library>/<Manga>/<Volume>.cbz`. It is also how the app knows a volume is already there, so a change
/// here makes every file on disk look missing.
func destination(_ request: DownloadRequest, in library: URL) -> URL {
    library.appending(path: sanitize(request.manga.name)).appending(path: sanitize(request.volume.name) + ".cbz")
}

// MARK: Engine

typealias Report = @Sendable (_ phase: String, _ fraction: Double) -> Void

/// Pages fetched at once within one volume.
private let pageWidth = 8

/// Every page of every chapter, in reading order, into one stored zip moved into place at the end. A page
/// that will not come fails the volume: a .cbz with a hole in it reads as complete and is not.
func download(_ request: DownloadRequest, library: URL, temp: URL, report: @escaping Report) async throws -> URL {
    let chapters = request.volume.chapters
    var pages: [URL] = []
    for (index, chapter) in chapters.enumerated() {
        report("Capitolo \(index + 1) di \(chapters.count)", Double(index) / Double(chapters.count) * 0.1)
        pages += try await Mangaworld.pages(of: chapter)
    }

    let folder = temp.appending(path: "pages")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Numbered across the whole volume, so any reader's name order is the reading order.
    let files = pages.indices.map { index in
        let ext = pages[index].pathExtension.isEmpty ? "jpg" : pages[index].pathExtension.lowercased()
        return folder.appending(path: String(format: "%04d.%@", index + 1, ext))
    }
    var done = 0
    func step() { done += 1; report("Pagina \(done) di \(pages.count)", 0.1 + 0.9 * Double(done) / Double(pages.count)) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in pages.indices {
            if index >= pageWidth { _ = try await group.next(); step() }
            group.addTask { try await fetch(pages[index]).write(to: files[index]) }
        }
        while try await group.next() != nil { step() }
    }

    report("Controllo delle tavole doppie", 1)
    let spreads = redundantSpreads(files)
    report("Creazione del cbz", 1)
    let archive = temp.appending(path: "volume.cbz")
    try await writeCBZ(files.indices.filter { !spreads.contains($0) }.map { files[$0] }, to: archive)
    let target = destination(request, in: library)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: archive, to: target)
    return target
}

/// The system's zip: stored, since the pages are already compressed images; `-j` keeps only the file
/// names and `-X` leaves out the macOS extras, so a reader finds nothing but the pages.
func writeCBZ(_ pages: [URL], to archive: URL) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.arguments = ["-q", "-0", "-X", "-j", archive.path] + pages.map(\.path)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { finished in
            if finished.terminationStatus == 0 {
                continuation.resume()
            } else {
                continuation.resume(throwing: Failure("zip non riuscito (codice \(finished.terminationStatus))"))
            }
        }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}

// MARK: Double spreads

/// The spreads the site also carries cut in two right beside them, by index: those stay out of the .cbz, and
/// a spread with no halves around it stays in. They are fetched all the same, since the halves are only
/// recognisable by their pixels. A spread is a page about twice as wide as the volume's usual one; its halves
/// are the two pages just before or just after it when both correlate with them.
///
/// Correlation, not a difference hash: pencil art on grey paper, cropped a little differently in the split
/// version, put true halves 9–18 bits from the spread out of 64 and unrelated pages 20–39, too close to draw
/// a line. By correlation, Berserk's first volume scores its true halves 0.73–0.99 and every other neighbour
/// at most 0.21; Hunter x Hunter's spreads, which have no halves, score about 0.
func redundantSpreads(_ files: [URL]) -> Set<Int> {
    // A thumbnail is plenty for a 24×34 fingerprint, and keeps a volume of large pages out of memory.
    let images = files.map { url -> CGImage? in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
    }
    let ratios = images.compactMap { $0.map { Double($0.width) / Double($0.height) } }.sorted()
    guard !ratios.isEmpty else { return [] }
    let median = ratios[ratios.count / 2]
    func width(_ index: Int) -> Double? {
        guard images.indices.contains(index), let image = images[index] else { return nil }
        return Double(image.width) / Double(image.height) / median
    }
    func isSingle(_ index: Int) -> Bool { width(index).map { abs($0 - 1) <= 0.25 } ?? false }
    func same(_ a: [Double], _ b: [Double]) -> Bool { correlation(a, b) >= 0.6 }
    let prints = images.map { $0.map(fingerprint) }

    var redundant = Set<Int>()
    for index in images.indices {
        guard let image = images[index], let k = width(index), abs(k - 2) <= 0.30,
              let left = image.cropping(to: CGRect(x: 0, y: 0, width: image.width / 2, height: image.height)),
              let right = image.cropping(to: CGRect(x: image.width - image.width / 2, y: 0, width: image.width / 2, height: image.height))
        else { continue }
        let l = fingerprint(left), r = fingerprint(right)
        for first in [index - 2, index + 1] where isSingle(first) && isSingle(first + 1) {
            guard let a = prints[first], let b = prints[first + 1] else { continue }
            // Either order: a manga reads its halves right to left, and a cover's front comes before its back.
            if (same(a, l) && same(b, r)) || (same(a, r) && same(b, l)) {
                redundant.insert(index)
                break
            }
        }
    }
    return redundant
}

/// The page as 24×34 greys, whatever its size: coarse enough that a slightly different crop or scan of the same
/// drawing lines up, fine enough that two different drawings do not.
func fingerprint(_ image: CGImage) -> [Double] {
    let w = 24, h = 34
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let pixels = context.data
    else { return [] }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = pixels.bindMemory(to: UInt8.self, capacity: w * h)
    return (0..<(w * h)).map { Double(p[$0]) }
}

/// Pearson correlation: 1 for the same picture whatever its brightness and contrast, about 0 for unrelated ones.
func correlation(_ a: [Double], _ b: [Double]) -> Double {
    guard !a.isEmpty, a.count == b.count else { return 0 }
    let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
    var product = 0.0, da = 0.0, db = 0.0
    for i in a.indices {
        let x = a[i] - ma, y = b[i] - mb
        product += x * y
        da += x * x
        db += y * y
    }
    return da == 0 || db == 0 ? 0 : product / (da * db).squareRoot()
}

// MARK: Jobs

struct Job: Identifiable, Codable {
    enum Status: String, Codable {
        case queued, running, done, failed, cancelled
        var isActive: Bool { self == .queued || self == .running }
    }
    var id = UUID()
    var request: DownloadRequest
    var status = Status.queued
    var phase = ""
    var fraction = 0.0
    var output: URL?
}

/// The download list: volumes run a few at a time, remembered across restarts. Nothing resumes — a job
/// cut short comes back as failed, and Riprova runs it again from the start.
@MainActor @Observable final class Downloads {
    /// Oldest first, the order they run in; the list shows them newest first.
    private(set) var jobs: [Job] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private static let ledger = URL.applicationSupportDirectory.appending(path: "Mangaworld Downloader/downloads.json")

    init() {
        jobs = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: Self.ledger))) ?? []
        for index in jobs.indices where jobs[index].status.isActive {
            jobs[index].status = .failed
            jobs[index].phase = "Interrotto dalla chiusura dell'app"
        }
    }

    var activeCount: Int { jobs.filter(\.status.isActive).count }

    func isQueued(_ request: DownloadRequest) -> Bool {
        jobs.contains { $0.status.isActive && $0.request == request }
    }

    func enqueue(_ requests: [DownloadRequest]) {
        let library = libraryFolder
        // Two jobs writing one file leave it corrupt: whatever is already on its way there is not queued twice.
        var busy = Set(jobs.filter(\.status.isActive).map { destination($0.request, in: library) })
        jobs += requests.filter { busy.insert(destination($0, in: library)).inserted }.map { Job(request: $0) }
        changed()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        update(id) { $0.status = .cancelled; $0.phase = "Annullato" }
        changed()
    }

    func retry(_ id: UUID) {
        guard tasks[id] == nil else { return }  // still unwinding from its cancellation
        update(id) { $0 = Job(id: $0.id, request: $0.request) }
        changed()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.status.isActive }
        changed()
    }

    func clearFinished() {
        jobs.removeAll { !$0.status.isActive }
        changed()
    }

    private func pump() {
        var running = jobs.filter { $0.status == .running }.count
        for job in jobs where job.status == .queued && running < max(1, UserDefaults.standard.integer(forKey: "maxDownloads")) {
            running += 1
            update(job.id) { $0.status = .running; $0.phase = "Avvio" }
            tasks[job.id] = Task { await run(job.id, job.request) }
        }
    }

    private func run(_ id: UUID, _ request: DownloadRequest) async {
        let temp = FileManager.default.temporaryDirectory.appending(path: "Mangaworld/\(id.uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let report: Report = { phase, fraction in
            Task { @MainActor in
                self.update(id) {
                    guard $0.status == .running else { return }  // a late report
                    $0.phase = phase
                    $0.fraction = fraction
                }
            }
        }
        do {
            let file = try await download(request, library: libraryFolder, temp: temp, report: report)
            update(id) { $0.status = .done; $0.output = file; $0.phase = ""; $0.fraction = 1 }
        } catch {
            let cancelled = Task.isCancelled
            update(id) {
                $0.status = cancelled ? .cancelled : .failed
                $0.phase = cancelled ? "Annullato" : error.localizedDescription
            }
        }
        tasks[id] = nil
        changed()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }

    private func changed() {
        pump()
        try? FileManager.default.createDirectory(at: Self.ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(jobs.suffix(500))).write(to: Self.ledger)
    }
}
