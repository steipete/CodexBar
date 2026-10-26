#if os(macOS)
import CommonCrypto
import Foundation
import Security
import SweetCookieKit

/// Chromium/Electron macOS OSCrypt primitives shared by app tokens and the legacy cookie reader.
enum ChromiumSafeStorage {
    @TaskLocal static var readOverrideForTesting: (@Sendable ([String: Any]) -> (OSStatus, Data?))?

    static func password(service: String, account: String, allowPrompt: Bool = false) -> String? {
        guard !KeychainAccessGate.isDisabled else { return nil }
        var interactive = false
        if allowPrompt {
            // Legacy ACLs can prompt despite no-UI flags; inspect them before requesting the secret.
            switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
            case .allowed: break
            case .interactionRequired:
                guard BrowserCookieAccessGate.claimCredentialRead(service: service) else { return nil }
                interactive = true
            case .notFound, .temporarilyUnavailable, .failure: return nil
            }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if interactive {
            BrowserCookieKeychainPromptHandler.handler?(.init(service: service, account: account, label: service))
        } else {
            KeychainNoUIQuery.apply(to: &query)
        }
        let (status, data) = self.readOverrideForTesting?(query) ?? KeychainStringStore.Operations.live.read(query)
        if interactive, [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem].contains(status) {
            BrowserCookieAccessGate.recordCredentialDenial(service: service)
        }
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        return key
    }

    static func decrypt(_ encryptedValue: Data, key: Data) -> Data? {
        guard encryptedValue.count > 3, encryptedValue.starts(with: Data("v10".utf8)) else { return nil }

        let payload = Data(encryptedValue.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outLength = 0
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        out.count = outLength

        return out
    }
}
#endif
