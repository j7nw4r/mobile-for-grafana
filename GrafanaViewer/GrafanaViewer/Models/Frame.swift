import Foundation

/// Arrow-style columnar frame returned by `/api/ds/query`. Stub — full shape
/// and decoding live in docs/04-datasource-queries.md.
struct Frame: Sendable {
    let refId: String
    let fields: [Field]

    struct Field: Sendable {
        let name: String
        let type: String
    }
}
