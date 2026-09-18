package com.example.duidui_video

import io.agora.agora_rtc_ng.AgoraPIPFlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 悬浮窗（PiP）不再由本工程自写原生桥实现——声网 Flutter SDK 6.6.2+ 已在
 * SDK 内部提供画中画能力（Dart 侧 engine.createPipController()），
 * 原生侧只需要两件事：
 *   1. AndroidManifest 里 Activity 声明 android:supportsPictureInPicture="true"
 *   2. Activity 继承 AgoraPIPFlutterActivity，插件才能接管 onUserLeaveHint()
 *      （安卓 12 以下「按 Home 自动进小窗」依赖这一步）
 *
 * AgoraPIPFlutterActivity 继承自 FlutterActivity，行为与原生 FlutterActivity 一致。
 *
 * 额外挂了一条 duidui/native 通道给 Dart 用，只有一个方法 goHome：把 App 退到桌面，
 * 但【不】销毁本 Activity。之所以不能用 Flutter 自带的 SystemNavigator.pop()：
 * 它在安卓上执行 Activity.finish()，Activity 一销毁，声网的 PiP 小窗跟着消失，
 * 且重开 App 会从首页重新启动 —— 正是「回到桌面没小窗 + 重开回到首页」的原因。
 */
class MainActivity : AgoraPIPFlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duidui/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "goHome" -> {
                        // 等价于用户按 Home：任务退到后台，Activity 不销毁。
                        // 退后台会让本 Activity 收到 onUserLeaveHint()，
                        // AgoraPIPFlutterActivity 正是在那里调用系统的
                        // enterPictureInPictureMode()，于是桌面可见、PiP 小窗浮在其上。
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
