import SwiftUI
import AVKit
import Network
import YouTubeKit

/// A counter that moves every time the box's network path changes shape — a
/// VPN tunnel coming up or going down is exactly that kind of change.
///
/// googlevideo mints a playback URL for the connection that asked for it, and
/// the moment the route out of the house changes (tunnel up, tunnel down, or
/// the VPN provider rotating which exit you leave from) the URLs we remembered
/// start answering 403. Nothing in the trailer pipeline noticed: the resolved
/// URLs were cached for half an hour, so enabling a VPN could leave every
/// trailer dead until that window ran out. Stamping each cached entry with the
/// generation it was extracted under makes a path change drop them, without
/// any cache having to know what a VPN is.
enum TrailerNetworkGeneration {
    private static let lock = NSLock()
    private static var value: UInt64 = 0
    /// The shape of the last path we saw. `nil` until the first callback,
    /// which only establishes the baseline — the app didn't change networks by
    /// launching.
    private static var lastShape: String?

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let shape = TrailerNetworkGeneration.shape(of: path)
            TrailerNetworkGeneration.lock.withLock {
                guard TrailerNetworkGeneration.lastShape != shape else { return }
                if TrailerNetworkGeneration.lastShape != nil {
                    TrailerNetworkGeneration.value &+= 1
                }
                TrailerNetworkGeneration.lastShape = shape
            }
        }
        monitor.start(queue: DispatchQueue(label: "orivio.trailer.path"))
        return monitor
    }()

    /// Reading this also starts the monitor the first time, so nothing has to
    /// remember to boot it.
    static var current: UInt64 {
        _ = monitor
        return lock.withLock { value }
    }

    /// What we consider "the same network". `usesInterfaceType(.other)` is how
    /// a tunnel shows up, and the interface list catches a VPN that reconnects
    /// onto a fresh `utun` (and so, almost always, a fresh exit address).
    private static func shape(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name)/\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)|tunnel:\(path.usesInterfaceType(.other))|\(interfaces)"
    }
}

/// Resolves a YouTube video key to something AVPlayer can play. tvOS has no
/// WebKit, so the iframe embed is out — YouTubeKit extracts native streams.
///
/// YouTube only *muxes* audio+video up to ~720p; 1080p and up exist solely as
/// separate adaptive tracks (DASH), so a 1080p trailer means merging a
/// video-only and an audio-only stream into one composition.
///
/// This used to always take the single muxed URL for a fast start, which
/// capped every trailer at 720p (often 360/480p, since the muxed ladder is
/// thin). Resolution wins now: the merge is used whenever it is genuinely
/// sharper than the best muxed stream, and the muxed fast path is kept for the
/// case where it is already as good. The old objection — that merging is slow
/// to start — was mostly the merge loading its two remote assets one after the
/// other; `mergedItem` now loads them concurrently.
enum TrailerResolver {
    /// How many of TMDB's ranked trailers to try before giving up on a title.
    ///
    /// One was not enough. A trailer is a YouTube video like any other and
    /// plenty of them are geo-restricted, so the top-ranked one can be
    /// unplayable from wherever the connection comes OUT — the ordinary case
    /// when the box is on a VPN whose exit sits in another country. TMDB
    /// usually lists several (the studio's, a distributor's, a regional cut)
    /// and the ones after the first are frequently not restricted at all.
    /// Bounded because every miss costs a full extraction.
    static let maxCandidates = 3

    /// Ask YouTube for a video's streams, local extractor first and the remote
    /// extraction service after it.
    ///
    /// `.local` parses YouTube's own page, so it breaks whenever they reshape
    /// it, and it is the first thing to be handed a consent wall or a
    /// "confirm you're not a bot" interstitial when the address asking has a
    /// poor reputation — which a VPN exit, shared by however many other people
    /// sit behind it, permanently does. `.remote` never touches that page, so
    /// it is the way through.
    ///
    /// Two separate calls rather than `methods: [.local, .remote]`, for one
    /// reason the combined form does not cover: a local extraction that
    /// returns an EMPTY list without throwing satisfies the combined call,
    /// which then hands back nothing at all. Here that counts as a miss and
    /// the remote extractor still gets its turn.
    ///
    /// Note that neither form reaches the remote extractor unless YouTubeKit
    /// itself is patched — its availability pre-check parses the watch page
    /// before it walks the method list, and used to abort everything when that
    /// page was unreadable. See the ORIVIO PATCH in
    /// `Vendor/YouTubeKit/Sources/YouTubeKit/YouTube.swift`.
    private static func extractStreams(youtubeKey: String) async -> [YouTubeKit.Stream]? {
        do {
            let streams = try await YouTube(videoID: youtubeKey, methods: [.local]).streams
            if !streams.isEmpty { return streams }
            NSLog("[OrivioTrailer] local extraction returned nothing for %@ — trying remote", youtubeKey)
        } catch {
            NSLog("[OrivioTrailer] local extraction failed for %@: %@ — trying remote",
                  youtubeKey, String(describing: error))
        }
        // The hero moved on (or the page closed) and took the URLSession
        // requests with it — that is not YouTube refusing us, and the remote
        // extractor would only be cancelled the same way.
        guard !Task.isCancelled else { return nil }
        do {
            let streams = try await YouTube(videoID: youtubeKey, methods: [.remote]).streams
            return streams.isEmpty ? nil : streams
        } catch {
            NSLog("[OrivioTrailer] extraction failed for %@: %@", youtubeKey, String(describing: error))
            return nil
        }
    }

    /// The first of `candidates` that resolves to something playable, with the
    /// key it came from so a later playback failure can invalidate the right
    /// entry. Ranked best-first by TMDB; see `maxCandidates`.
    static func playerItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if let item = await playerItem(youtubeKey: key) {
                return (item, key)
            }
            NSLog("[OrivioTrailer] %@ did not resolve — trying the next trailer", key)
        }
        return nil
    }

    /// The highest-resolution natively-playable item: a merged 1080p (or
    /// better) composition when the adaptive ladder beats the muxed one,
    /// otherwise the single muxed progressive URL.
    static func playerItem(youtubeKey: String) async -> AVPlayerItem? {
        guard let streams = await extractStreams(youtubeKey: youtubeKey) else { return nil }
        // isNativelyPlayable keeps only codecs AVPlayer decodes (H.264/AAC),
        // dropping VP9/AV1 webm — so the "highest" video-only is 1080p H.264.
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        // Merge only when it actually buys resolution. When YouTube happens to
        // mux the same height (or better), the single URL is both sharper-
        // equal and faster to start, so there is nothing to gain.
        // Apple TV HD: never merge. The composition is a second connection +
        // two moov round trips + an AVMutableComposition on a 2-core, 2 GB,
        // 1080p box, to lift a TRAILER from 720p — the muxed single URL is
        // the right trade there.
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (muxed best was %dp)",
                  youtubeKey, adaptiveHeight, muxedHeight)
            return merged
        }
        if let muxed {
            NSLog("[OrivioTrailer] %@: muxed %dp", youtubeKey, muxedHeight)
            return budgeted(AVPlayerItem(asset: asset(for: muxed.url)))
        }
        // No muxed stream at all — merge whatever the adaptive ladder offers,
        // even if the comparison above didn't favour it.
        if let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (no muxed stream)", youtubeKey, adaptiveHeight)
            return merged
        }
        return nil
    }

    /// Bound AVPlayer's read-ahead on the constrained boxes. With no
    /// preference set it buffers at its own appetite — fine on 4 GB, but a
    /// trailer is a MUTED PREVIEW playing beside a browsing UI on the 2–3 GB
    /// boxes, and its buffer competes with poster decodes for the same RAM.
    @discardableResult
    private static func budgeted(_ item: AVPlayerItem) -> AVPlayerItem {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            item.preferredForwardBufferDuration = 10
        }
        return item
    }

    /// googlevideo playback URLs are tied to the InnerTube CLIENT that
    /// extracted them (the `c=` query param) — YouTube serves them only to a
    /// matching User-Agent, and AVPlayer's default UA gets "Cannot Open"
    /// (-11828). Rebuild each request with the extracting client's UA.
    private static func asset(for url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent(for: url)]
        ])
    }

    /// The User-Agent googlevideo expects for a URL — the one matching the
    /// InnerTube client that minted it (see `asset(for:)`).
    fileprivate static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value
        let userAgent: String
        switch client {
        case "ANDROID_VR":
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case "ANDROID":
            userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        case "ANDROID_MUSIC":
            userAgent = "com.google.android.apps.youtube.music/5.16.51 (Linux; U; Android 11) gzip"
        case "ANDROID_EMBEDDED_PLAYER":
            userAgent = "com.google.android.youtube/18.11.34 (Linux; U; Android 11) gzip"
        // The clients below were missing, and every one of them is an APP
        // client — the kind googlevideo actually checks the agent for. They
        // are not exotic: the local extractor falls through to them when the
        // first choice is refused, and the REMOTE extractor (the one that
        // takes over whenever YouTube won't talk to this address directly,
        // which is the normal state of affairs from a VPN exit) hands back
        // whichever client got through. Extraction then succeeded and
        // playback died with "Cannot Open" — a trailer that resolves and
        // never starts. Agents lifted from YouTubeKit's own client table so
        // they match the request that minted the URL.
        case "IOS":
            userAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case "IOS_MUSIC":
            userAgent = "com.google.ios.youtubemusic/5.21 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)"
        case "TVHTML5":
            userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER":
            userAgent = "Mozilla/5.0"
        default:
            // WEB, VISIONOS, MWEB, WEB_EMBEDDED_PLAYER and friends are
            // browser clients — a browser agent is the matching one.
            userAgent = "Mozilla/5.0"
        }
        return userAgent
    }

    /// Merge a remote video-only and audio-only track into one playable asset.
    ///
    /// `@MainActor` because `AVPlayerItem.init(asset:)` is main-actor isolated
    /// in the current SDK and this was calling it from a nonisolated async
    /// context — a warning today and a hard error under Swift 6. Nothing is
    /// blocked by the annotation: every expensive step in here is an `await`
    /// on AVFoundation's own loaders, which suspend rather than spin, and the
    /// one caller (`playerItem`) is already reached from a `.task` on main.
    @MainActor
    private static func mergedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        // STREAM IT. The composition below needs both tracks' complete sample
        // tables, and YouTube's adaptive files are fragmented MP4s — so
        // AVFoundation downloads the ENTIRE video file before it will hand the
        // track over: 10.2s for a 1080p trailer on a link doing 5 MB/s
        // (measured 2026-10-02). Since YouTube stopped serving muxed streams,
        // every trailer went through that wait, and the Home hero gives up at
        // 12s — so trailers "didn't load". The same two files described as an
        // HLS presentation start from their first fragment instead.
        if let streamed = await DashAsHLS.item(video: video, audio: audio) {
            return budgeted(streamed)
        }
        let videoAsset = asset(for: video)
        let audioAsset = asset(for: audio)
        let composition = AVMutableComposition()
        do {
            // CONCURRENTLY. Each of these is a network round trip for the
            // asset's moov atom, and running them one after another is most of
            // what made a merged trailer slower to open than a muxed one —
            // which is why the muxed stream (and its 720p ceiling) used to be
            // preferred outright.
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)

            guard let vTrack = try await videoTracks.first else { return nil }
            // YouTube's adaptive (DASH) files load at TWICE their real length:
            // measured on itag 137/140, `dur=146.145` in the URL against an
            // asset duration of 292.29, every key tried. The trailer played to
            // its real end and the composition then ran on over nothing for
            // the same time again — a frozen picture and a spinner half way
            // through the timeline. The URL's own `dur` is the real length.
            //
            // AND ASKING FOR THE ASSET'S DURATION IS WHAT MADE TRAILERS NOT
            // LOAD. These are fragmented MP4s: AVFoundation answers `.duration`
            // (and an audio track's `.timeRange`) by walking the fragments, and
            // that walk took the merge to 10-11 SECONDS (measured 2026-10-02,
            // `-trailerSelfTest`) — past the Home hero's 12s give-up, so the
            // hero trailer never started. The declared `dur` is the real
            // length; the slow load runs only when a URL carries none.
            let duration: CMTime
            if let declared = declaredDuration(of: video) {
                duration = declared
            } else {
                duration = try await videoAsset.load(.duration)
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try vComp?.insertTimeRange(range, of: vTrack, at: .zero)
            if let aTrack = try await audioTracks.first {
                let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                // The audio track can be a hair shorter than the video; clamp
                // so `insertTimeRange` can't throw on the tail and lose the
                // whole composition (and with it the 1080p path).
                let audioDuration: CMTime
                if let declared = declaredDuration(of: audio) {
                    audioDuration = declared
                } else {
                    audioDuration = try await aTrack.load(.timeRange).duration
                }
                let audioRange = CMTimeRange(start: .zero,
                                             duration: min(range.duration, audioDuration))
                try aComp?.insertTimeRange(audioRange, of: aTrack, at: .zero)
            }
            return budgeted(AVPlayerItem(asset: composition))
        } catch {
            NSLog("[OrivioTrailer] merge failed: %@", String(describing: error))
            return nil
        }
    }

    /// The length a googlevideo URL declares in its `dur` query item
    /// (seconds), or nil when it has none.
    private static func declaredDuration(of url: URL) -> CMTime? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "dur" })?.value,
              let seconds = Double(raw), seconds > 0 else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: 1000)
    }

    /// The backdrop trailer behind Home's hero and the Detail page.
    ///
    /// Resolution is chosen the same way `playerItem` chooses it — the merged
    /// adaptive pair when it beats the muxed ladder, which in practice means
    /// 1080p instead of 720p or worse. This used to take the muxed URL
    /// unconditionally "because the preview sits behind heavy scrims", but the
    /// Detail page plays this same item large and un-muted, so the ceiling was
    /// visible there.
    ///
    /// The client-matched User-Agent is baked in — see `asset(for:)`.
    /// Extraction is the slow step (seconds, the remote fallback especially),
    /// and the playback URLs it yields stay valid for hours — so remember
    /// them, and a title the browse comes BACK to starts its preview almost
    /// immediately instead of re-paying the extraction every visit.
    /// Guarded by `backdropCacheLock`: `backdropItem` is nonisolated async,
    /// so Home's hero layer and a Detail page opening at the same moment
    /// mutate these two dictionaries concurrently off the main actor —
    /// unsynchronised Dictionary mutation, i.e. a corrupted hash table.
    private static let backdropCacheLock = NSLock()

    /// What extraction settled on for one key. Both URLs are remembered, not
    /// just one, because the 1080p choice is a PAIR of adaptive streams —
    /// and `muxedFallback` keeps a single self-contained URL around so a
    /// failed merge degrades to a lower-resolution trailer WITH audio rather
    /// than to a silent one.
    private struct BackdropChoice {
        let video: URL
        let audio: URL?
        let muxedFallback: URL?
        let height: Int
        let at: Date
        /// The network path these URLs were minted for — see
        /// `TrailerNetworkGeneration`.
        let generation: UInt64
    }
    private static var backdropURLCache: [String: BackdropChoice] = [:]
    /// Conservative slice of googlevideo's ~6h link lifetime.
    private static let backdropURLTTL: TimeInterval = 30 * 60

    /// Keys whose extraction just failed, and when.
    ///
    /// Successes were remembered and failures were not, which is exactly
    /// backwards for load: every time the viewer's focus passed back over a
    /// title we could not extract, we asked YouTube again. Browsing a row of
    /// them is then a burst of failing requests from one address — and a burst
    /// is what earns a bot-check page, whose unparseable HTML is itself the
    /// `regexMatchError` that made the extraction fail. The retry storm feeds
    /// the thing causing it. Short enough that a genuinely transient failure
    /// costs one browse, long enough to stop the storm.
    private static var backdropFailureCache: [String: (at: Date, generation: UInt64)] = [:]
    private static let backdropFailureTTL: TimeInterval = 10 * 60
    /// The generation both dictionaries were last swept for.
    private static var cachedGeneration: UInt64 = 0

    /// Drop everything remembered for a network we are no longer on. Called
    /// under `backdropCacheLock`.
    private static func purgeIfPathChangedLocked(_ generation: UInt64) {
        guard cachedGeneration != generation else { return }
        cachedGeneration = generation
        backdropURLCache.removeAll()
        // The failures go too, and that is the point: a burst of them recorded
        // while a tunnel was coming up would otherwise keep every one of those
        // titles trailer-less for ten more minutes after it settled.
        backdropFailureCache.removeAll()
        NSLog("[OrivioTrailer] network path changed — dropped the resolved-URL cache")
    }

    /// Remember that a key wouldn't extract — but only if the network we
    /// failed on is still the network we are on. A slow extraction can finish
    /// AFTER a tunnel came up, and a failure earned on the old path must not
    /// be allowed to sit out the next ten minutes on the new one.
    private static func rememberFailure(youtubeKey: String, generation: UInt64) {
        // A cancelled extraction is not a failed one. Every hero rest starts a
        // resolve and stepping along a row cancels each of them in turn, so
        // recording those as failures branded a whole row trailer-less for ten
        // minutes just for browsing past it — and the slower extraction gets
        // (a VPN's remote fallback being the slow case), the more of the row
        // it swallowed.
        guard !Task.isCancelled else { return }
        backdropCacheLock.withLock {
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == generation else { return }
            backdropFailureCache[youtubeKey] = (Date(), generation)
        }
    }

    /// Forget what we resolved for a key. The caller is a player that got a
    /// dead URL: a cached googlevideo link minted on a different path answers
    /// 403 rather than video, and without this the next visit to the title
    /// would cheerfully hand out the same dead link for the rest of the TTL.
    static func invalidate(youtubeKey: String) {
        backdropCacheLock.withLock {
            backdropURLCache.removeValue(forKey: youtubeKey)
            // Not a failure to EXTRACT — re-extracting is exactly what should
            // happen next — so the failure cache must not pick it up either.
            backdropFailureCache.removeValue(forKey: youtubeKey)
        }
    }

    /// The first of `candidates` that resolves, with the key it came from.
    /// See `maxCandidates` for why more than one is tried.
    static func backdropItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if let item = await backdropItem(youtubeKey: key) {
                return (item, key)
            }
            NSLog("[OrivioTrailer] backdrop %@ did not resolve — trying the next trailer", key)
        }
        return nil
    }

    static func backdropItem(youtubeKey: String) async -> AVPlayerItem? {
        let generation = TrailerNetworkGeneration.current
        let (cachedHit, cachedFailure) = backdropCacheLock.withLock { () -> (BackdropChoice?, (at: Date, generation: UInt64)?) in
            purgeIfPathChangedLocked(generation)
            return (backdropURLCache[youtubeKey], backdropFailureCache[youtubeKey])
        }
        if let hit = cachedHit,
           Date().timeIntervalSince(hit.at) < backdropURLTTL {
            return await backdropPlayerItem(hit)
        }
        if let cachedFailure,
           Date().timeIntervalSince(cachedFailure.at) < backdropFailureTTL {
            return nil
        }
        let extractStart = Date()
        guard let streams = await extractStreams(youtubeKey: youtubeKey) else {
            PlayerProbe.event("trailer", String(format: "%@ extraction FAILED after %.1fs",
                                                youtubeKey, Date().timeIntervalSince(extractStart)))
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            return nil
        }
        PlayerProbe.event("trailer", String(format: "%@ extracted %d streams in %.1fs",
                                            youtubeKey, streams.count, Date().timeIntervalSince(extractStart)))
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        let choice: BackdropChoice
        // Apple TV HD: same rule as `playerItem` — the muxed single URL over
        // a two-connection composition merge (see the note there).
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive {
            // 1080p: video-only plus its own audio track, merged at play time.
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: muxed?.url,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else if let muxed {
            choice = BackdropChoice(video: muxed.url, audio: nil, muxedFallback: muxed.url,
                                    height: muxedHeight, at: Date(), generation: generation)
        } else if let adaptive {
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: nil,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else {
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            return nil
        }
        backdropCacheLock.withLock {
            // The path could have moved under us during a multi-second
            // extraction; only keep what still belongs to the current one.
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == choice.generation else { return }
            backdropURLCache[youtubeKey] = choice
        }
        NSLog("[OrivioTrailer] backdrop %@: %dp (%@)", youtubeKey, choice.height,
              choice.audio == nil ? "muxed" : "merged")
        return await backdropPlayerItem(choice)
    }

    /// Build the item for a resolved backdrop choice.
    ///
    /// `@MainActor` for the same reason `mergedItem` is: `AVPlayerItem.init`
    /// is main-actor isolated. A merge that fails falls back to the muxed URL
    /// — a lower-resolution trailer that still has SOUND, which matters
    /// because the Detail page un-mutes this item.
    @MainActor
    private static func backdropPlayerItem(_ choice: BackdropChoice) async -> AVPlayerItem? {
        guard let audio = choice.audio else {
            return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
        }
        let mergeStart = Date()
        if let merged = await mergedItem(video: choice.video, audio: audio) {
            PlayerProbe.event("trailer", String(format: "merged %dp in %.1fs",
                                                choice.height, Date().timeIntervalSince(mergeStart)))
            return merged
        }
        PlayerProbe.event("trailer", String(format: "merge FAILED after %.1fs", Date().timeIntervalSince(mergeStart)))
        if let fallback = choice.muxedFallback {
            NSLog("[OrivioTrailer] backdrop merge failed — falling back to the muxed stream")
            return budgeted(AVPlayerItem(asset: asset(for: fallback)))
        }
        return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
    }
}

/// Two DASH on-demand files (video-only + audio-only fragmented MP4, the way
/// YouTube serves everything above 360p) presented to AVPlayer as one HLS
/// stream.
///
/// Each file opens with its init header (`ftyp` + `moov`) and a `sidx` index
/// giving every fragment's byte size and duration. That is exactly what an
/// HLS media playlist with `EXT-X-MAP` + `EXT-X-BYTERANGE` describes, so the
/// playlists are generated from the first 64 KB of each file and served from
/// memory through a resource loader; the media itself is fetched by AVPlayer
/// straight from googlevideo, fragment by fragment, starting at once.
enum DashAsHLS {
    fileprivate static let scheme = "orivio-dash"

    /// nil whenever either file doesn't parse as expected — the caller then
    /// takes the composition path, so nothing is lost by trying.
    @MainActor
    static func item(video: URL, audio: URL) async -> AVPlayerItem? {
        async let videoHead = head(of: video)
        async let audioHead = head(of: audio)
        guard let v = await videoHead.flatMap(parse), let a = await audioHead.flatMap(parse) else {
            return nil
        }
        let master = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=\(v.bandwidth + a.bandwidth),AUDIO=\"a\"",
            "video.m3u8",
        ].joined(separator: "\n") + "\n"
        let loader = PlaylistLoader(playlists: [
            "master.m3u8": Data(master.utf8),
            "video.m3u8": Data(playlist(for: video, v).utf8),
            "audio.m3u8": Data(playlist(for: audio, a).utf8),
        ])
        guard let url = URL(string: "\(scheme)://\(UUID().uuidString)/master.m3u8") else { return nil }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": TrailerResolver.userAgent(for: video)]
        ])
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader does not keep its delegate alive; the asset does.
        objc_setAssociatedObject(asset, &PlaylistLoader.associationKey, loader, .OBJC_ASSOCIATION_RETAIN)
        return AVPlayerItem(asset: asset)
    }

    private struct Layout {
        let initLength: Int
        let segments: [(offset: Int, size: Int, seconds: Double)]
        let bandwidth: Int
    }

    private static func head(of url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue(TrailerResolver.userAgent(for: url), forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
        return data
    }

    /// Top-level boxes: the init header ends with `moov`; `sidx` lists the
    /// fragments that follow it.
    private static func parse(_ data: Data) -> Layout? {
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> Int {
            guard i >= 0, i + 4 <= bytes.count else { return -1 }
            return Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        func u64(_ i: Int) -> Int {
            let high = u32(i), low = u32(i + 4)
            return high < 0 || low < 0 ? -1 : high << 32 | low
        }
        var offset = 0
        var moovEnd = -1
        while offset + 8 <= bytes.count {
            var size = u32(offset)
            var header = 8
            if size == 1 { size = u64(offset + 8); header = 16 }
            guard size >= header else { return nil }
            let type = String(bytes: bytes[(offset + 4) ..< (offset + 8)], encoding: .ascii) ?? ""
            if type == "moov" { moovEnd = offset + size }
            if type == "sidx" {
                // Must be wholly inside what was fetched.
                guard moovEnd > 0, offset + size <= bytes.count else { return nil }
                var p = offset + header
                let version = bytes[p]
                p += 8                           // version/flags, reference_ID
                let timescale = u32(p); p += 4
                guard timescale > 0 else { return nil }
                let firstOffset: Int
                if version == 0 { firstOffset = u32(p + 4); p += 8 } else { firstOffset = u64(p + 8); p += 16 }
                guard firstOffset >= 0, p + 4 <= offset + size else { return nil }
                p += 2                           // reserved
                let count = Int(bytes[p]) << 8 | Int(bytes[p + 1]); p += 2
                guard p + count * 12 <= offset + size else { return nil }
                var cursor = offset + size + firstOffset
                var segments: [(offset: Int, size: Int, seconds: Double)] = []
                var totalBytes = 0
                var totalSeconds = 0.0
                for _ in 0 ..< count {
                    let reference = u32(p)
                    let duration = u32(p + 4)
                    p += 12
                    // reference_type 1 is a nested index, not media — not used
                    // by YouTube's on-demand files and not supported here.
                    guard reference > 0, reference & 0x8000_0000 == 0, duration > 0 else { return nil }
                    let length = reference & 0x7FFF_FFFF
                    let seconds = Double(duration) / Double(timescale)
                    segments.append((cursor, length, seconds))
                    cursor += length
                    totalBytes += length
                    totalSeconds += seconds
                }
                guard !segments.isEmpty, totalSeconds > 0 else { return nil }
                return Layout(initLength: moovEnd, segments: segments,
                              bandwidth: max(Int(Double(totalBytes * 8) / totalSeconds * 1.5), 64_000))
            }
            offset += size
        }
        return nil
    }

    private static func playlist(for url: URL, _ layout: Layout) -> String {
        let target = Int((layout.segments.map(\.seconds).max() ?? 10).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(layout.initLength)@0\"",
        ]
        for segment in layout.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.seconds))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Serves the three generated playlists; every media request is a normal
    /// https fetch AVPlayer makes itself.
    private final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
        nonisolated(unsafe) static var associationKey: UInt8 = 0
        let queue = DispatchQueue(label: "orivio.dash-hls")
        private let playlists: [String: Data]

        init(playlists: [String: Data]) { self.playlists = playlists }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let url = loadingRequest.request.url, url.scheme == DashAsHLS.scheme,
                  let body = playlists[url.lastPathComponent] else { return false }
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(body.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
            return true
        }
    }
}

#if DEBUG
extension TrailerResolver {
    /// Dev-only: `-trailerSelfTest <youtubeKey> [<key>…]` runs the real backdrop
    /// path — extraction, stream choice, merge, AVPlayer — and logs how long
    /// each step took and whether frames actually started, under
    /// "OrivioTrailerTest". TMDB is not involved, so it needs no API key.
    static func runSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-trailerSelfTest") else { return }
        let keys = args[(flag + 1)...].prefix { !$0.hasPrefix("-") }
        Task { @MainActor in
            for key in keys {
                let t0 = Date()
                guard let item = await backdropItem(youtubeKey: key) else {
                    NSLog("[OrivioTrailerTest] %@: NO ITEM after %.1fs", key, Date().timeIntervalSince(t0))
                    continue
                }
                NSLog("[OrivioTrailerTest] %@: item after %.1fs", key, Date().timeIntervalSince(t0))
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.play()
                var verdict = "never played"
                for _ in 0 ..< 40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if item.status == .failed {
                        verdict = "FAILED: \(String(describing: item.error))"
                        break
                    }
                    if player.timeControlStatus == .playing, player.currentTime().seconds > 1 {
                        verdict = String(format: "PLAYING at %.1fs (size %.0fx%.0f)",
                                         player.currentTime().seconds,
                                         item.presentationSize.width, item.presentationSize.height)
                        break
                    }
                }
                NSLog("[OrivioTrailerTest] %@: %@ — %.1fs from start", key, verdict,
                      Date().timeIntervalSince(t0))
                player.pause()
            }
        }
    }
}
#endif

/// A bare `AVPlayerLayer` with no transport chrome — used to play a trailer
/// silently behind the Detail hero. `.resizeAspectFill` so it fills the header
/// like the still backdrop it replaces.
struct BackdropVideoView: UIViewRepresentable {
    /// Optional so a host can keep the layer MOUNTED across previews and just
    /// swap what plays in it. Adding and removing this view mid-browse is a
    /// view-tree structural change, and the focus engine re-resolves on those
    /// — on Home that landed while the viewer was stepping through a row and
    /// left the focus lift stranded on the card they had already left.
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        // Decoration only. Inserting an interactive UIView into the hierarchy
        // makes the focus engine re-resolve, and on the detail page that threw
        // focus off Play and onto the synopsis the moment the backdrop trailer
        // started — the page appeared to grab the highlight on its own a
        // second after it opened. Same rule as the hero artwork.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen trailer playback. Resolves the YouTube key, then plays through
/// the native tvOS `VideoPlayer` transport. Menu (back) dismisses.
struct TrailerPlayerView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let trailer: TMDBService.Trailer
    /// Every trailer TMDB ranked for this title, best first. The one that was
    /// pressed leads; the rest are there because a geo-restricted first choice
    /// shouldn't be the end of it — see `TrailerResolver.maxCandidates`.
    var alternates: [String] = []

    @State private var player: AVPlayer?
    @State private var failed = false

    private var candidates: [String] {
        [trailer.youtubeKey] + alternates.filter { $0 != trailer.youtubeKey }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // Fully release on dismiss: pausing alone leaves the player
                    // registered as the system "Now Playing" item, so pressing
                    // Play/Pause later summons the tvOS transport overlay over
                    // whatever screen you're on. Clearing the item drops it.
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                    }
            } else if failed {
                OrivioEmptyState(
                    icon: "play.slash.fill",
                    title: "Trailer unavailable",
                    message: "This trailer couldn't be loaded. Press Menu to go back."
                )
            } else {
                OrivioLoadingView(label: "Loading trailer")
            }
        }
        .onExitCommand { dismiss() }
        // Release on the CONTAINER, not the VideoPlayer branch: dismissing
        // while "Loading trailer" is still up means the VideoPlayer (and its
        // onDisappear) never existed — the resolved player then played on,
        // headless, and became the system Now Playing item.
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .task {
            var exhausted: Set<String> = []
            // Two passes, not one. Resolving a key is not the same as being
            // able to PLAY it: a googlevideo URL that the connection can't
            // fetch — refused outright, or minted for a network path the box
            // has since left — leaves the item failed, and the old code sat on
            // that behind "Loading trailer" for as long as anyone waited. Now
            // a dead item moves on to the next trailer the title has.
            for _ in 0..<2 {
                let remaining = candidates.filter { !exhausted.contains($0) }
                guard !remaining.isEmpty,
                      let resolved = await TrailerResolver.playerItem(candidates: remaining) else { break }
                // Everything the resolver walked past is spent, not just the
                // key it settled on — re-extracting a candidate it already
                // gave up on would only buy the same failure twice.
                if let reached = remaining.firstIndex(of: resolved.youtubeKey) {
                    exhausted.formUnion(remaining[...reached])
                } else {
                    exhausted.insert(resolved.youtubeKey)
                }
                // Dismissed during the (multi-second) extraction: never start.
                guard !Task.isCancelled else { return }
                let player = AVPlayer(playerItem: resolved.item)
                // Start on the first available buffer instead of waiting to build a
                // stall-proof one — a trailer should pop up, not spin.
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
                player.play()
                guard await Self.itemFailed(resolved.item) else { return }
                NSLog("[OrivioTrailer] %@ failed to load: %@", resolved.youtubeKey,
                      String(describing: resolved.item.error))
                // Drop it from the shared backdrop cache too, so the page
                // underneath stops handing the same dead link to its hero.
                TrailerResolver.invalidate(youtubeKey: resolved.youtubeKey)
                player.pause()
                player.replaceCurrentItem(with: nil)
                self.player = nil
            }
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Suspends until the item is either playable or broken, and answers only
    /// for the broken case. A cancelled wait (the viewer left) is not a
    /// failure, so it reports `false` and the caller simply returns.
    ///
    /// The deadline matters as much as the status does: a connection that
    /// swallows the request rather than refusing it leaves the item `.unknown`
    /// indefinitely, and that is what left "Loading trailer" on screen for as
    /// long as anyone was willing to watch it. Generous enough that a slow
    /// link still wins on the first pass.
    private static func itemFailed(_ item: AVPlayerItem, timeout: TimeInterval = 25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            switch item.status {
            case .failed: return true
            case .readyToPlay: return false
            default:
                guard Date() < deadline else {
                    NSLog("[OrivioTrailer] gave up waiting for the item to load")
                    return true
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return false
    }
}
