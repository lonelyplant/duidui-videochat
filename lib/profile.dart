// 我的资料（昵称/头像）与累计通话统计的本地存储。
// 昵称头像在进房后通过声网数据流广播给对方（见 rtc_manager），对方显示在通话页顶部。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PeerProfile {
  final String name;
  final String emoji;
  const PeerProfile({required this.name, required this.emoji});
}

class ProfileStore {
  static const _kName = 'vc_name';
  static const _kEmoji = 'vc_emoji';
  static const defaultEmoji = '🙂';
  static const emojis = ['🙂', '😊', '🐱', '🐶', '🦊', '🌸'];

  static Future<String> getName() async =>
      (await SharedPreferences.getInstance()).getString(_kName) ?? '';

  static Future<void> setName(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kName, sanitizeName(v));

  static Future<String> getEmoji() async {
    final v =
        (await SharedPreferences.getInstance()).getString(_kEmoji) ?? '';
    return v.isEmpty ? defaultEmoji : v;
  }

  static Future<void> setEmoji(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kEmoji, v);

  /// 数据来自对方（可伪造）：去控制字符、限长，防止破版
  static String sanitizeName(String s) => s
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f]'), '')
      .replaceAll(RegExp('[<>&"\']'), '');

  static String sanitizeEmoji(String s) {
    final runes = s.runes.take(4).toList();
    return String.fromCharCodes(runes).trim();
  }

  static String cappedName(String s) {
    final clean = sanitizeName(s);
    if (clean.runes.length <= 12) return clean;
    return String.fromCharCodes(clean.runes.take(12));
  }
}

class CallStats {
  static const _k = 'vc_stats';

  static Future<Map<String, num>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_k);
    if (raw == null) return {'calls': 0, 'seconds': 0, 'mb': 0.0};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        return {
          'calls': (d['calls'] ?? 0) as num,
          'seconds': (d['seconds'] ?? 0) as num,
          'mb': (d['mb'] ?? 0) as num,
        };
      }
    } catch (_) {}
    return {'calls': 0, 'seconds': 0, 'mb': 0.0};
  }

  static Future<void> _save(Map<String, num> s) async =>
      (await SharedPreferences.getInstance()).setString(_k, jsonEncode(s));

  /// 增量累加流量/时长。通话中每约 30 秒调一次、挂断时冲最后一段——
  /// 这样进程被杀最多丢 30 秒统计，而不是整通全丢。
  static Future<void> addTraffic({
    required int seconds,
    required int bytes,
  }) async {
    if (seconds <= 0 && bytes <= 0) return;
    final s = await load();
    s['seconds'] = (s['seconds'] ?? 0) + seconds;
    s['mb'] = (s['mb'] ?? 0) + bytes / 1048576;
    await _save(s);
  }

  /// 通话计数：整通时长 ≥3 秒才算一通（与网页版口径一致），一通只加一次。
  static Future<void> countCall() async {
    final s = await load();
    s['calls'] = (s['calls'] ?? 0) + 1;
    await _save(s);
  }

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_k);
}
