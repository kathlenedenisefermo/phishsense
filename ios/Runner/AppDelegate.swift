import UIKit
import Flutter
import Foundation

@main
@objc class AppDelegate: FlutterAppDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if let controller = self.window?.rootViewController as? FlutterViewController {
        let channel = FlutterMethodChannel(
          name: "com.phishsense/appgroup",
          binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { call, result in
          if call.method == "getFilteredLogs" {
            let groupID = "group.com.phishsense.shared"
            if let defaults = UserDefaults(suiteName: groupID),
               let data = defaults.data(forKey: "filtered_messages"),
               let json = String(data: data, encoding: .utf8) {
              result(json)
              return
            }
            if let containerURL = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: groupID
            ) {
              let fileURL = containerURL.appendingPathComponent("filtered_messages.json")
              if let data = try? Data(contentsOf: fileURL),
                 let json = String(data: data, encoding: .utf8) {
                result(json)
                return
              }
            }
            result("[]")
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
      }
    }

    return result
  }
}
