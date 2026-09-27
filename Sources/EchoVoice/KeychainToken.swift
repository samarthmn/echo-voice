import Foundation
import Security

enum KeychainToken {
    static let service = "com.samarthmn.EchoVoice.model-downloads"
    @discardableResult static func save(_ value: String) -> Bool {
        remove()
        return SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "huggingface", kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil) == errSecSuccess
    }
    static func read() -> String? {
        var result: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "huggingface", kSecReturnData: true, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove() { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "huggingface"] as CFDictionary) }
}
