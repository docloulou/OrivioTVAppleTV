import Foundation
import UIKit

/// One channel parsed from an M3U/M3U8 playlist.
struct M3UChannel: Identifiable, Hashable {
    let id: String        // the stream URL (stable + unique enough)
    let name: String
    let url: String
    let logo: String?
    let group: String
    /// ISO country code from the tvg-id (e.g. "BBCAmerica.us@East" → "us"), if any.
    let country: String?
    /// Headers, manifest type and DRM the playlist declared for THIS channel.
    /// See `LiveStreamOptions` — these used to be parsed and thrown away.
    var options: LiveStreamOptions = LiveStreamOptions()
    var id_: String { id }
}

/// Parses an M3U playlist (e.g. the embedded iptv-org global list) into channels
/// with their group, logo and direct stream URL. Fetch + parse happen off the
/// main actor; the result is cached in memory for the session.
enum M3UService {
    /// The playlist embedded into Live TV so channels exist without installing
    /// any add-on.
    static let iptvOrgURL = "https://iptv-org.github.io/iptv/index.m3u"

    /// Parsed playlists, most-recently-used last. Each entry is an ENTIRE
    /// playlist — the embedded iptv-org index alone is ~10k channels (tens of
    /// MB parsed), and user Xtream lists run far larger — so this is capped
    /// at two playlists (the one on screen plus the one just left) and
    /// emptied on a memory warning. It used to be unbounded and permanent:
    /// every playlist ever opened stayed resident for the process lifetime,
    /// on a 2 GB box, after leaving Live TV. Worst case after a purge is one
    /// re-download and an off-main re-parse.
    private static var cache: [String: [M3UChannel]] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 2
    private static let lock = NSLock()

    private static let purgeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil, queue: .main
    ) { _ in
        lock.withLock {
            cache.removeAll()
            cacheOrder.removeAll()
        }
    }

    static func channels(from urlString: String) async -> [M3UChannel] {
        _ = purgeObserver
        let hit = lock.withLock { () -> [M3UChannel]? in
            guard let hit = cache[urlString] else { return nil }
            // Refresh LRU position.
            cacheOrder.removeAll { $0 == urlString }
            cacheOrder.append(urlString)
            return hit
        }
        if let hit { return hit }

        guard let url = URL(string: urlString) else { return [] }
        let parsed: [M3UChannel]
        if let xtream = await xtreamLiveChannels(playlistURL: url), !xtream.isEmpty {
            parsed = xtream
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            // A captive portal (or any error page) answers 200 with HTML. Without
            // a status check that parsed to zero channels and was CACHED for the
            // process lifetime, so Live TV stayed empty until the app was killed
            // even after the network came good.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("[OrivioM3U] %@ returned HTTP %d — not caching", urlString, http.statusCode)
                return []
            }
            parsed = await Task.detached(priority: .userInitiated) { parse(text) }.value
        }
        // Only cache a real playlist. An empty parse is either an error page
        // or a truncated download; caching it makes the failure permanent.
        guard !parsed.isEmpty else { return [] }
        lock.withLock {
            if cache[urlString] == nil { cacheOrder.append(urlString) }
            cache[urlString] = parsed
            while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        return parsed
    }

    static func parse(_ text: String) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var seen = Set<String>()
        var pendingName: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingCountry: String?
        var pendingOptions = LiveStreamOptions()

        text.enumerateLines { line, _ in
            if line.hasPrefix("#EXTINF") {
                pendingName = name(from: line)
                pendingLogo = attribute("tvg-logo", in: line)
                pendingGroup = attribute("group-title", in: line)
                pendingCountry = country(fromTvgID: attribute("tvg-id", in: line))
                // Some playlists put the agent on the EXTINF line itself.
                if let agent = attribute("user-agent", in: line) {
                    pendingOptions.setHeader("User-Agent", agent)
                }
            } else if line.hasPrefix("#") {
                if line.hasPrefix("#EXTGRP:") {
                    pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                } else {
                    // Every other directive that carries playback options. These
                    // were discarded, which is why channels behind a CDN that
                    // checks User-Agent or Referer looked dead.
                    absorbDirective(line, into: &pendingOptions)
                }
            } else {
                let rawLine = line.trimmingCharacters(in: .whitespaces)
                guard !rawLine.isEmpty, let nm = pendingName, !nm.isEmpty else { return }
                // A `|Header=Value` suffix on the URL wins over the directives
                // above it — it is the most specific statement about this link.
                let split = LiveStreamClassifier.splitPipedOptions(rawLine)
                var options = pendingOptions
                options.merge(split.options)
                let url = split.url
                if seen.insert(url).inserted {
                    channels.append(M3UChannel(
                        id: url, name: nm, url: url,
                        logo: pendingLogo?.isEmpty == false ? pendingLogo : nil,
                        group: (pendingGroup?.isEmpty == false ? pendingGroup! : "Other"),
                        country: pendingCountry,
                        options: options
                    ))
                }
                pendingName = nil; pendingLogo = nil; pendingGroup = nil; pendingCountry = nil
                pendingOptions = LiveStreamOptions()
            }
        }
        return channels
    }

    /// Fold one `#`-directive into the options being accumulated for the next
    /// URL line. Covers the three conventions in the wild:
    ///
    /// * `#EXTVLCOPT:http-user-agent=…` — VLC's, and the most common by far.
    /// * `#EXTHTTP:{"User-Agent":"…"}` — a JSON header map.
    /// * `#KODIPROP:inputstream.adaptive.…` — Kodi's, which also carries the
    ///   manifest type and any DRM.
    private static func absorbDirective(_ line: String, into options: inout LiveStreamOptions) {
        func value(after prefix: String) -> String? {
            guard line.count > prefix.count,
                  line.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }

        if let raw = value(after: "#EXTVLCOPT:") {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0].lowercased() {
            case "http-user-agent": options.setHeader("User-Agent", parts[1])
            case "http-referrer", "http-referer": options.setHeader("Referer", parts[1])
            case "http-origin": options.setHeader("Origin", parts[1])
            case "http-cookie": options.setHeader("Cookie", parts[1])
            default: break   // network-caching, deinterlace… not ours to act on
            }
            return
        }

        if let raw = value(after: "#EXTHTTP:") {
            guard let data = raw.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for (key, rawValue) in map {
                if let text = rawValue as? String { options.setHeader(key, text) }
            }
            return
        }

        if let raw = value(after: "#KODIPROP:") {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let key = parts[0].lowercased()
            let payload = parts[1]
            if key.hasSuffix("manifest_type") { options.manifestType = payload }
            else if key.hasSuffix("license_type") { options.licenseType = payload }
            else if key.hasSuffix("license_key") { options.licenseKey = payload }
            else if key.hasSuffix("stream_headers") || key.hasSuffix("manifest_headers") {
                options.absorbHeaderQuery(payload)
            }
            return
        }

        // `#EXTVLCOPT` without the colon, and the bare `#USER-AGENT:` some
        // generators emit.
        if let agent = value(after: "#USER-AGENT:") { options.setHeader("User-Agent", agent) }
        else if let referer = value(after: "#REFERER:") { options.setHeader("Referer", referer) }
    }

    /// Value of an `attr="value"` pair on an #EXTINF line.
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// The 2-letter country code embedded in a tvg-id like "BBCAmerica.us@East"
    /// or "AlMajd.sa" — the segment after the last "." (before any "@").
    private static func country(fromTvgID tvgID: String?) -> String? {
        guard let raw = tvgID, !raw.isEmpty else { return nil }
        let beforeAt = raw.split(separator: "@", maxSplits: 1).first.map(String.init) ?? raw
        guard let cc = beforeAt.split(separator: ".").last.map(String.init),
              cc.count == 2, cc.allSatisfy({ $0.isLetter }) else { return nil }
        return cc.lowercased()
    }

    /// The channel name — the text after the first comma that isn't inside quotes.
    private static func name(from line: String) -> String {
        var inQuote = false
        for (i, c) in line.enumerated() {
            if c == "\"" { inQuote.toggle() }
            else if c == "," && !inQuote {
                let start = line.index(line.startIndex, offsetBy: i + 1)
                return String(line[start...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}

// MARK: - Xtream Codes API

extension M3UService {
    /// Live channels for an IPTV provider login, read through the Xtream
    /// Codes JSON API (`player_api.php`) — the endpoint every other IPTV app
    /// signs in with. The login is stored as the provider's `get.php`
    /// playlist URL, but many providers switch that M3U download off, or it
    /// runs past the timeout because it bundles the whole VOD library, so a
    /// login that works everywhere else came back with no channels here.
    /// nil when the URL isn't a provider login or the API doesn't answer
    /// with an authorised account; the caller then falls back to `get.php`.
    fileprivate static func xtreamLiveChannels(playlistURL url: URL) async -> [M3UChannel]? {
        guard url.path.lowercased().hasSuffix("/get.php"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let username = items.first(where: { $0.name == "username" })?.value, !username.isEmpty,
              let password = items.first(where: { $0.name == "password" })?.value, !password.isEmpty
        else { return nil }
        let apiPath = String(components.path.dropLast("get.php".count)) + "player_api.php"
        components.path = apiPath
        let serverBase = String(url.absoluteString.prefix(while: { $0 != "?" }).dropLast("get.php".count))

        func call(_ action: String?) async -> Any? {
            var c = components
            c.queryItems = [URLQueryItem(name: "username", value: username),
                            URLQueryItem(name: "password", value: password)]
                + (action.map { [URLQueryItem(name: "action", value: $0)] } ?? [])
            // Same `+` rule as LiveTVSettingsStore.providerPlaylistURL.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let callURL = c.url else { return nil }
            var request = URLRequest(url: callURL)
            request.timeoutInterval = 30
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("[OrivioM3U] Xtream %@ returned HTTP %d", action ?? "login", http.statusCode)
                return nil
            }
            return await Task.detached(priority: .userInitiated) {
                try? JSONSerialization.jsonObject(with: data)
            }.value
        }

        // Panels send numbers and strings interchangeably for the same field.
        func text(_ value: Any?) -> String? {
            switch value {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }

        guard let login = await call(nil) as? [String: Any],
              let user = login["user_info"] as? [String: Any],
              text(user["auth"]) == "1" else {
            NSLog("[OrivioM3U] Xtream login not authorised — trying get.php")
            return nil
        }
        // HLS when the account allows it (what `get.php` asked for), else the
        // raw TS every panel serves.
        let formats = (user["allowed_output_formats"] as? [Any])?.compactMap { text($0) } ?? []
        let ext = formats.isEmpty || formats.contains("m3u8") ? "m3u8" : "ts"

        let categories = await call("get_live_categories") as? [[String: Any]] ?? []
        guard let streams = await call("get_live_streams") as? [[String: Any]] else { return nil }

        var categoryName: [String: String] = [:]
        var categoryRank: [String: Int] = [:]
        for (i, category) in categories.enumerated() {
            guard let id = text(category["category_id"]) else { continue }
            categoryName[id] = text(category["category_name"])
            categoryRank[id] = i
        }
        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let user_ = username.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? username
        let pass_ = password.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? password

        return await Task.detached(priority: .userInitiated) { () -> [M3UChannel] in
            // Panel order: categories as the provider lists them, channels by
            // their number within each — what the `get.php` playlist gives.
            let ordered = streams.enumerated().sorted { a, b in
                let ra = text(a.element["category_id"]).flatMap { categoryRank[$0] } ?? Int.max
                let rb = text(b.element["category_id"]).flatMap { categoryRank[$0] } ?? Int.max
                if ra != rb { return ra < rb }
                let na = Int(text(a.element["num"]) ?? "") ?? Int.max
                let nb = Int(text(b.element["num"]) ?? "") ?? Int.max
                return na != nb ? na < nb : a.offset < b.offset
            }
            var channels: [M3UChannel] = []
            var seen = Set<String>()
            for (_, stream) in ordered {
                guard let streamID = text(stream["stream_id"]), !streamID.isEmpty,
                      let name = text(stream["name"])?.trimmingCharacters(in: .whitespaces), !name.isEmpty
                else { continue }
                let streamURL = "\(serverBase)live/\(user_)/\(pass_)/\(streamID).\(ext)"
                guard seen.insert(streamURL).inserted else { continue }
                let logo = text(stream["stream_icon"]).flatMap { $0.isEmpty ? nil : $0 }
                let group = text(stream["category_id"]).flatMap { categoryName[$0] }
                channels.append(M3UChannel(
                    id: streamURL, name: name, url: streamURL, logo: logo,
                    group: group?.isEmpty == false ? group! : "Other",
                    country: country(fromTvgID: text(stream["epg_channel_id"]))
                ))
            }
            return channels
        }.value
    }
}
