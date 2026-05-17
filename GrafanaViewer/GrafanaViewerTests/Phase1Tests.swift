import XCTest
@testable import GrafanaViewer

// MARK: - Codable shape

final class FolderDecodingTests: XCTestCase {
    func testDecodesTopLevelFolder() throws {
        let json = #"""
        {"id":1,"uid":"prod","title":"Production","parentUid":null}
        """#.data(using: .utf8)!
        let folder = try JSONDecoder().decode(Folder.self, from: json)
        XCTAssertEqual(folder.uid, "prod")
        XCTAssertEqual(folder.title, "Production")
        XCTAssertNil(folder.parentUid)
        XCTAssertFalse(folder.isSyntheticSharedWithMe)
    }

    func testDecodesNestedFolderWithParentUid() throws {
        let json = #"""
        {"id":2,"uid":"sub","title":"Sub","parentUid":"prod"}
        """#.data(using: .utf8)!
        let folder = try JSONDecoder().decode(Folder.self, from: json)
        XCTAssertEqual(folder.parentUid, "prod")
    }

    func testDecodesFolderWithoutParentUidKey() throws {
        // Grafana 10 omits parentUid entirely on top-level folders.
        let json = #"{"id":3,"uid":"x","title":"X"}"#.data(using: .utf8)!
        let folder = try JSONDecoder().decode(Folder.self, from: json)
        XCTAssertNil(folder.parentUid)
    }

    func testDetectsSharedWithMeFolder() throws {
        let json = #"""
        {"id":-1,"uid":"sharedwithme","title":"Shared with me"}
        """#.data(using: .utf8)!
        let folder = try JSONDecoder().decode(Folder.self, from: json)
        XCTAssertTrue(folder.isSyntheticSharedWithMe)
    }
}

final class SearchHitDecodingTests: XCTestCase {
    func testDecodesDashboardHit() throws {
        let json = #"""
        {"id":2,"uid":"kitchen-sink","title":"Kitchen Sink","type":"dash-db",
         "url":"/d/kitchen-sink/kitchen-sink","tags":["demo"],
         "folderUid":"prod","folderTitle":"Production","isStarred":false}
        """#.data(using: .utf8)!
        let hit = try JSONDecoder().decode(SearchHit.self, from: json)
        XCTAssertEqual(hit.uid, "kitchen-sink")
        XCTAssertEqual(hit.type, .dashboard)
        XCTAssertEqual(hit.folderUid, "prod")
        XCTAssertEqual(hit.tags, ["demo"])
    }

    func testDecodesFolderHit() throws {
        let json = #"""
        {"id":1,"uid":"prod","title":"Production","type":"dash-folder",
         "url":"/dashboards/f/prod","tags":[],"folderUid":null,
         "folderTitle":null,"isStarred":null,"sortMeta":0}
        """#.data(using: .utf8)!
        let hit = try JSONDecoder().decode(SearchHit.self, from: json)
        XCTAssertEqual(hit.type, .folder)
    }
}

final class DashboardEnvelopeDecodingTests: XCTestCase {
    func testDecodesEnvelopeWithPanels() throws {
        // Realistic Grafana 11 response shape — extra fields included to
        // verify we ignore unknown keys.
        let json = #"""
        {
          "dashboard": {
            "uid": "kitchen-sink",
            "title": "Kitchen Sink",
            "tags": ["demo"],
            "schemaVersion": 39,
            "version": 1,
            "panels": [
              {"id": 1, "type": "timeseries", "title": "Request rate",
               "gridPos": {"x":0,"y":0,"w":24,"h":8}},
              {"id": 2, "type": "stat", "title": "Up"},
              {"id": 3, "type": "table"}
            ]
          },
          "meta": {
            "isStarred": false,
            "folderUid": "prod",
            "folderTitle": "Production",
            "url": "/d/kitchen-sink/kitchen-sink",
            "updated": "2026-05-01T12:34:56Z",
            "version": 1,
            "canSave": true
          }
        }
        """#.data(using: .utf8)!
        let env = try JSONDecoder().decode(DashboardEnvelope.self, from: json)
        XCTAssertEqual(env.dashboard.title, "Kitchen Sink")
        XCTAssertEqual(env.dashboard.panels.count, 3)
        XCTAssertEqual(env.dashboard.panels[0].type, "timeseries")
        XCTAssertNil(env.dashboard.panels[2].title)
        XCTAssertEqual(env.meta.folderTitle, "Production")
    }
}

// MARK: - GrafanaClient new methods

@MainActor
final class Phase1ClientTests: XCTestCase {
    private let baseURL = URL(string: "https://grafana.example.com")!

    func testListFoldersHitsRightPath() async throws {
        let session = MockURLSession { request in
            XCTAssertEqual(request.url?.path, "/api/folders")
            XCTAssertEqual(request.httpMethod, "GET")
            return (Data("[]".utf8), Self.ok())
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        let folders = try await client.listFolders()
        XCTAssertEqual(folders, [])
    }

    func testSearchDashboardsBuildsExpectedQuery() async throws {
        let session = MockURLSession { request in
            let url = request.url!
            XCTAssertEqual(url.path, "/api/search")
            let qs = Self.queryItems(url)
            XCTAssertEqual(qs["query"], "rate")
            XCTAssertEqual(qs["type"], "dash-db")
            XCTAssertEqual(qs["starred"], "true")
            XCTAssertEqual(qs["limit"], "50")
            // Plural folderUIDs — Grafana 10+. Multiple values supported.
            let folderUIDs = Self.queryItemsAll(url, name: "folderUIDs")
            XCTAssertEqual(Set(folderUIDs), Set(["prod", "stage"]))
            let tags = Self.queryItemsAll(url, name: "tag")
            XCTAssertEqual(Set(tags), Set(["api", "latency"]))
            return (Data("[]".utf8), Self.ok())
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        _ = try await client.searchDashboards(
            query: "rate",
            type: .dashboard,
            folderUIDs: ["prod", "stage"],
            starred: true,
            tags: ["api", "latency"],
            limit: 50
        )
    }

    func testSearchDashboardsOmitsEmptyParams() async throws {
        let session = MockURLSession { request in
            let url = request.url!
            let qs = Self.queryItems(url)
            // Defaults: only `type` is sent (default = .dashboard).
            XCTAssertEqual(qs.keys.sorted(), ["type"])
            XCTAssertEqual(qs["type"], "dash-db")
            return (Data("[]".utf8), Self.ok())
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        _ = try await client.searchDashboards()
    }

    func testGetDashboardEncodesUidIntoPath() async throws {
        let session = MockURLSession { request in
            XCTAssertEqual(request.url?.path, "/api/dashboards/uid/kitchen-sink")
            let body = #"{"dashboard":{"uid":"kitchen-sink","title":"K","panels":[]},"meta":{"isStarred":false}}"#
            return (Data(body.utf8), Self.ok())
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        let env = try await client.getDashboard(uid: "kitchen-sink")
        XCTAssertEqual(env.dashboard.uid, "kitchen-sink")
    }

    nonisolated private static func ok() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    nonisolated private static func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    nonisolated private static func queryItemsAll(_ url: URL, name: String) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == name }
            .compactMap { $0.value } ?? []
    }
}

// MARK: - RecentDashboardsStore

@MainActor
final class RecentDashboardsStoreTests: XCTestCase {
    func testRecordPrependsAndPersists() {
        let defaults = ephemeralDefaults()
        let store = RecentDashboardsStore(defaults: defaults, key: "test", cap: 20)

        store.record(uid: "a", title: "A", folderTitle: "Prod")
        store.record(uid: "b", title: "B", folderTitle: nil)

        XCTAssertEqual(store.entries.map(\.uid), ["b", "a"])

        // Same defaults + key → reload sees the persisted state.
        let store2 = RecentDashboardsStore(defaults: defaults, key: "test")
        XCTAssertEqual(store2.entries.map(\.uid), ["b", "a"])
    }

    func testReRecordingMovesToFrontWithoutDuplicating() {
        let store = RecentDashboardsStore(defaults: ephemeralDefaults(), key: "test")
        store.record(uid: "a", title: "A", folderTitle: nil)
        store.record(uid: "b", title: "B", folderTitle: nil)
        store.record(uid: "a", title: "A (renamed)", folderTitle: "X")

        XCTAssertEqual(store.entries.map(\.uid), ["a", "b"])
        XCTAssertEqual(store.entries[0].title, "A (renamed)")
        XCTAssertEqual(store.entries[0].folderTitle, "X")
    }

    func testCapsAtConfiguredSize() {
        let store = RecentDashboardsStore(defaults: ephemeralDefaults(), key: "test", cap: 3)
        for i in 0..<10 {
            store.record(uid: "uid-\(i)", title: "T\(i)", folderTitle: nil)
        }
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.uid), ["uid-9", "uid-8", "uid-7"])
    }

    func testClearWipesPersistence() {
        let defaults = ephemeralDefaults()
        let store = RecentDashboardsStore(defaults: defaults, key: "test")
        store.record(uid: "a", title: "A", folderTitle: nil)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = RecentDashboardsStore(defaults: defaults, key: "test")
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
