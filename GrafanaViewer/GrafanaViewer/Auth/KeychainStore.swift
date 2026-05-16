import Foundation
import Security

/// Read/write `Credential` values to the Keychain, keyed by server host.
///
/// One `kSecClassGenericPassword` item per server, scoped by service
/// `com.grafanaviewer.credentials` and account = host. The struct exposes
/// closures so tests can substitute an in-memory implementation; production
/// callers use `.live`.
struct KeychainStore: Sendable {
    var read: @Sendable (_ host: String) throws -> Credential?
    var write: @Sendable (_ host: String, _ credential: Credential) throws -> Void
    var delete: @Sendable (_ host: String) throws -> Void
}

extension KeychainStore {
    nonisolated static let live = KeychainStore(
        read: { try KeychainBackend.read(host: $0) },
        write: { try KeychainBackend.write(host: $0, credential: $1) },
        delete: { try KeychainBackend.delete(host: $0) }
    )
}

enum KeychainError: Error {
    case osStatus(OSStatus)
    case malformed
}

private nonisolated enum KeychainBackend {
    static let service = "com.grafanaviewer.credentials"

    nonisolated static func read(host: String) throws -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    nonisolated static func write(host: String, credential: Credential) throws {
        let data = try encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    nonisolated static func delete(host: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    nonisolated private struct Box: Codable {
        let kind: String
        let value: String
    }

    nonisolated private static func encode(_ credential: Credential) throws -> Data {
        let box: Box
        switch credential {
        case .bearerToken(let t): box = Box(kind: "bearer", value: t)
        case .sessionCookie(let c): box = Box(kind: "cookie", value: c)
        }
        return try JSONEncoder().encode(box)
    }

    nonisolated private static func decode(_ data: Data) throws -> Credential {
        let box = try JSONDecoder().decode(Box.self, from: data)
        switch box.kind {
        case "bearer": return .bearerToken(box.value)
        case "cookie": return .sessionCookie(box.value)
        default: throw KeychainError.malformed
        }
    }
}
