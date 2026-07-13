//
//  StockfishNetworkLoader.swift
//  SwiftStockfish
//
//  A version-aware NNUE network manager. Its one job: make a directory contain
//  EXACTLY the networks the current engine requires — keeping valid ones,
//  (re)downloading missing/corrupt ones, and pruning leftovers from a previous
//  Stockfish version. This is what makes a 18 → 18.1 upgrade a clean, automatic
//  swap rather than a manual file-juggling chore.
//
//  Run this BEFORE creating a `StockfishEngine`: Stockfish exits the host
//  process on a missing/invalid net, so the directory must be correct first.
//
//  INTENTIONAL MIRROR of SwiftReckless's RecklessNetworkLoader.swift: the two
//  packages must stay dependency-free of each other, so the download box, the
//  downloadToTemp staging pipeline, and the pruning sweep are maintained as
//  deliberate twins. CHANGE THEM TOGETHER — a hardening fix landed in one
//  loader must be ported to the other in the same session (this rule exists
//  because the two copies drifted once already). Intentional differences:
//  Stockfish manages a manifest of several `nn-<12hex>.nnue` nets verified by
//  SHA-256 *prefix* with a fishtest→GitHub source fallback; Reckless manages
//  one `v<NN>-<8hex>.nnue` net verified against a pinned *full* SHA-256 from
//  a single URL, so its LoaderError carries download context Stockfish
//  expresses via allSourcesFailed.
//

import Foundation
// On Linux, URLSession lives in the FoundationNetworking module (split out of
// swift-corelibs-foundation); on Apple it is part of Foundation. The plain
// `import Foundation` above is enough on Apple — this only adds the networking
// half where it is a separate module.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// SHA-256 for network verification. Apple ships CryptoKit; non-Apple platforms
// use swift-crypto's `Crypto`, which exposes the identical `SHA256` API
// (`SHA256()` / `update(data:)` / `finalize()`), so the call sites below are
// source-identical on every platform. swift-crypto is declared as a
// non-Apple-only dependency in Package.swift, so the Apple build never resolves
// or links it.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cancellation bridge for the callback-based URLSession API. Parent-task
/// cancellation can race task creation, so the state and task reference share
/// one lock. Deliberate twin of SwiftReckless's RecklessDownloadTaskBox —
/// change them together (see the mirror note in the file header).
private final class StockfishDownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancellationRequested = false

    func installAndResume(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()

        task.resume()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

/// Ensures a directory holds exactly the NNUE networks the engine requires.
///
/// ```swift
/// let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
/// let dir = support.appendingPathComponent("stockfish-nets")
/// try await StockfishNetworkLoader().ensure(in: dir) { p in
///     print("\(p.file): \(p.bytesDownloaded)/\(p.totalBytes)")
/// }
/// guard let engine = StockfishEngine(networkDirectory: dir) else { return }
/// ```
public struct StockfishNetworkLoader: Sendable {

    /// A download endpoint for a network file.
    public enum Source: Sendable, CaseIterable {
        /// The Stockfish fishtest API: `https://tests.stockfishchess.org/api/nn/<filename>`.
        case fishtest
        /// The official networks repo raw files:
        /// `https://raw.githubusercontent.com/official-stockfish/networks/master/<filename>`.
        case githubNetworks

        /// The default try-order: fishtest first, GitHub as fallback.
        static let preferenceOrder: [Source] = [.fishtest, .githubNetworks]

        func url(for filename: String) -> URL {
            switch self {
            case .fishtest:
                return URL(string: "https://tests.stockfishchess.org/api/nn/\(filename)")!
            case .githubNetworks:
                return URL(string: "https://raw.githubusercontent.com/official-stockfish/networks/master/\(filename)")!
            }
        }
    }

    /// Progress for a single in-flight download.
    ///
    /// `totalBytes` is `-1` (`unknownTotalBytes`) when the server does not send
    /// a `Content-Length` (or `Content-Length` is unavailable for the redirect).
    public struct Progress: Sendable {
        public let file: String
        public let bytesDownloaded: Int64
        public let totalBytes: Int64

        /// Sentinel for an unknown total size.
        public static let unknownTotalBytes: Int64 = -1

        /// Fraction in `0...1`, or `nil` when the total is unknown.
        public var fractionCompleted: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1.0, Double(bytesDownloaded) / Double(totalBytes))
        }
    }

    public enum LoaderError: Error, Sendable {
        /// A downloaded file's SHA-256 prefix did not match its filename.
        /// Associated value: the filename.
        case checksumMismatch(String)
        /// Every source failed for a file. Associated value: the filename.
        case allSourcesFailed(String)
        /// A network's filename does not follow Stockfish's `nn-<hex>.nnue`
        /// scheme, so it cannot be verified. Associated value: the filename.
        case invalidNetworkName(String)
        /// A filesystem operation failed. Associated value: a description.
        case fileSystem(String)
    }

    /// The networks this loader will ensure are present. Defaults to the
    /// engine's manifest, ``StockfishNetworks/required``.
    public let networks: [StockfishNetworks.Network]

    private let session: URLSession

    public init(networks: [StockfishNetworks.Network] = StockfishNetworks.required) {
        self.init(networks: networks, session: URLSession(configuration: .ephemeral))
    }

    /// Testability seam: inject a session (e.g. one whose configuration routes
    /// through a stub `URLProtocol`) so the download/cancellation paths can be
    /// exercised hermetically. Production callers use the public initializer.
    init(networks: [StockfishNetworks.Network], session: URLSession) {
        self.networks = networks
        self.session = session
    }

    /// Make `directory` contain EXACTLY the required networks.
    ///
    /// Steps, in order:
    ///   1. Ensure `directory` exists.
    ///   2. PRUNE: delete any `nn-*.nnue` in `directory` that is not in the
    ///      required set (leftovers from a previous Stockfish version), and
    ///      any orphaned `.nn-*.nnue.<UUID>.part` download staging file left
    ///      by a crashed/killed earlier run.
    ///   3. For each required net: keep it if present AND it passes SHA
    ///      verification; otherwise download it (trying fishtest, then GitHub),
    ///      verify it, and move it atomically into place.
    ///
    /// A present, valid net is never re-downloaded (idempotent). Downloads go
    /// to a temp file that is verified before replacing the destination, so a
    /// failed/aborted download never leaves a corrupt net behind.
    /// Cancelling the calling task cancels the active URLSession transfer and
    /// throws `CancellationError`; cancellation never advances to a fallback
    /// source.
    ///
    /// - Parameters:
    ///   - directory: Where the nets should live.
    ///   - progress: Optional per-byte progress callback, invoked on downloads
    ///     only. May be called from a background task.
    public func ensure(
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default

        // 1. Ensure the directory exists.
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LoaderError.fileSystem("could not create \(directory.path): \(error.localizedDescription)")
        }
        try Task.checkCancellation()

        let requiredNames = Set(networks.map(\.filename))

        // 2. Prune any nn-*.nnue that isn't required.
        try pruneStaleNetworks(in: directory, keeping: requiredNames, fm: fm)
        try Task.checkCancellation()

        // 3. Ensure each required net.
        for network in networks {
            try Task.checkCancellation()
            guard !network.shaPrefix.isEmpty else {
                throw LoaderError.invalidNetworkName(network.filename)
            }
            let destination = directory.appendingPathComponent(network.filename)

            // Keep it if present and valid.
            if fm.fileExists(atPath: destination.path),
               (try? verify(fileAt: destination, matches: network)) == true {
                try Task.checkCancellation()
                continue
            }
            // Remove an invalid/partial existing file before re-fetching.
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }

            try await download(network, to: destination, in: directory, progress: progress, fm: fm)
        }
    }

    // MARK: - Pruning

    /// Deliberate twin of RecklessNetworkLoader.pruneStaleFiles — change them
    /// together (see the mirror note in the file header).
    private func pruneStaleNetworks(
        in directory: URL,
        keeping requiredNames: Set<String>,
        fm: FileManager
    ) throws {
        let contents: [URL]
        do {
            // No `.skipsHiddenFiles`: the download staging files this pruner
            // must reclaim are dot-prefixed (hidden) by design — see below.
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            // A directory we just created should be enumerable; treat a failure
            // here as fatal so we don't silently skip pruning.
            throw LoaderError.fileSystem("could not enumerate \(directory.path): \(error.localizedDescription)")
        }

        for url in contents {
            let name = url.lastPathComponent

            // Orphaned download staging files: downloadToTemp stages in-flight
            // bytes at `.nn-<hex>.nnue.<UUID>.part`; in-process cleanup is a
            // `defer` in download(), so a crash/kill during the verify/install
            // window (which includes SHA-256 hashing the ~100 MB big net)
            // orphans the file forever — ~100 MB leaked per crash. Any `.part`
            // present NOW is from a dead run: live staging files exist only
            // during a download, and downloads start strictly after this prune
            // within the same `ensure` call (concurrent `ensure` calls on one
            // directory are not supported). The three-piece match is exact to
            // the staging scheme so no unrelated hidden file is ever touched.
            if name.hasPrefix(".nn-"), name.contains(".nnue."), name.hasSuffix(".part") {
                try? fm.removeItem(at: url)
                continue
            }

            guard name.hasPrefix("nn-"), name.hasSuffix(".nnue") else { continue }
            if !requiredNames.contains(name) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Downloading

    private func download(
        _ network: StockfishNetworks.Network,
        to destination: URL,
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)?,
        fm: FileManager
    ) async throws {
        var lastError: Error?

        for source in Source.preferenceOrder {
            do {
                let tempURL = try await downloadToTemp(
                    network, from: source, in: directory, progress: progress
                )
                defer { try? fm.removeItem(at: tempURL) }
                try Task.checkCancellation()

                // Verify before moving into place.
                guard try verify(fileAt: tempURL, matches: network) else {
                    lastError = LoaderError.checksumMismatch(network.filename)
                    continue  // try the next source
                }
                try Task.checkCancellation()

                // Atomic-ish move into place (replace if a stale file lingers).
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                do {
                    try fm.moveItem(at: tempURL, to: destination)
                } catch {
                    throw LoaderError.fileSystem(
                        "could not install \(network.filename): \(error.localizedDescription)"
                    )
                }
                return  // success
            } catch is CancellationError {
                // Cancellation is a caller decision, not a source failure. Do
                // not silently start the fallback URL after the task is gone.
                throw CancellationError()
            } catch let error as LoaderError {
                // Filesystem errors during install are not source-specific; bail.
                throw error
            } catch {
                lastError = error
                continue  // network error — try the next source
            }
        }

        throw LoaderError.allSourcesFailed(
            "\(network.filename): \(lastError.map { String(describing: $0) } ?? "unknown")"
        )
    }

    /// Download `network` from `source` straight to a temp file in `directory`,
    /// then return its URL (caller verifies + installs). Uses URLSession's
    /// download-to-disk path — NOT the `bytes(from:)` async byte stream, which
    /// would iterate ~100M times for the 100 MB big net.
    ///
    /// Implemented with `URLSession.downloadTask(with:completionHandler:)`
    /// bridged through `withCheckedThrowingContinuation` so the floor stays at
    /// iOS 13 / macOS 10.15 (the async `download(from:)` is iOS 15 / macOS 12).
    ///
    /// CRITICAL temp-file lifetime: `downloadTask`'s completion handler is
    /// handed a URL in the system temp dir that the OS DELETES the instant the
    /// handler returns. So the handler must SYNCHRONOUSLY relocate that file to
    /// our own stable `.part` URL (alongside the destination) BEFORE resuming
    /// the continuation, and resume with the stable URL — never the OS temp URL,
    /// which would already be gone by the time the caller touches it.
    private func downloadToTemp(
        _ network: StockfishNetworks.Network,
        from source: Source,
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> URL {
        let url = source.url(for: network.filename)

        // Our stable destination for the bytes: a hidden `.part` alongside the
        // final file so the later install move stays on one volume. Computed up
        // front so the @Sendable completion handler can capture it as a plain
        // value (keeping it Swift-6 concurrency-clean — no `self` capture).
        let tempURL = directory.appendingPathComponent(
            ".\(network.filename).\(UUID().uuidString).part"
        )

        let taskBox = StockfishDownloadTaskBox()
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url) { downloadedURL, response, error in
                // Transport-level failure (no file produced).
                if let error {
                    if taskBox.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let downloadedURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                // HTTP status check — same behavior as before: non-2xx → throw.
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                // RELOCATE NOW, synchronously, before this handler returns —
                // the OS deletes `downloadedURL` as soon as we return. Move
                // first (fast, same-volume); fall back to copy if the system
                // temp dir is on a different volume than `directory`.
                let fm = FileManager.default
                try? fm.removeItem(at: tempURL)
                do {
                    do {
                        try fm.moveItem(at: downloadedURL, to: tempURL)
                    } catch {
                        try fm.copyItem(at: downloadedURL, to: tempURL)
                    }
                } catch {
                    continuation.resume(throwing: LoaderError.fileSystem(
                        "could not stage download for \(network.filename): \(error.localizedDescription)"
                    ))
                    return
                }

                // Coarse progress: without a URLSessionDownloadDelegate we can't
                // surface byte-by-byte counts, so report completion only.
                if let progress {
                    let total = (response?.expectedContentLength ?? -1) > 0
                        ? response!.expectedContentLength
                        : Progress.unknownTotalBytes
                    progress(Progress(file: network.filename,
                                      bytesDownloaded: max(total, 0),
                                      totalBytes: total))
                }

                // Resume with the STABLE url; `downloadedURL` is about to vanish.
                continuation.resume(returning: tempURL)
            }
                taskBox.installAndResume(task)
            }
        }, onCancel: {
            taskBox.cancel()
        })
    }

    // MARK: - Verification

    /// Compute the file's SHA-256, hex-encode it, take the first 12 chars, and
    /// compare against the filename's encoded prefix. This is the same check
    /// Stockfish itself performs on its nets.
    private func verify(fileAt url: URL, matches network: StockfishNetworks.Network) throws -> Bool {
        let expected = network.shaPrefix
        guard !expected.isEmpty else {
            throw LoaderError.invalidNetworkName(network.filename)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        // `closeFile()` / `readData(ofLength:)` are the classic (non-throwing)
        // FileHandle APIs available since iOS 13.0 / macOS 10.15.0. Their
        // throwing replacements `close()` / `read(upToCount:)` are 10.15.4-only,
        // which is above this package's 10.15.0 floor.
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.hasPrefix(expected)
    }
}
