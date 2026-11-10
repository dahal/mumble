import AVFoundation
import MumbleReader
import MumbleTTS
import Observation
import PDFKit

/// One open book: its sentences, where you are, and the narration pipeline. Synthesizes a few
/// sentences ahead of playback, so there are no gaps, and highlights what's being read.
@MainActor @Observable
final class ReadingSession {
    let bookID: UUID
    let document: PDFDocument?
    private(set) var utterances: [Utterance] = []
    /// The sentence being read (or to read next when paused).
    private(set) var current = 0
    private(set) var isPlaying = false
    private(set) var isLoadingText = true
    private(set) var problem: String?
    /// Set while the voice model downloads or loads.
    private(set) var voiceStatus: String?
    var followAlong = true
    /// Bumped when the PDF view should scroll to the current sentence even if follow-along is off.
    private(set) var revealRequest = 0

    @ObservationIgnored private weak var books: BooksController?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var producer: Task<Void, Never>?
    /// Incremented on every stop/seek so callbacks from older audio are ignored.
    @ObservationIgnored private var generation = 0
    /// Sentence indices scheduled on the player and not yet finished.
    private var queued: [Int] = []
    @ObservationIgnored private var characterOffsets: [Int] = []
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    /// Dev tools play silently (the audio still runs through the engine in real time).
    static var muted = false
    /// How many sentences to synthesize ahead of the one playing.
    private static let lookahead = 3
    private static let format = AVAudioFormat(standardFormatWithSampleRate: Narrator.sampleRate, channels: 1)!
    /// Rough narration rate at 1×, for "time left".
    private static let charactersPerSecond = 15.0

    init(book: Book, url: URL, books: BooksController) {
        bookID = book.id
        self.url = url
        self.books = books
        document = PDFDocument(url: url)
        current = book.finished ? 0 : book.position
        loadText()
    }

    var isBuffering: Bool { isPlaying && queued.isEmpty }
    var currentUtterance: Utterance? { utterances.indices.contains(current) ? utterances[current] : nil }
    var pageCount: Int { document?.pageCount ?? 0 }
    var currentPage: Int { currentUtterance?.page ?? 0 }
    var progress: Double { utterances.isEmpty ? 0 : Double(current) / Double(utterances.count) }

    /// Seconds of narration left at the current speed.
    var secondsLeft: Double {
        guard let total = characterOffsets.last, characterOffsets.indices.contains(current) else { return 0 }
        let speed = Double(books?.speed ?? 1)
        return Double(total - characterOffsets[current]) / (Self.charactersPerSecond * speed)
    }

    // MARK: Text

    private func loadText() {
        let url = url
        Task {
            let pages: [String]? = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: url) else { return nil }
                return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            }.value
            guard let pages else {
                problem = "This PDF couldn't be opened."
                isLoadingText = false
                return
            }
            let utterances = await Task.detached(priority: .userInitiated) { BookText.utterances(pages: pages) }.value
            self.utterances = utterances
            var offsets = [0]
            offsets.reserveCapacity(utterances.count + 1)
            for u in utterances { offsets.append(offsets[offsets.count - 1] + u.text.count) }
            characterOffsets = offsets
            if current >= utterances.count { current = 0 }
            isLoadingText = false
            if utterances.isEmpty {
                problem = "This PDF has no text to read aloud. It may be scanned pages (images of text)."
            }
            books?.update(bookID) { $0.utteranceCount = utterances.count }
            revealRequest += 1
            AppLog.info("Book opened: \(pages.count) pages, \(utterances.count) sentences")
        }
    }

    // MARK: Controls

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !utterances.isEmpty else { return }
        if current >= utterances.count { current = 0 }
        // Resume buffered audio in place; otherwise (first play, or settings changed) start fresh.
        if !queued.isEmpty, let engine, engine.isRunning {
            isPlaying = true
            player.play()
        } else {
            start(at: current)
        }
    }

    func pause() {
        isPlaying = false
        player.pause()
        savePosition()
    }

    func next() { seek(to: min(current + 1, max(utterances.count - 1, 0))) }

    func previous() { seek(to: max(current - 1, 0)) }

    /// Read from a sentence (a click in the text, the scrubber, or skip buttons).
    func seek(to index: Int) {
        guard utterances.indices.contains(index) else { return }
        if isPlaying {
            start(at: index)
        } else {
            invalidate()
            current = index
            savePosition()
        }
        revealRequest += 1
    }

    /// The sentence at a character of a page, for "Read from here".
    func utterance(page: Int, character: Int) -> Int? {
        var best: Int?
        for u in utterances {
            for span in u.spans where span.page == page {
                if character >= span.location, character < span.location + span.length { return u.index }
                if span.location <= character { best = u.index }
            }
            if u.page > page { break }
        }
        return best ?? utterances.first { $0.page >= page }?.index
    }

    /// Voice or speed changed: re-synthesize from the current sentence.
    func settingsChanged() {
        if isPlaying { start(at: current) } else { invalidate() }
    }

    func close() {
        invalidate()
        isPlaying = false
        engine?.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        savePosition()
    }

    // MARK: Pipeline

    private func start(at index: Int) {
        invalidate()
        current = index
        isPlaying = true
        problem = nil
        do {
            try startEngine()
        } catch {
            problem = "Audio output failed: \(error.localizedDescription)"
            isPlaying = false
            return
        }
        player.play()
        let generation = generation
        producer = Task { [weak self] in await self?.produce(from: index, generation: generation) }
    }

    /// Stops audio and forgets anything scheduled.
    private func invalidate() {
        generation += 1
        producer?.cancel()
        producer = nil
        if engine != nil { player.stop() }
        queued = []
    }

    private func startEngine() throws {
        if engine == nil {
            let engine = AVAudioEngine()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
            if Self.muted { engine.mainMixerNode.outputVolume = 0 }
            self.engine = engine
            // Output device changed (headphones unplugged…): the engine stops; pick up where we were.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isPlaying { self.start(at: self.current) } else { self.invalidate() }
                }
            }
        }
        if let engine, !engine.isRunning { try engine.start() }
    }

    private func produce(from start: Int, generation: Int) async {
        guard let books else { return }
        if !(await books.narrator.isReady) {
            voiceStatus = "Preparing the voice… The first time, this downloads about 390 MB."
            do {
                try await books.narrator.load()
            } catch {
                guard generation == self.generation else { return }
                voiceStatus = nil
                problem = "The voice couldn't load: \(error.localizedDescription)"
                isPlaying = false
                return
            }
            voiceStatus = nil
        }
        var index = start
        while index < utterances.count, generation == self.generation {
            while queued.count >= Self.lookahead, generation == self.generation {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard generation == self.generation else { return }
            let utterance = utterances[index]
            do {
                let samples = try await books.narrator.speak(utterance.text, voice: books.voice, speed: books.speed)
                guard generation == self.generation else { return }
                schedule(samples, utterance: utterance, generation: generation)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // One bad sentence shouldn't stop the book: log it and move on.
                AppLog.error("Narration failed for sentence \(index): \(error)")
            }
            index += 1
        }
    }

    private func schedule(_ samples: [Float], utterance: Utterance, generation: Int) {
        // A beat between sentences, longer after headings.
        let pause = utterance.text.last.map { ".!?…\"”’)".contains($0) } ?? false ? 0.12 : 0.45
        let padding = Int(Narrator.sampleRate * pause)
        let frames = AVAudioFrameCount(samples.count + padding)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        (channel + samples.count).update(repeating: 0, count: padding)
        queued.append(utterance.index)
        let index = utterance.index
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(index, generation: generation) }
        }
    }

    private func finished(_ index: Int, generation: Int) {
        guard generation == self.generation else { return }
        queued.removeAll { $0 == index }
        current = index + 1
        if current >= utterances.count {
            isPlaying = false
            current = utterances.count
            books?.update(bookID) {
                $0.finished = true
                $0.position = 0
            }
            current = 0
            return
        }
        savePosition()
    }

    private func savePosition() {
        guard !utterances.isEmpty else { return }
        let position = current
        books?.update(bookID) { $0.position = position }
    }
}
