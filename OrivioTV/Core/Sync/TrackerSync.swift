import Foundation

// MARK: - Trakt (§9.2)

/// Two-way watched history, playback progress → Continue Watching,
/// watchlist ↔ Library, ratings, dropped shows. Per profile; every 5 min while
/// signed in, skipped during playback.
@MainActor
enum TraktSync {
    private static var running = false

    static func sync() async {
        let stores = AppStores.shared
        guard stores.trakt.isSignedIn, !stores.trakt.needsReconnect, !running else { return }
        running = true
        defer { running = false }
        let flags = stores.traktFlags.value
        do {
            if flags.syncHistory { try await history() }
            if flags.syncContinueWatching { try await playback() }
            if flags.syncWatchlist { try await watchlist() }
            if flags.syncRatings { try await ratings() }
            try await dropped()
            stores.trakt.lastSync = Date()
            stores.trakt.lastError = nil
        } catch {
            stores.trakt.lastError = error.localizedDescription
        }
    }

    private static func ids(_ item: [String: Any]?) -> String? {
        guard let ids = item?["ids"] as? [String: Any] else { return nil }
        return ids["imdb"] as? String ?? (ids["tmdb"] as? Int).map { "tmdb:\($0)" }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ s: Any?) -> Date {
        guard let s = s as? String else { return Date() }
        return iso.date(from: s) ?? DateParsing.isoNoFraction.date(from: s) ?? Date()
    }

    // MARK: Watched history

    private static func history() async throws {
        let stores = AppStores.shared
        let watched = stores.watched
        // Pull.
        var remote: [WatchedItem] = []
        let (movies, _) = try await TraktService.request("/sync/watched/movies")
        for m in movies as? [[String: Any]] ?? [] {
            guard let id = ids(m["movie"] as? [String: Any]) else { continue }
            remote.append(WatchedItem(id: id, metaID: id, type: "movie", watchedAt: date(m["last_watched_at"]),
                                      name: (m["movie"] as? [String: Any])?["title"] as? String))
        }
        let (shows, _) = try await TraktService.request("/sync/watched/shows")
        for s in shows as? [[String: Any]] ?? [] {
            let show = s["show"] as? [String: Any]
            guard let id = ids(show) else { continue }
            for season in s["seasons"] as? [[String: Any]] ?? [] {
                guard let sn = season["number"] as? Int, sn > 0 else { continue }
                for ep in season["episodes"] as? [[String: Any]] ?? [] {
                    guard let en = ep["number"] as? Int else { continue }
                    remote.append(WatchedItem(id: "\(id):\(sn):\(en)", metaID: id, type: "series", season: sn, episode: en,
                                              watchedAt: date(ep["last_watched_at"]), name: show?["title"] as? String))
                }
            }
        }
        let remoteIDs = Set(remote.map(\.id))
        watched.mergeFromTracker(remote)

        // Push local marks Trakt doesn't have (imdb ids only).
        let missing = watched.items.values.filter { !remoteIDs.contains($0.id) && $0.metaID.hasPrefix("tt") }
        if !missing.isEmpty {
            var movieBody: [[String: Any]] = []
            var showMap: [String: [Int: [[String: Any]]]] = [:]
            for w in missing {
                let at = iso.string(from: w.watchedAt)
                if let s = w.season, let e = w.episode {
                    showMap[w.metaID, default: [:]][s, default: []].append(["number": e, "watched_at": at])
                } else {
                    movieBody.append(["ids": ["imdb": w.metaID], "watched_at": at])
                }
            }
            let showBody: [[String: Any]] = showMap.map { id, seasons in
                ["ids": ["imdb": id], "seasons": seasons.map { ["number": $0.key, "episodes": $0.value] }]
            }
            try await TraktService.request("/sync/history", method: "POST", body: ["movies": movieBody, "shows": showBody])
        }
        // Removals made here.
        let removed = watched.removed.ids.keys.filter { remoteIDs.contains($0) }
        if !removed.isEmpty {
            var movies: [[String: Any]] = []
            var showMap: [String: [Int: [[String: Any]]]] = [:]
            for id in removed {
                let parts = id.split(separator: ":").map(String.init)
                if parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) {
                    showMap[parts.dropLast(2).joined(separator: ":"), default: [:]][s, default: []].append(["number": e])
                } else {
                    movies.append(["ids": ["imdb": id]])
                }
            }
            let shows: [[String: Any]] = showMap.map { id, seasons in
                ["ids": ["imdb": id], "seasons": seasons.map { ["number": $0.key, "episodes": $0.value] }]
            }
            try await TraktService.request("/sync/history/remove", method: "POST", body: ["movies": movies, "shows": shows])
        }
    }

    // MARK: Playback progress → Continue Watching

    private static func playback() async throws {
        let (obj, _) = try await TraktService.request("/sync/playback?extended=full")
        var rows: [WatchProgress] = []
        for item in obj as? [[String: Any]] ?? [] {
            let pct = (item["progress"] as? Double ?? 0) / 100
            let at = date(item["paused_at"])
            if item["type"] as? String == "movie" {
                let m = item["movie"] as? [String: Any]
                guard let id = ids(m) else { continue }
                let dur = Double((m?["runtime"] as? Int ?? 120) * 60)
                rows.append(WatchProgress(id: id, metaID: id, type: "movie", position: dur * pct, duration: dur, updatedAt: at,
                                          name: m?["title"] as? String ?? "", poster: id.hasPrefix("tt") ? TraktService.posterURL(imdb: id) : nil,
                                          background: id.hasPrefix("tt") ? TraktService.backdropURL(imdb: id) : nil))
            } else {
                let show = item["show"] as? [String: Any], ep = item["episode"] as? [String: Any]
                guard let id = ids(show), let s = ep?["season"] as? Int, let e = ep?["number"] as? Int else { continue }
                let dur = Double((ep?["runtime"] as? Int ?? show?["runtime"] as? Int ?? 45) * 60)
                rows.append(WatchProgress(id: "\(id):\(s):\(e)", metaID: id, type: "series", videoID: "\(id):\(s):\(e)", season: s, episode: e,
                                          position: dur * pct, duration: dur, updatedAt: at, name: show?["title"] as? String ?? "",
                                          poster: id.hasPrefix("tt") ? TraktService.posterURL(imdb: id) : nil,
                                          background: id.hasPrefix("tt") ? TraktService.backdropURL(imdb: id) : nil,
                                          episodeTitle: ep?["title"] as? String))
            }
        }
        AppStores.shared.progress.mergeFromTracker(rows)
    }

    /// "Clear Trakt Continue Watching": removes every playback entry on Trakt.
    static func clearPlayback() async {
        guard let (obj, _) = try? await TraktService.request("/sync/playback") else { return }
        for item in obj as? [[String: Any]] ?? [] {
            if let id = item["id"] as? Int { _ = try? await TraktService.request("/sync/playback/\(id)", method: "DELETE") }
        }
    }

    // MARK: Watchlist ↔ Library

    private static func watchlist() async throws {
        let library = AppStores.shared.library
        var remote: [(MetaItem, Date)] = []
        for (path, type) in [("/sync/watchlist/movies", "movie"), ("/sync/watchlist/shows", "series")] {
            let (obj, _) = try await TraktService.request(path)
            for item in obj as? [[String: Any]] ?? [] {
                let key = type == "movie" ? "movie" : "show"
                if let meta = TraktService.meta(fromTraktItem: item[key] as? [String: Any] ?? [:], type: type) {
                    remote.append((meta, date(item["listed_at"])))
                }
            }
        }
        let remoteIDs = Set(remote.map(\.0.id))
        library.mergeFromTracker(remote)
        // Push additions made here.
        let missing = library.items.filter { !remoteIDs.contains($0.meta.id) && $0.meta.id.hasPrefix("tt") }
        if !missing.isEmpty {
            let movies = missing.filter { $0.meta.type == "movie" }.map { ["ids": ["imdb": $0.meta.id]] }
            let shows = missing.filter { $0.meta.type != "movie" }.map { ["ids": ["imdb": $0.meta.id]] }
            try await TraktService.request("/sync/watchlist", method: "POST", body: ["movies": movies, "shows": shows])
        }
        let removed = library.removed.ids.keys.filter { remoteIDs.contains($0) }
        if !removed.isEmpty {
            let list = removed.map { ["ids": ["imdb": $0]] }
            try await TraktService.request("/sync/watchlist/remove", method: "POST", body: ["movies": list, "shows": list])
        }
    }

    // MARK: Ratings

    private static func ratings() async throws {
        let store = AppStores.shared.ratings
        var remote: [String: Int] = [:]
        for (path, key) in [("/sync/ratings/movies", "movie"), ("/sync/ratings/shows", "show")] {
            let (obj, _) = try await TraktService.request(path)
            for item in obj as? [[String: Any]] ?? [] {
                if let id = ids(item[key] as? [String: Any]), let r = item["rating"] as? Int { remote[id] = r }
            }
        }
        // Local ratings Trakt lacks go up; Trakt's fill in the rest.
        let local = store.ratings
        let up = local.filter { remote[$0.key] != $0.value && $0.key.hasPrefix("tt") }
        if !up.isEmpty {
            let list = up.map { ["ids": ["imdb": $0.key], "rating": $0.value] as [String: Any] }
            try await TraktService.request("/sync/ratings", method: "POST", body: ["movies": list, "shows": list])
        }
        store.applyRemote(remote.merging(local) { _, l in l })
    }

    private static func dropped() async throws {
        let (obj, _) = try await TraktService.request("/users/hidden/dropped?type=show&limit=200")
        let dropped = Set((obj as? [[String: Any]] ?? []).compactMap { ids($0["show"] as? [String: Any]) })
        AppStores.shared.watched.droppedShows = dropped
    }
}

// MARK: - SIMKL (§9.3)

struct SimklSession: Codable, Equatable {
    var accessToken: String
    var username: String?
    /// AUTH V2 tokens expire; these renew them (`SimklService.validToken`).
    /// Nil for a legacy PIN-flow token, which does not expire.
    var refreshToken: String? = nil
    var expiresAt: Date? = nil
}

/// SIMKL login per profile (PIN flow, client id only).
@MainActor
final class SimklStore: ObservableObject, ProfileScoped {
    @Published private(set) var session: SimklSession?
    @Published var lastSync: Date?
    @Published var lastError: String?

    init() { reloadForActiveProfile() }

    var isSignedIn: Bool { session != nil }

    func reloadForActiveProfile() {
        session = Persistence.loadScoped(SimklSession.self, base: "simkl.session.v1", profile: ProfileScope.current)
    }

    func set(_ s: SimklSession?) {
        session = s
        if let s { Persistence.saveScoped(s, base: "simkl.session.v1", profile: ProfileScope.current) } else {
            Persistence.set(nil, forKey: Persistence.key("simkl.session.v1", profile: ProfileScope.current))
        }
    }
}

@MainActor
enum SimklService {
    static let base = "https://api.simkl.com"
    static var clientID: String { Secrets.simklClientID }
    static var isConfigured: Bool { !clientID.isEmpty }

    /// `deviceCode` is set for an AUTH V2 device flow and nil for the legacy
    /// PIN flow; `poll` follows whichever one `startPin` opened.
    struct PinInfo {
        var userCode: String
        var url: String
        var interval: TimeInterval
        var expiresAt: Date
        var deviceCode: String? = nil
    }

    /// SIMKL asks every request to name the app: `client_id`, `app-name`
    /// and `app-version` on the URL and a User-Agent. Requests without them
    /// are answered 400 for API apps created recently.
    private static let appName = "orivio-tvos"
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    private static func identified(_ path: String) -> URL? {
        guard var components = URLComponents(string: base + path) else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "client_id" }) { items.append(URLQueryItem(name: "client_id", value: clientID)) }
        items.append(URLQueryItem(name: "app-name", value: appName))
        items.append(URLQueryItem(name: "app-version", value: appVersion))
        components.queryItems = items
        return components.url
    }
    private static var userAgent: String { "OrivioTV/\(appVersion)" }

    private static func get(_ path: String, token: String?) async throws -> Any {
        guard let url = identified(path) else { throw HTTPError.badURL(path) }
        var h = ["simkl-api-key": clientID, "Content-Type": "application/json", "User-Agent": userAgent]
        if let token { h["Authorization"] = "Bearer \(token)" }
        let (d, _) = try await HTTP.data(HTTP.request(url, headers: h, fresh: true, timeout: 30), session: HTTP.ephemeral)
        return (try? JSONSerialization.jsonObject(with: d)) ?? [:]
    }

    /// A form POST to the OAuth 2.0 endpoints, answered with its status and
    /// body whatever the status: the device-token poll reads its 400s.
    private static func postForm(_ path: String, _ fields: [String: String]) async throws -> (status: Int, body: [String: Any]) {
        guard let url = URL(string: base + path) else { throw HTTPError.badURL(path) }
        let form = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&")
        let request = HTTP.request(url, method: "POST",
                                   headers: ["Content-Type": "application/x-www-form-urlencoded",
                                             "Accept": "application/json", "User-Agent": userAgent],
                                   body: Data(form.utf8), fresh: true, timeout: 30)
        let (data, response) = try await HTTP.ephemeral.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    /// The redirect URI a legacy PIN-flow app is usually registered with.
    private static let oobRedirect = "urn:ietf:wg:oauth:2.0:oob"

    static func startPin() async throws -> PinInfo {
        // AUTH V2 FIRST. SIMKL's current API apps sign in with the OAuth 2.0
        // device flow (RFC 8628) and refuse the legacy PIN endpoint with a
        // 400; an app made before it answers the device endpoint with 404 or
        // 401 "invalid_client", which is when the legacy flow is used.
        let device = try await postForm("/oauth2/device", ["client_id": clientID, "scope": "media:read media:write"])
        if (200..<300).contains(device.status), let code = device.body["user_code"] as? String, !code.isEmpty {
            let link = device.body["verification_uri_complete"] as? String
                ?? device.body["verification_uri"] as? String ?? "https://simkl.com/pin"
            return PinInfo(userCode: code, url: link,
                           interval: TimeInterval(device.body["interval"] as? Int ?? 5),
                           expiresAt: Date().addingTimeInterval(TimeInterval(device.body["expires_in"] as? Int ?? 900)),
                           deviceCode: device.body["device_code"] as? String)
        }

        // LEGACY PIN FLOW. Whether to send `redirect` depends on the app: one
        // registered with no redirect URI answers 403 when it is present, one
        // registered with the out-of-band URI answers 400 when it is missing.
        let pinPath = "/oauth/pin?client_id=\(HTTP.encodeComponent(clientID))"
        let obj: [String: Any]
        do {
            obj = try await get(pinPath, token: nil) as? [String: Any] ?? [:]
        } catch HTTPError.status(let code) where code == 400 || code == 403 {
            obj = try await get(pinPath + "&redirect=\(HTTP.encodeComponent(oobRedirect))", token: nil) as? [String: Any] ?? [:]
        }
        guard let code = obj["user_code"] as? String else { throw HTTPError.notJSON }
        return PinInfo(userCode: code, url: obj["verification_url"] as? String ?? "https://simkl.com/pin",
                       interval: TimeInterval(obj["interval"] as? Int ?? 5), expiresAt: Date().addingTimeInterval(TimeInterval(obj["expires_in"] as? Int ?? 900)))
    }

    static func poll(_ pin: PinInfo) async throws -> SimklSession {
        var interval = pin.interval
        while Date() < pin.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if let deviceCode = pin.deviceCode {
                guard let reply = try? await postForm("/oauth2/token", [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": clientID, "device_code": deviceCode,
                ]) else { continue }
                if (200..<300).contains(reply.status), let session = session(from: reply.body) {
                    return session
                }
                switch reply.body["error"] as? String {
                case "authorization_pending", nil: continue
                case "slow_down": interval = min(interval + 5, 60)
                case "expired_token": throw HTTPError.other("The code expired. Start a new SIMKL code.")
                case "access_denied": throw HTTPError.other("The SIMKL sign-in was declined.")
                case let other?: throw HTTPError.other("SIMKL: \(other)")
                }
            } else if let obj = try? await get("/oauth/pin/\(pin.userCode)?client_id=\(clientID)", token: nil) as? [String: Any],
                      (obj["result"] as? String) == "OK", let token = obj["access_token"] as? String {
                return SimklSession(accessToken: token)
            }
        }
        throw HTTPError.other("The code expired. Start a new SIMKL code.")
    }

    /// A token response as a session. `expires_in` is in seconds.
    private static func session(from body: [String: Any], keeping old: SimklSession? = nil) -> SimklSession? {
        guard let token = body["access_token"] as? String, !token.isEmpty else { return nil }
        let lifetime = (body["expires_in"] as? Int).map(TimeInterval.init)
        return SimklSession(accessToken: token, username: old?.username,
                            refreshToken: body["refresh_token"] as? String ?? old?.refreshToken,
                            expiresAt: lifetime.map { Date().addingTimeInterval($0) })
    }

    /// The signed-in profile's access token, renewed first when it expires
    /// within a minute. Nil when signed out, or when SIMKL refused the
    /// renewal — the session is dropped then, so Settings offers Connect
    /// again rather than syncing with a dead token.
    static func validToken() async -> String? {
        let store = AppStores.shared.simkl
        guard let current = store.session else { return nil }
        guard let expiresAt = current.expiresAt, expiresAt.timeIntervalSinceNow < 60 else {
            return current.accessToken
        }
        guard let refresh = current.refreshToken, !refresh.isEmpty else { return current.accessToken }
        guard let reply = try? await postForm("/oauth2/token", [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh,
        ]) else { return current.accessToken }   // offline: try the old one
        if (200..<300).contains(reply.status), let renewed = session(from: reply.body, keeping: current) {
            store.set(renewed)
            return renewed.accessToken
        }
        if reply.status == 400 || reply.status == 401 {
            store.set(nil)
            store.lastError = "SIMKL signed you out (\(reply.body["error"] as? String ?? "HTTP \(reply.status)")). Connect again."
            return nil
        }
        return current.accessToken
    }

    static func username(_ token: String) async -> String? {
        let obj = try? await get("/users/settings", token: token) as? [String: Any]
        return (obj?["user"] as? [String: Any])?["name"] as? String
    }

    /// Watched history, watchlist, ratings. Decoded into small dictionaries per
    /// bucket and transformed off the main actor (huge libraries jetsammed the app).
    static func sync() async {
        let stores = AppStores.shared
        guard let token = await validToken() else { return }
        let flags = stores.simklFlags.value
        do {
            let raw = try await get("/sync/all-items/?extended=full&episode_watched_at=yes", token: token)
            let parsed = await Task.detached(priority: .utility) { parse(raw) }.value
            if flags.syncHistory { stores.watched.mergeFromTracker(parsed.watched) }
            if flags.syncWatchlist { stores.library.mergeFromTracker(parsed.watchlist) }
            if flags.syncRatings {
                let r = (try? await get("/sync/ratings", token: token)) ?? [:]
                let ratings = await Task.detached(priority: .utility) { parseRatings(r) }.value
                if !ratings.isEmpty { stores.ratings.applyRemote(ratings.merging(stores.ratings.ratings) { _, l in l }) }
            }
            stores.simkl.lastSync = Date()
            stores.simkl.lastError = nil
        } catch {
            stores.simkl.lastError = error.localizedDescription
        }
    }

    private nonisolated static func imdb(_ item: [String: Any]?) -> String? {
        let ids = item?["ids"] as? [String: Any]
        if let i = ids?["imdb"] as? String, !i.isEmpty { return i }
        return nil
    }

    private nonisolated static func parse(_ raw: Any) -> (watched: [WatchedItem], watchlist: [(MetaItem, Date)]) {
        let root = raw as? [String: Any] ?? [:]
        // With or without fractional seconds (a bare ISO formatter rejected
        // `.000Z` and every such date became "now").
        let date: (String) -> Date? = { DateParsing.parse($0) }
        var watched: [WatchedItem] = []
        var watchlist: [(MetaItem, Date)] = []
        for m in root["movies"] as? [[String: Any]] ?? [] {
            let movie = m["movie"] as? [String: Any]
            guard let id = imdb(movie) else { continue }
            let title = movie?["title"] as? String ?? ""
            let at = (m["last_watched_at"] as? String).flatMap(date) ?? Date()
            switch m["status"] as? String {
            case "completed": watched.append(WatchedItem(id: id, metaID: id, type: "movie", watchedAt: at, name: title))
            case "plantowatch":
                watchlist.append((MetaItem(id: id, type: "movie", name: title, poster: "https://images.metahub.space/poster/medium/\(id)/img"),
                                  (m["added_to_watchlist_at"] as? String).flatMap(date) ?? Date()))
            default: break
            }
        }
        for key in ["shows", "anime"] {
            for s in root[key] as? [[String: Any]] ?? [] {
                let show = s["show"] as? [String: Any]
                guard let id = imdb(show) else { continue }
                let title = show?["title"] as? String ?? ""
                if s["status"] as? String == "plantowatch" {
                    watchlist.append((MetaItem(id: id, type: "series", name: title, poster: "https://images.metahub.space/poster/medium/\(id)/img"),
                                      (s["added_to_watchlist_at"] as? String).flatMap(date) ?? Date()))
                }
                for season in s["seasons"] as? [[String: Any]] ?? [] {
                    guard let sn = season["number"] as? Int, sn > 0 else { continue }
                    for ep in season["episodes"] as? [[String: Any]] ?? [] {
                        guard let en = ep["number"] as? Int else { continue }
                        let at = (ep["watched_at"] as? String).flatMap(date) ?? Date()
                        watched.append(WatchedItem(id: "\(id):\(sn):\(en)", metaID: id, type: "series", season: sn, episode: en, watchedAt: at, name: title))
                    }
                }
            }
        }
        return (watched, watchlist)
    }

    private nonisolated static func parseRatings(_ raw: Any) -> [String: Int] {
        let root = raw as? [String: Any] ?? [:]
        var out: [String: Int] = [:]
        for (key, inner) in [("movies", "movie"), ("shows", "show"), ("anime", "show")] {
            for r in root[key] as? [[String: Any]] ?? [] {
                if let id = imdb(r[inner] as? [String: Any]), let v = r["user_rating"] as? Int { out[id] = v }
            }
        }
        return out
    }
}
