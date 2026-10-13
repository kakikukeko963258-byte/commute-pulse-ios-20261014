import Foundation

struct GroupDiagnostic: Codable {
    var configuredGroup: String
    var selectedGroup: String?
    var permittedGroups: [String]
    var containerAvailable: Bool
    var writeReadSucceeded: Bool
    var extensionReadAt: Date?
    var extensionPublishedAt: Date?
    var message: String
}

struct ExtensionReceipt: Codable {
    var readAt: Date
    var publishedAt: Date
}

enum SharedStore {
    static let widgetKind = "CommutePulseProgress"
    static var configuredGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.dev.commutepulse.app"
    }

    /// Profile permissions are diagnostic evidence, not proof of executable entitlements.
    static func profileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let finish = text.range(of: "</plist>"),
              start.lowerBound < finish.upperBound else { return [] }
        let xml = String(text[start.lowerBound..<finish.upperBound]).data(using: .utf8)!
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func container() -> (String, URL)? {
        let groups = [configuredGroup] + profileGroups().filter { $0 != configuredGroup && !$0.contains("*") }
        for group in groups {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return (group, url)
            }
        }
        return nil
    }

    static func write(_ envelope: SnapshotEnvelope) throws {
        guard let (_, url) = container() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let encoded = try JSONEncoder().encode(envelope)
        try encoded.write(to: url.appendingPathComponent("snapshot-v1.json"), options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.appendingPathComponent("snapshot-v1.json").path
        )
    }

    static func read(recordExtensionReceipt: Bool = false) -> SnapshotEnvelope? {
        guard let (_, url) = container(),
              let data = try? Data(contentsOf: url.appendingPathComponent("snapshot-v1.json")),
              let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data),
              envelope.version == 1 else { return nil }
        if recordExtensionReceipt,
           let encoded = try? JSONEncoder().encode(
               ExtensionReceipt(readAt: .now, publishedAt: envelope.current.publishedAt)) {
            try? encoded.write(to: url.appendingPathComponent("extension-receipt.json"), options: .atomic)
        }
        return envelope
    }

    static func diagnostic() -> GroupDiagnostic {
        let selected = container()
        var roundTrip = false
        var receipt: ExtensionReceipt?
        if let (_, url) = selected {
            let probe = url.appendingPathComponent("app-probe.txt")
            let token = UUID().uuidString
            do {
                try Data(token.utf8).write(to: probe, options: .atomic)
                roundTrip = (try String(contentsOf: probe, encoding: .utf8)) == token
                try FileManager.default.removeItem(at: probe)
            } catch { roundTrip = false }
            if let data = try? Data(contentsOf: url.appendingPathComponent("extension-receipt.json")) {
                receipt = try? JSONDecoder().decode(ExtensionReceipt.self, from: data)
            }
        }
        return GroupDiagnostic(configuredGroup: configuredGroup, selectedGroup: selected?.0,
            permittedGroups: profileGroups(), containerAvailable: selected != nil,
            writeReadSucceeded: roundTrip, extensionReadAt: receipt?.readAt,
            extensionPublishedAt: receipt?.publishedAt,
            message: selected == nil
                ? "共有コンテナを利用できません。AltStore後の両ターゲットの署名とプロファイルを確認してください。"
                : "本体の書込とWidget読取記録を別々に確認してください。プロファイルの許可だけでは共有成功を証明しません。")
    }
}
