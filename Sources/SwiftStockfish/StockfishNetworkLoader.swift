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

import Foundation
import CryptoKit

/// Ensures a directory holds exactly the NNUE networks the engine requires.
///
/// ```swift
/// let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")
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
        self.networks = networks
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Make `directory` contain EXACTLY the required networks.
    ///
    /// Steps, in order:
    ///   1. Ensure `directory` exists.
    ///   2. PRUNE: delete any `nn-*.nnue` in `directory` that is not in the
    ///      required set (leftovers from a previous Stockfish version).
    ///   3. For each required net: keep it if present AND it passes SHA
    ///      verification; otherwise download it (trying fishtest, then GitHub),
    ///      verify it, and move it atomically into place.
    ///
    /// A present, valid net is never re-downloaded (idempotent). Downloads go
    /// to a temp file that is verified before replacing the destination, so a
    /// failed/aborted download never leaves a corrupt net behind.
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

        let requiredNames = Set(networks.map(\.filename))

        // 2. Prune any nn-*.nnue that isn't required.
        try pruneStaleNetworks(in: directory, keeping: requiredNames, fm: fm)

        // 3. Ensure each required net.
        for network in networks {
            guard !network.shaPrefix.isEmpty else {
                throw LoaderError.invalidNetworkName(network.filename)
            }
            let destination = directory.appending(path: network.filename)

            // Keep it if present and valid.
            if fm.fileExists(atPath: destination.path),
               (try? verify(fileAt: destination, matches: network)) == true {
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

    private func pruneStaleNetworks(
        in directory: URL,
        keeping requiredNames: Set<String>,
        fm: FileManager
    ) throws {
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            // A directory we just created should be enumerable; treat a failure
            // here as fatal so we don't silently skip pruning.
            throw LoaderError.fileSystem("could not enumerate \(directory.path): \(error.localizedDescription)")
        }

        for url in contents {
            let name = url.lastPathComponent
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

                // Verify before moving into place.
                guard try verify(fileAt: tempURL, matches: network) else {
                    lastError = LoaderError.checksumMismatch(network.filename)
                    continue  // try the next source
                }

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

    /// Stream `network` from `source` into a temp file in `directory`, reporting
    /// per-byte progress. Returns the temp file URL (caller verifies + moves).
    private func downloadToTemp(
        _ network: StockfishNetworks.Network,
        from source: Source,
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> URL {
        let url = source.url(for: network.filename)
        let (bytes, response) = try await session.bytes(from: url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let totalBytes = response.expectedContentLength > 0
            ? response.expectedContentLength
            : Progress.unknownTotalBytes

        // Temp file alongside the destination so the final move stays on one
        // volume (a cross-volume move would copy, defeating atomicity).
        let tempURL = directory.appending(path: ".\(network.filename).\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            throw LoaderError.fileSystem("could not open temp file for \(network.filename)")
        }
        defer { try? handle.close() }

        var downloaded: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(Progress(file: network.filename, bytesDownloaded: downloaded, totalBytes: totalBytes))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
            progress?(Progress(file: network.filename, bytesDownloaded: downloaded, totalBytes: totalBytes))
        }

        return tempURL
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
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.hasPrefix(expected)
    }
}
