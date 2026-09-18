import 'package:flutter/material.dart';
import '../config.dart';
import '../main.dart';
import '../rtc_manager.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _roomCtl = TextEditingController();
  String _qualityKey = defaultQualityKey;
  bool _initing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _roomCtl.text = await Settings.getRoom();
    _qualityKey = await Settings.getQuality();
    if (mounted) setState(() {});
  }

  Future<void> _enter() async {
    final room = _roomCtl.text.trim();
    if (room.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入房间名')));
      return;
    }
    // App ID 是构建期注入的：没注入（本地直接 flutter run）时进不了声网，提前拦下并说明
    if (agoraAppId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('未配置声网 App ID：构建时需要 --dart-define=AGORA_APP_ID 注入'
              '（真值放 GitHub Secrets，不进源码）')));
      return;
    }
    setState(() => _initing = true);
    await Settings.setRoom(room);
    await Settings.setQuality(_qualityKey);

    try {
      // 若上次进房中途失败（引擎已建但没进成/没挂断），先彻底释放旧引擎，
      // 否则会叠出一个占着摄像头的「幽灵引擎」，二次进入时行为异常。
      await rtc.dispose();
      final token = await Settings.getToken();
      await rtc.init(token: token, qualityKey: _qualityKey);
      await rtc.join(room: room, token: token, qualityKey: _qualityKey);
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/call');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('进入失败：$e')));
        setState(() => _initing = false);
      }
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (mounted) _load(); // 设置页可能改了默认画质，回来刷新
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('对对视频',
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    SizedBox(height: 6),
                    Text('和异地家人省流量视频通话',
                        style: TextStyle(color: Colors.white54)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '设置',
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined,
                    color: Colors.white70, size: 26),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _roomCtl,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: '房间名（双方填一样的）',
              labelStyle: TextStyle(color: Colors.white54),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _qualityKey,
            dropdownColor: const Color(0xFF1E1E1E),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: '默认画质',
              labelStyle: TextStyle(color: Colors.white54),
              border: OutlineInputBorder(),
            ),
            items: qualities
                .map((q) => DropdownMenuItem(
                      value: q.key,
                      child: Text('${q.label} · ${q.mbPerHour}',
                          style: const TextStyle(color: Colors.white)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _qualityKey = v ?? defaultQualityKey),
          ),
          const SizedBox(height: 28),
              FilledButton(
                onPressed: _initing ? null : _enter,
                child: _initing
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('进入房间'),
              ),
              const Spacer(),
              Text(
                '版本 1.0.$appBuild（每次推送自动升级，与 Actions/蒲公英一致，分辨新旧包）',
                style: TextStyle(color: Colors.white.withOpacity(.4), fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                '提示：iOS 用 TrollStore 安装 IPA，安卓直接装 APK，均无需上架应用商店。',
                style: TextStyle(color: Colors.white.withOpacity(.4), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
