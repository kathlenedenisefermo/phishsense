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
          } else if call.method == "scanMessage" {
            guard let args = call.arguments as? [String: Any],
                  let message = args["message"] as? String else {
              result(FlutterError(code: "BAD_ARGS", message: "Missing message", details: nil))
              return
            }
            guard let url = URL(string: "https://phishsense-backend-production.up.railway.app/predict") else {
              result(FlutterError(code: "BAD_URL", message: "Invalid URL", details: nil))
              return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": message])
            URLSession.shared.dataTask(with: request) { data, _, error in
              if let data = data,
                 let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result(json)
              } else {
                result(FlutterError(code: "API_ERROR", message: error?.localizedDescription ?? "Unknown", details: nil))
              }
            }.resume()
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
      }
    }

    return result
  }
}
