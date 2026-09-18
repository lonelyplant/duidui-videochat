import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// 与 Dart 侧 lib/native_bridge.dart 对齐的小通道，只有一个方法 goHome。
  private var nativeChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 用 Flutter 的私有 suspend 选择器把 App 退到后台（回桌面）。
    // 注意：这不是之前的 AVCaptureSession swizzle 那套补丁（那套会因缺
    // multitasking-camera-access entitlement 在未签名包上闪退），本文件只挂一条方法通道，
    // 不碰摄像头会话，对 TrollStore / 未签名 IPA 是安全的。
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "duidui/native",
                                        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "goHome":
          // iOS 没有任何公开 API 能让 App 主动退到后台。这里给 UIApplication 发私有的
          // suspend 选择器，效果等同于用户按 Home：App 进后台，已启动的 PiP 小窗继续
          // 浮在桌面上。
          //
          // ⚠️ 私有 API，上架 App Store 有被拒风险；本 App 走 TrollStore 侧载自用，不受影响。
          // 将来若要上架，iOS 侧应改回「点悬浮窗只起 PiP，由用户自己按 Home 退后台」。
          // 先 responds(to:) 再调用，防止个别系统版本没有该方法时崩溃。
          let selector = NSSelectorFromString("suspend")
          if UIApplication.shared.responds(to: selector) {
            _ = UIApplication.shared.perform(selector)
            result(true)
          } else {
            result(false)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      nativeChannel = channel
    } else {
      NSLog("[duidui] native channel NOT registered: rootViewController is not FlutterViewController")
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
