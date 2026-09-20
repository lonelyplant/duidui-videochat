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
 * 【自动进窗总闸】iris 层一旦在通话中 pipSetup 过（autoEnterEnabled=true），这组
 * PictureInPictureParams 就留在 Activity 上，挂断后未必清掉 —— 表现是回到首页
 * 甚至在桌面按 Home 也会弹出小窗（用户报障）。Dart 侧通过 duidui/native 的
 * setAutoPip 下发开关，这里在系统的两条自动进窗路径上把关：
 *   · onUserLeaveHint()（iris 兼容安卓 12 以下的进窗路径）
 *   · onPictureInPictureRequested()（安卓 12+ 系统自动进窗的询问回调）
 * 手动点「悬浮」不走这两条路径（iris 直接调 enterPictureInPictureMode），不受影响；
 * 手动流程里补一次 moveTaskToBack 触发 onUserLeaveHint 的场景，Dart 侧会先放开总闸。
 *
 * 额外挂了一条 duidui/native 通道给 Dart 用：
 *   · goHome：把 App 退到桌面，但【不】销毁本 Activity。
 *   · setAutoPip(Boolean)：开关上面的自动进窗总闸。
 * 之所以不能用 Flutter 自带的 SystemNavigator.pop()：
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
                    "setAutoPip" -> {
                        autoPipAllowed = call.arguments as? Boolean ?: false
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onUserLeaveHint() {
        // 闸门关闭时【不要】把事件转发给 iris：这是它进小窗的触发点之一。
        if (!autoPipAllowed) return
        super.onUserLeaveHint()
    }

    override fun onPictureInPictureRequested(): Boolean {
        // 安卓 12+ 系统自动进窗前会先问这个回调；闸门关闭时明确拒绝。
        if (!autoPipAllowed) return false
        return super.onPictureInPictureRequested()
    }

    companion object {
        /// 是否允许「退后台自动进悬浮窗」。Dart 侧通话页维护：
        /// 对方画面在播 = true；等待对方/纯语音/挂断后 = false。
        @Volatile
        var autoPipAllowed: Boolean = false
    }
}
