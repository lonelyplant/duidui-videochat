import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'pages/home_page.dart';
import 'pages/call_page.dart';

void main() => runApp(const DuiduiApp());

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
    );
  }
}

/// 持久化：房间名、Token、上次画质
class Settings {
  static const _kRoom = 'vc_room';
  static const _kToken = 'vc_token';
  static const _kQuality = 'vc_default_q';

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
