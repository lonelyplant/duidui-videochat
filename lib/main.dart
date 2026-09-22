import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'config.dart';
import 'pages/home_page.dart';
import 'pages/call_page.dart';
import 'window_title_bar.dart';

Future<void> main() async {
  if (Platform.isWindows) {
    WidgetsFlutterBinding.ensureInitialized();
    // 隐藏系统标题栏，由 WindowTitleBar 自绘（含「置顶」按钮，见 window_title_bar.dart）
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: '对对视频',
        // 窗口默认尺寸 = 小米14 屏幕等比缩小（1200×2670 → 390×870）：
        // 整个 App（首页/设置/通话）默认就是手机竖屏观感，用户仍可手动拉伸/最大化。
        size: Size(390, 870),
        titleBarStyle: TitleBarStyle.hidden,
        minimumSize: Size(320, 480),
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  runApp(const DuiduiApp());
}

class DuiduiApp extends StatelessWidget {
  const DuiduiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '对对视频',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF07C160)),
        scaffoldBackgroundColor: const Color(0xFF0E0E0E),
      ),
      home: const HomePage(),
      routes: {
        '/call': (ctx) => const CallPage(),
      },
      // Windows：所有页面（首页/设置/通话）顶部都挂自绘标题栏（置顶/最小化/最大化/关闭）
      builder: (ctx, child) {
        final bar = maybeWindowTitleBar();
        if (bar == null) return child ?? const SizedBox.shrink();
        return Column(
          children: [bar, Expanded(child: child ?? const SizedBox.shrink())],
        );
      },
    );
  }
}

/// 持久化：房间名、Token、上次画质
class Settings {
  static const _kRoom = 'vc_room';
  static const _kToken = 'vc_token';
  static const _kQuality = 'vc_default_q';
  static const _kAppId = 'vc_app_id';

  /// 用户在设置页配置的声网 App ID（仅桌面版会用到：Windows 分发不走 CI 注入）。
  static Future<String> getAppId() async =>
      (await SharedPreferences.getInstance()).getString(_kAppId) ?? '';
  static Future<void> setAppId(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kAppId, v.trim());

  /// 本机实际生效的 App ID：构建期 --dart-define 注入优先（与手机端一致），
  /// 未注入时回落到设置页里用户配置的值；两者都没有 → 空串（进房前会拦截提示）。
  static Future<String> resolveAppId() async {
    if (agoraAppId.isNotEmpty) return agoraAppId;
    return getAppId();
  }

  static Future<String> getRoom() async =>
      (await SharedPreferences.getInstance()).getString(_kRoom) ?? '';
  static Future<void> setRoom(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kRoom, v);

  static Future<String> getToken() async =>
      (await SharedPreferences.getInstance()).getString(_kToken) ?? '';
  static Future<void> setToken(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kToken, v);

  static Future<String> getQuality() async {
    final v = (await SharedPreferences.getInstance()).getString(_kQuality);
    return v?.isNotEmpty == true ? v! : defaultQualityKey;
  }

  static Future<void> setQuality(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kQuality, v);
}
