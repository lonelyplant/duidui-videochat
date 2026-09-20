// 与原生侧（安卓 MainActivity.kt / iOS AppDelegate.swift）之间的小通道。
// 目前只有一个能力：把 App 退到后台（回桌面），但【不】销毁 Activity / 进程。
//
// 为什么需要它 —— SystemNavigator.pop() 不能用：
//   · 安卓：它执行的是 Activity.finish()。Activity 一销毁，声网的 PiP 小窗跟着消失，
//     而且重开 App 会从首页重新启动。表现就是「回到桌面但没有小窗 + 重开回到首页」。
//   · iOS：它是 exit(0)，直接杀进程，小窗同样会没。
//
// 两端各自实现：
//   · 安卓 moveTaskToBack(true) —— 官方 API，只把任务退到后台（等价于按 Home），
//     不 finish。它会让 Activity 触发 onUserLeaveHint()，AgoraPIPFlutterActivity
//     正是靠这个回调去调用系统的 enterPictureInPictureMode()。
//   · iOS 没有公开 API 能让 App 自己退到后台，只能给 UIApplication 发私有的
//     `suspend` 选择器（见 AppDelegate.swift，那里会先 responds(to:) 再调用）。
//     ⚠️ 用的是私有 API，上架 App Store 有被拒风险；本 App 走 TrollStore 侧载自用，
//        不受影响。若日后要上架，iOS 侧应改回「让用户按 Home」的方案。
import 'dart:io';

import 'package:flutter/services.dart';

class NativeBridge {
  NativeBridge._();

  static const MethodChannel _channel = MethodChannel('duidui/native');

  /// 把 App 退到后台（回桌面），原生侧返回是否成功。
  /// 任何异常都吞掉并返回 false —— 退后台失败不该影响通话本身。
  static Future<bool> goHome() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('goHome') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 安卓专用：允许/禁止系统「按 Home 自动进悬浮窗」。
  ///
  /// 为什么 Dart 侧要下发这个开关（安卓-only，iOS 调用无效果）：
  /// 声网 iris 层一旦在通话中 pipSetup 过（autoEnterEnabled=true），这组
  /// PictureInPictureParams 就留在 Activity 上，挂断后未必清掉 —— 表现是
  /// 在首页/桌面按 Home 也会弹出悬浮小窗（用户报障）。Dart 侧重新 pipSetup
  /// 关掉参数有时够用，但 iris 在 onUserLeaveHint 里的进窗路径不完全受参数
  /// 控制，所以在 MainActivity 里加一道总闸最可靠。
  static Future<void> setAutoPip(bool allowed) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('setAutoPip', allowed);
    } catch (_) {}
  }
}
