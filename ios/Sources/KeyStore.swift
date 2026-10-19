import Foundation
import Security

/// 把「访问码派生出的解密密钥」存进系统钥匙串。
/// 作用：iOS 会把嵌在跨站 iframe 里的网页存储定期清掉，导致反复要求输入访问码；
/// 钥匙串不受影响，所以这里做一份副本，页面加载时再还原。
/// 只存密钥（不是访问码本身），且仅限本机、首次解锁后可读，不进 iCloud。
enum KeyStore {
    private static let service = "com.bobo.workbench.gt"
    private static func fbKey(_ account: String) -> String { "gt.fallback." + account }

    /// 先读钥匙串；读不到（例如被重新签名后系统没给钥匙串权限）再读应用私有存储里的备份。
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let s = String(data: data, encoding: .utf8) { return s }
        return UserDefaults.standard.string(forKey: fbKey(account))
    }

    /// 写钥匙串；写失败则退而写应用私有存储（同样只在本机、只有本应用能读）。
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var st = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = base
            attrs.forEach { add[$0.key] = $0.value }
            st = SecItemAdd(add as CFDictionary, nil)
        }
        if st == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fbKey(account))
            return true
        }
        DebugLog.write("keychain set failed status=\(st), using fallback")
        UserDefaults.standard.set(value, forKey: fbKey(account))
        return false
    }

    static func remove(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fbKey(account))
    }
}

/// 仅在设置了环境变量 GT_DEBUG 时写调试日志（云端模拟器自测用，正式使用不产生任何文件）。
enum DebugLog {
    static let on = ProcessInfo.processInfo.environment["GT_DEBUG"] != nil

    static func write(_ line: String) {
        guard on else { return }
        NSLog("[GT] %@", line)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("gt-debug.log")
        let text = "\(Date().timeIntervalSince1970)\t\(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
