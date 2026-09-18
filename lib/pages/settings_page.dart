// 设置页：我的资料（昵称/头像，通话中通过数据流展示给对方）、默认画质、
// 累计流量统计、Token（高级）、软件更新（检测 → 展开更新说明与大小 → 点下载才真下载）。
// 功能对应旧网页版的设置页。
import 'dart:io';

import 'package:flutter/material.dart';

import '../config.dart';
import '../main.dart';
import '../profile.dart';
import '../update_checker.dart';

/// 主题强调色（与通话页、按钮保持一致）
const _green = Color(0xFF07C160);
const _card = Color(0xFF1C1C1E);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _nameCtl = TextEditingController();
  final _tokenCtl = TextEditingController();
  String _emoji = ProfileStore.defaultEmoji;
  String _qualityKey = defaultQualityKey;
  Map<String, num> _stats = {'calls': 0, 'seconds': 0, 'mb': 0.0};

  // ---------- 检测更新状态 ----------
  bool _checking = false;
  bool _checked = false; // 查过一次、结果卡是否展开
  AppUpdate? _latest; // null 且 _checked → 检查失败

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _nameCtl.text = await ProfileStore.getName();
    _emoji = await ProfileStore.getEmoji();
    _tokenCtl.text = await Settings.getToken();
    _qualityKey = await Settings.getQuality();
    _stats = await CallStats.load();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _tokenCtl.dispose();
    super.dispose();
  }

  Widget _group(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text,
          style:
              const TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final minutes = ((_stats['seconds'] ?? 0) / 60).round();
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 我的资料 ----------
          _group('我的资料', [
            TextField(
              controller: _nameCtl,
              maxLength: 12,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: '昵称（留空则显示“对方”）',
                labelStyle: const TextStyle(color: Colors.white54),
                counterText: '',
                border: const OutlineInputBorder(),
                prefixIcon: Text(_emoji,
                    style: const TextStyle(fontSize: 20, height: 1.2)),
              ),
              onChanged: (v) => ProfileStore.setName(v),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              children: [
                for (final e in ProfileStore.emojis)
                  InkWell(
                    onTap: () {
                      ProfileStore.setEmoji(e);
                      setState(() => _emoji = e);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: e == _emoji
                            ? _green.withOpacity(.25)
                            : Colors.transparent,
                        border: Border.all(
                          color: e == _emoji ? _green : Colors.white24,
                        ),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
              ],
            ),
            _hint('通话时对方会看到你的昵称和头像，改动即时保存。'),
          ]),

          // ---------- 默认画质 ----------
          _group('默认画质', [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in qualities)
                  ChoiceChip(
                    label: Text(q.label.replaceAll(RegExp(r'（.*?）'), '')),
                    selected: q.key == _qualityKey,
                    // 显式设高对比色：选中=实心绿底白字，未选中=深灰底浅字。
                    // （之前未选中用的是 Colors.white10，在深色卡片上几乎看不见，且
                    // 某些 iOS Material3 表现下会出现“按钮是白的、字也是白的”看不清。）
                    selectedColor: _green,
                    backgroundColor: const Color(0xFF2C2C2E),
                    labelStyle: TextStyle(
                      color: q.key == _qualityKey ? Colors.white : Colors.white70,
                      fontSize: 12,
                      fontWeight: q.key == _qualityKey
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    onSelected: (_) async {
                      await Settings.setQuality(q.key);
                      setState(() => _qualityKey = q.key);
                    },
                  ),
              ],
            ),
            _hint('只影响你发出去的画面；你看到的画面由对方的档位决定。'),
          ]),

          // ---------- 累计流量 ----------
          _group('累计流量统计', [
            Row(
              children: [
                _statCell('${_stats['calls'] ?? 0}', '次'),
                _statCell('$minutes', '分钟'),
                _statCell(((_stats['mb'] ?? 0) as num).toStringAsFixed(1), 'MB'),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await CallStats.clear();
                  setState(() => _stats = {'calls': 0, 'seconds': 0, 'mb': 0.0});
                },
                child: const Text('清除记录',
                    style: TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            ),
            _hint('收发合计，按次累计（<3 秒的通话不计）。'),
          ]),

          // ---------- 高级 ----------
          _group('高级', [
            TextField(
              controller: _tokenCtl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                labelText: '临时 Token（仅 App ID 模式可留空）',
                labelStyle: TextStyle(color: Colors.white54),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => Settings.setToken(v.trim()),
            ),
            _hint('改动即时保存。双方 Token 必须一致（证书模式时）。'),
          ]),

          const SizedBox(height: 8),
          const Center(
            child: Text('对对视频 · 省流量的二人世界',
                style: TextStyle(color: Colors.white24, fontSize: 12)),
          ),

          // ---------- 软件更新 ----------
          const SizedBox(height: 18),
          _updateGroup(),
        ],
      ),
    );
  }

  // ============================================================ 软件更新

  Widget _updateGroup() {
    return _group('软件更新', [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('对对视频',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                const SizedBox(height: 3),
                Text(
                  '当前版本 ${currentBuild == 0 ? 'dev' : 'v1.0.$currentBuild'}'
                  '${Platform.isAndroid ? ' · 安卓' : ' · iOS'}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: _checking ? null : _checkUpdate,
            icon: _checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white54),
                  )
                : const Icon(Icons.system_update_alt, size: 16),
            label: Text(_checking ? '检查中…' : '检测更新',
                style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      // 结果区：检测有新版本 / 已是最新 / 失败 —— 三种都在这里「展开」
      if (_checked && !_checking) ...[
        const SizedBox(height: 12),
        _updateResult(),
      ],
    ]);
  }

  Future<void> _checkUpdate() async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _checked = false; // 收起上一次的结果，避免旧信息看着像新的
      _latest = null;
    });
    final latest = await fetchLatestUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checked = true;
      _latest = latest;
    });
  }

  Widget _updateResult() {
    final latest = _latest;
    if (latest == null) return _failedCard();
    if (latest.build <= currentBuild) return _upToDateCard(latest);
    return _newVersionCard(latest);
  }

  /// 有新版本：版本号 + 大小 + 更新说明 + 下载按钮。
  /// ⚠️ 这里【不发起任何下载】，只有点下面的按钮才会打开真正的下载地址。
  Widget _newVersionCard(AppUpdate latest) {
    final size = latest.sizeText;
    final actions = _downloadActions(latest);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12261A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _green.withOpacity(.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.arrow_circle_up, color: _green, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '发现新版本 v${latest.version}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (size.isNotEmpty) _chip('大小 $size'),
            ],
          ),
          const SizedBox(height: 10),
          const Text('更新说明',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 5),
          // 说明可能很长（CI 把提交历史都塞进来了），限高 + 可滚动，别把整页撑爆。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 170),
            child: SingleChildScrollView(
              child: Text(
                latest.notes?.trim().isNotEmpty == true
                    ? latest.notes!
                    : '（本次没有填写更新说明）',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.55),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('来源：${latest.source}',
              style: const TextStyle(color: Colors.white24, fontSize: 11)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: actions,
          ),
          // iOS 当前没有匿名可访问的 IPA 地址，把「要多走哪几步」直接写在卡上，
          // 免得用户点开看到登录页以为坏了。
          if (_iosNeedsLoginDownload(latest)) ...[
            const SizedBox(height: 8),
            const Text(
              '未签名版装不进系统：点「打开蒲公英下载」→ 登录蒲公英后在版本管理里点下载 '
              '拿到 IPA → 用 TrollStore 打开它完成安装。'
              '（也可用「GitHub 下载页」，在浏览器登录 GitHub 后下载。）',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11.5, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _upToDateCard(AppUpdate latest) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已是最新版本（本机 v${currentBuild == 0 ? 'dev' : '1.0.$currentBuild'}，'
              '线上 v${latest.version}）',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _failedCard() {
    final tried = lastUpdateAttempts.isEmpty
        ? '（没发出任何请求）'
        : lastUpdateAttempts.map((e) => '· $e').join('\n');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withOpacity(.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
              SizedBox(width: 6),
              Text('检查更新失败',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '三路都取不到版本信息（本机 v${currentBuild == 0 ? 'dev' : '1.0.$currentBuild'}）。来源明细：\n$tried',
            style: const TextStyle(
                color: Colors.white60, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            '蒲公英公开页通常是最稳的一路，它都失败多半是当前网络到不了蒲公英。'
            '换网络再试，或直接到下载页看看。',
            style: TextStyle(color: Colors.white38, fontSize: 11.5, height: 1.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // 「打开下载页」兜底入口：安卓 = 蒲公英公开下载页，iOS = 蒲公英管理中心
              // （登录后能看到 iOS 版本列表）。对应标识未注入时返回空串 → 按钮隐藏。
              if (_fallbackUrl().isNotEmpty)
                TextButton(
                  onPressed: () => openLink(_fallbackUrl()),
                  child: const Text('打开下载页',
                      style: TextStyle(color: _green, fontSize: 13)),
                ),
              TextButton(
                onPressed: () => setState(() => _checked = false),
                child: const Text('收起',
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// iOS 且拿不到任何匿名可访问的 IPA 直链 → 只能引导用户去「已登录」的页面自己下。
  bool _iosNeedsLoginDownload(AppUpdate latest) =>
      !Platform.isAndroid &&
      (latest.iosTrollstore?.isNotEmpty != true) &&
      (latest.iosGithubUrl?.isNotEmpty != true);

  /// 「打开下载页」兜底入口：安卓 = 蒲公英公开下载页，iOS = 蒲公英管理中心
  /// （登录后能看到 iOS 版本列表，未签名 IPA 从那里下载）。
  /// 对应标识未在构建期注入时返回空串，按钮应隐藏。
  String _fallbackUrl() =>
      Platform.isAndroid ? pgyerPageUrl : pgyerDashboardUrl;

  /// 按平台给出下载按钮。此处只是拼按钮，**不触发下载**。
  List<Widget> _downloadActions(AppUpdate latest) {
    final list = <Widget>[];
    if (Platform.isAndroid) {
      // 直装链接优先：手机浏览器打开即开始下载 APK，不用再跳页面找按钮。
      final apk = latest.androidApkUrl;
      final page = latest.androidUrl ?? pgyerPageUrl;
      if (apk != null && apk.isNotEmpty) {
        list.add(FilledButton.icon(
          onPressed: () => openLink(apk),
          icon: const Icon(Icons.download, size: 16),
          label: const Text('下载安装包', style: TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
          ),
        ));
        // 留个后路：万一直装链接在某个浏览器里被拦（或蒲公英当天额度用尽），
        // 用户还能走下载页手动点。
        if (page.isNotEmpty) {
          list.add(TextButton(
            onPressed: () => openLink(page),
            child: const Text('下载页',
                style: TextStyle(color: _green, fontSize: 13)),
          ));
        }
      } else if (page.isNotEmpty) {
        // 没拿到直链 → 去下载页手动点一下
        list.add(FilledButton.icon(
          onPressed: () => openLink(page),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('前往下载页', style: TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
          ),
        ));
      }
    } else {
      // iOS：未签名 IPA 系统装不上，只有【匿名可访问】的直链才谈得上自动下载 ——
      // TrollStore 自己发起请求时带不了 GitHub 登录态，而源码仓库是 private。
      final ts = latest.iosTrollstore;
      final gh = latest.iosGithubUrl;
      if (ts != null && ts.isNotEmpty) {
        // 一键装：只有「建了公开产物仓库 + 配了 RELEASE_REPO」才会走到这里
        list.add(FilledButton.icon(
          onPressed: () => openLink(ts),
          icon: const Icon(Icons.download, size: 16),
          label: const Text('用 TrollStore 安装', style: TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
          ),
        ));
      }
      if (gh != null && gh.isNotEmpty) {
        list.add(TextButton(
          onPressed: () => openLink(gh),
          child: const Text('下载 IPA', style: TextStyle(color: _green, fontSize: 13)),
        ));
      }
      if (_iosNeedsLoginDownload(latest)) {
        // 没有任何匿名可访问的 IPA 直链 → 走【已登录】的页面自己下：
        // 主入口是蒲公英管理中心（版本管理里点下载即得现签链接）；
        // 备用入口是源码仓库的 Release 页面（手机上登录 GitHub 也能下到）。
        // 管理中心依赖构建期注入的 PGYER_APP_KEY，未注入 → 只显示 GitHub 下载页。
        if (pgyerDashboardUrl.isNotEmpty) {
          list.add(FilledButton.icon(
            onPressed: () => openLink(pgyerDashboardUrl),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('打开蒲公英下载', style: TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
            ),
          ));
        }
        list.add(TextButton(
          onPressed: () => openLink(sourceReleasePageUrl),
          child: const Text('GitHub 下载页',
              style: TextStyle(color: _green, fontSize: 13)),
        ));
      }
    }
    list.add(TextButton(
      onPressed: () => setState(() => _checked = false),
      child: const Text('稍后', style: TextStyle(color: Colors.white38, fontSize: 13)),
    ));
    return list;
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
    );
  }

  Widget _statCell(String value, String unit) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 3),
              Text(unit,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
