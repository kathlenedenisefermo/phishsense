import UIKit
import Flutter
import Contacts

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let groupID = "group.com.phishsense.shared"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    DispatchQueue.main.async { [weak self] in
      self?.setupChannels()
    }

    return result
  }

  private func setupChannels() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    let sharedLogsChannel = FlutterMethodChannel(
      name: "phishsense/shared_logs",
      binaryMessenger: controller.binaryMessenger
    )

    sharedLogsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }

      if call.method == "getFilteredLogs" {
        let defaults = UserDefaults(suiteName: self.groupID)
        let logs = defaults?.array(forKey: "filtered_logs") as? [[String: String]] ?? []
        result(logs)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let smsManagerChannel = FlutterMethodChannel(
      name: "com.phishsense/sms_manager",
      binaryMessenger: controller.binaryMessenger
    )

    smsManagerChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }

      switch call.method {
      case "getAllContacts":
        self.getAllContacts(result: result)

      case "lookupContactName":
        guard
          let args = call.arguments as? [String: Any],
          let number = args["number"] as? String
        else {
          result(nil)
          return
        }
        self.lookupContactName(number: number, result: result)

      // Safe iOS fallbacks for Android-only SMS methods
      case "readInbox":
        result([])

      case "readThread":
        result([])

      case "searchMessages":
        result([])

      case "getUnreadCounts":
        result([:])

      case "isDefaultSmsApp":
        result(false)

      case "requestDefaultSmsApp":
        result(false)

      case "openDefaultAppsSettings":
        if let url = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.open(url)
        }
        result(nil)

      case "makeCall":
        guard
          let args = call.arguments as? [String: Any],
          let number = args["number"] as? String,
          let url = URL(string: "tel://\(number)"),
          UIApplication.shared.canOpenURL(url)
        else {
          result(nil)
          return
        }
        UIApplication.shared.open(url)
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func getAllContacts(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let status = CNContactStore.authorizationStatus(for: .contacts)

    switch status {
    case .authorized:
      self.fetchContacts(store: store, result: result)
        
    case .notDetermined:
      store.requestAccess(for: .contacts) { granted, _ in
        DispatchQueue.main.async {
          if granted {
            self.fetchContacts(store: store, result: result)
          } else {
            result(FlutterError(code: "CONTACTS_DENIED", message: "Contacts permission denied", details: nil))
          }
        }
      }

    case .denied, .restricted:
      result(FlutterError(code: "CONTACTS_DENIED", message: "Contacts permission denied", details: nil))

    @unknown default:
      result(FlutterError(code: "CONTACTS_UNKNOWN", message: "Unknown contacts permission state", details: nil))
    }
  }

  private func fetchContacts(store: CNContactStore, result: @escaping FlutterResult) {
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor
    ]

    var output: [[String: String]] = []
    let request = CNContactFetchRequest(keysToFetch: keys)

    do {
      try store.enumerateContacts(with: request) { contact, _ in
        let fullName = "\(contact.givenName) \(contact.familyName)"
          .trimmingCharacters(in: .whitespaces)

        for phone in contact.phoneNumbers {
          let number = phone.value.stringValue
          output.append([
            "name": fullName.isEmpty ? "Unknown Contact" : fullName,
            "number": number
          ])
        }
      }
      result(output)
    } catch {
      result([])
    }
  }

  private func lookupContactName(number: String, result: @escaping FlutterResult) {
    let store = CNContactStore()

    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor
    ]

    let target = normalizePhone(number)

    let request = CNContactFetchRequest(keysToFetch: keys)

    do {
      var foundName: String? = nil

      try store.enumerateContacts(with: request) { contact, stop in
        for phone in contact.phoneNumbers {
          let saved = self.normalizePhone(phone.value.stringValue)
          if saved == target {
            let fullName = "\(contact.givenName) \(contact.familyName)"
              .trimmingCharacters(in: .whitespaces)
            foundName = fullName.isEmpty ? nil : fullName
            stop.pointee = true
            break
          }
        }
      }

      result(foundName)
    } catch {
      result(nil)
    }
  }

  private func normalizePhone(_ value: String) -> String {
    let digits = value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    if digits.count >= 10 {
      return String(digits.suffix(10))
    }
    return digits
  }
}
