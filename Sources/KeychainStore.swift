import Foundation
import Security

enum KeychainStore {

    private static let service =
        "fr.viking.qlabfallback"

    private static let account =
        "qlab-osc-passcode"


    static func readPasscode() -> String? {

        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                service,
            kSecAttrAccount as String:
                account,
            kSecReturnData as String:
                true,
            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &result
            )

        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(
                data: data,
                encoding: .utf8
            )
        else {
            return nil
        }

        return value
    }


    @discardableResult
    static func savePasscode(
        _ value: String
    ) -> Bool {

        guard let data =
            value.data(using: .utf8)
        else {
            return false
        }


        let baseQuery: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                service,
            kSecAttrAccount as String:
                account
        ]


        let update: [String: Any] = [
            kSecValueData as String:
                data
        ]


        let updateStatus =
            SecItemUpdate(
                baseQuery as CFDictionary,
                update as CFDictionary
            )


        if updateStatus == errSecSuccess {
            return true
        }


        guard updateStatus ==
            errSecItemNotFound
        else {
            return false
        }


        var insert =
            baseQuery

        insert[
            kSecValueData as String
        ] = data

        insert[
            kSecAttrAccessible as String
        ] = kSecAttrAccessibleWhenUnlocked


        return SecItemAdd(
            insert as CFDictionary,
            nil
        ) == errSecSuccess
    }
}
