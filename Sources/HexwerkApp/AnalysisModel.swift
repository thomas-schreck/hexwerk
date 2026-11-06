import AppKit
import Combine
import HexwerkCore
import HexwerkMagic

/// Entropy profile and byte histogram of the file or selection (SPEC FR-9.1).
@MainActor
final class AnalysisModel: ObservableObject {
    @Published private(set) var stats: ByteStats?
    @Published private(set) var profile: EntropyProfile?
    @Published private(set) var end: UInt64 = 0
    @Published private(set) var running = false
    @Published private(set) var progress = 0.0
    @Published private(set) var stale = false
    @Published var hoverBlock: Int?
    @Published var hoverByte: Int?
    @Published var logScale = true

    private var task: Task<Void, Never>?

    // File type (FR-10.x): libmagic description, MIME, own signature.
    @Published private(set) var typeDescription: String?
    @Published private(set) var mime: String?
    @Published private(set) var signature: SignatureHit?
    @Published private(set) var embedded: [SignatureHit]?
    @Published private(set) var embeddedRunning = false
    private var embeddedTask: Task<Void, Never>?

    func detectType(_ snap: Snapshot) {
        Task.detached(priority: .utility) { [weak self] in
            let d = Magic.describe(snap), m = Magic.mime(snap), s = FileSignatures.detect(snap).first
            await MainActor.run {
                self?.typeDescription = d
                self?.mime = m
                self?.signature = s
            }
        }
    }

    func scanEmbedded(_ snap: Snapshot) {
        embeddedTask?.cancel()
        embeddedRunning = true
        embeddedTask = Task.detached(priority: .userInitiated) { [weak self] in
            let hits = FileSignatures.scanEmbedded(snap, isCancelled: { Task.isCancelled })
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.embedded = hits
                self.embeddedRunning = false
            }
        }
    }

    /// About one block per point of a typical sidebar chart.
    nonisolated static let blocks = 512

    func run(_ snap: Snapshot, range: Range<UInt64>?) {
        task?.cancel()
        running = true
        progress = 0
        let r = range ?? 0 ..< snap.count
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var last = Date.distantPast
            let result = Analysis.analyze(snap, range: r, blocks: Self.blocks, isCancelled: { Task.isCancelled }) { p in
                // Throttle UI updates to ~10/s.
                guard Date().timeIntervalSince(last) > 0.1 else { return }
                last = Date()
                Task { @MainActor [weak self] in self?.progress = p }
            }
            await MainActor.run {
                guard let self, let result, !Task.isCancelled else { return }
                self.running = false
                self.stats = result.0
                self.profile = result.1
                self.end = r.upperBound
                self.stale = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }

    func contentChanged() { if stats != nil { stale = true } }
}
