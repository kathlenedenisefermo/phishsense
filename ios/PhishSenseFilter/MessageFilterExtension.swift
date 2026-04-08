import IdentityLookup
import Foundation

final class MessageFilterExtension: ILMessageFilterExtension {}

extension MessageFilterExtension: ILMessageFilterQueryHandling {
    func handle(_ queryRequest: ILMessageFilterQueryRequest,
                
                
                context: ILMessageFilterExtensionContext,
                completion: @escaping (ILMessageFilterQueryResponse) -> Void) {

        let response = ILMessageFilterQueryResponse()

        let sender = queryRequest.sender ?? "Unknown"
        let message = queryRequest.messageBody ?? ""
        let lower = message.lowercased()

        let isSuspicious =
            lower.contains("click") ||
            lower.contains("verify") ||
            lower.contains("urgent") ||
            lower.contains("win")

        response.action = isSuspicious ? .junk : .allow

        saveLog(
            sender: sender,
            message: message,
            label: isSuspicious ? "Phishing" : "Safe"
        )

        completion(response)
    }

    private func saveLog(sender: String, message: String, label: String) {
        let groupID = "group.com.phishsense.shared"

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent("filtered_messages.json")

        var existing: [[String: String]] = []

        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            existing = json
        }

        let formatter = ISO8601DateFormatter()

        let newItem: [String: String] = [
            "sender": sender,
            "message": message,
            "label": label,
            "time": formatter.string(from: Date())
        ]

        existing.insert(newItem, at: 0)

        if existing.count > 100 {
            existing = Array(existing.prefix(100))
        }

        if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
