// 检测更新：两路取源，合并出「最新版本 + 更新说明 + 包大小 + 下载入口」。
//
//   ① 蒲公英 API   apiv2/app/check —— 信息最全：版本号、更新说明、包大小、直装链接
//      需要构建期注入 PGYER_API_KEY + PGYER_APP_KEY（见 .github/workflows/build.yml）。
//      没有注入时自动跳过 —— 源码仓库里不落任何凭据，本地开发构建也照常能跑。
//   ② 蒲公英公开页（零凭据兜底）—— 页面是服务端渲染的，版本/大小/更新说明都能正则取到
//
// 两路【并发】发起：API 有更新说明、大小和直装链接；公开页零凭据永远可用。
// 合并规则：取 build 号最大的那条做基准，再用另一条的非空字段补全。
//
// ⚠️ 曾经的第三路 version.json（GitHub Release 资源）已移除：国内访问 GitHub
//    时常 502/完全不通，而合并要等最慢的一路，导致每次「检测更新」被它拖到
//    超时才出结果。随之变化：iOS 一键装（apple-magnifier://）与 GitHub 直链
//    不再出现，iOS 下载入口 = 「打开蒲公英下载」（管理中心，登录后下载，国内快）。
//
// iOS 下载路径的现状：蒲公英的 IPA 存在私有 OSS 上且签名直链要登录态现签，
// 所以 iOS 的下载按钮 = 打开【蒲公英管理中心里本应用的版本列表页】
// （见 pgyerDashboardUrl，需登录蒲公英），在那里点下载拿到 IPA，再用 TrollStore
// 打开安装；另留一个源码仓库 Release 页面作备用入口。
//
// ⚠️ 应用标识（声网 App ID / 蒲公英短链 / appKey）不写在源码里：仓库公开后任何人可读，
// 全部走构建期 --dart-define 注入（真值放 GitHub Secrets），见下方「构建期注入」注释块。
//
// ⚠️ 蒲公英 API 的 downloadURL 里带 _api_key（官方文档明示属敏感链接）：只留在内存里，
// 不打印、不写日志、不落盘。要停用这条路，把 build.yml 里的两个 --dart-define 去掉即可，
// 代码会自动退回「公开页解析 + 跳蒲公英页下载」。
import 'dart:convert';
// 只为按平台各取自己的安装包大小（version.json 里分了 size_bytes_android / size_bytes_ios）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------- 构建期注入

/// 蒲公英凭据。两个都非空时才会走 API 源。
const _pgyerApiKey = String.fromEnvironment('PGYER_API_KEY');
const _pgyerAppKey = String.fromEnvironment('PGYER_APP_KEY');

/// 是否已注入蒲公英凭据（未注入 → API 源自动跳过，一切照旧）。
bool get pgyerApiEnabled => _pgyerApiKey.isNotEmpty && _pgyerAppKey.isNotEmpty;

/// 蒲公英管理中心里【本应用】的版本列表页（需登录蒲公英）。
/// iOS 靠它拿 IPA：登录后进版本管理点「下载」得到现签链接，再用 TrollStore 装。
/// 未注入 appKey（本地 dev 构建）→ 返回空串，设置页隐藏该按钮。
String get pgyerDashboardUrl =>
    _pgyerAppKey.isEmpty ? '' : 'https://www.pgyer.com/dashboard/?agKey=$_pgyerAppKey';

const _pgyerCheckUrl = 'https://www.pgyer.com/apiv2/app/check';

// ---------- 应用标识：全部构建期注入（--dart-define），源码不落任何真实值 ----------
// 真值放 GitHub **Secrets**（不是 Variables）：iOS 构建用 --verbose，dart-define 的值
// 可能被打进构建日志，而公开仓库的构建日志人人可见 —— Secrets 会被 GitHub 自动打码。
// 某个标识未注入时（如本地 dev 构建），对应的数据源/入口自动停用，不影响其他功能。

/// 本平台蒲公英公开下载页的短链名（Secrets：PGYER_SHORTCUT_ANDROID / PGYER_SHORTCUT_IOS）。
/// 两个平台是两个独立应用、短链不同，用错会读到另一个平台的版本号与包大小。
const _shortcutAndroid = String.fromEnvironment('PGYER_SHORTCUT_ANDROID');
const _shortcutIos = String.fromEnvironment('PGYER_SHORTCUT_IOS');

/// 本平台的蒲公英公开下载页（零凭据可访问、服务端渲染）。
/// 未注入短链 → 返回空串，调用方按空停用「公开页解析」源与「前往下载页」入口。
/// 页面上「版本：1.0.<n>」的 n 就是 CI 的 run_number；页面下方还有历史版本，
/// 所以解析时要取所有匹配里的**最大值**。
String get pgyerPageUrl {
  final s = Platform.isAndroid ? _shortcutAndroid : _shortcutIos;
  return s.isEmpty ? '' : 'https://www.pgyer.com/$s';
}

/// CI 构建时解析并注入的本平台蒲公英 appKey（--dart-define=PGYER_APP_KEY，来自 Secrets）。
/// 两个用途：① 让「设置 → 检测更新」调 apiv2/app/check（见 pgyerApiEnabled）；
/// ② 拼「蒲公英管理中心」直达入口；CI 由 scripts/resolve_pgyer_appkey.py 实证解析后注入。

/// 本机构建号（构建时由 --dart-define=APP_BUILD=run_number 注入）。
int get currentBuild {
  const fromDefine = String.fromEnvironment('APP_BUILD', defaultValue: '0');
  return int.tryParse(fromDefine) ?? 0;
}

/// 源码仓库（private）。只用来给 iOS 提供「Release 页面」入口：
/// 用户在手机浏览器里登录 GitHub 后，可以在该页下载 IPA，再用 TrollStore 打开安装。
/// 构建时由 CI 注入 --dart-define=SOURCE_REPO=owner/repo，默认值与仓库实际地址一致。
const _sourceRepo = String.fromEnvironment('SOURCE_REPO',
    defaultValue: 'lonelyplant/duidui-videochat');

/// 源码仓库的最新 Release 页面。私库匿名访问是 404，但**登录后可用**——
/// 作为 iOS 「自己下到 IPA」的备用入口（主入口是下面的蒲公英管理中心）。
String get sourceReleasePageUrl => 'https://github.com/$_sourceRepo/releases/latest';

/// 兜底用的蒲公英 agKey 已移除：源码不再落任何应用标识。
/// 「管理中心」直达入口只用构建期注入的 PGYER_APP_KEY（见 pgyerDashboardUrl）；
/// 未注入时入口隐藏，更新检测退回「蒲公英公开页解析」一路（零凭据可用）。
/// version.json（GitHub Release 资源）一路已移除：国内访问 GitHub 时常不通，
/// 曾把每次「检测更新」拖到超时，见文件头部说明。

// ---------------------------------------------------------------- 数据模型

/// 最新版本信息。两路源合并后的结果，各字段都可能为 null。
class AppUpdate {
  final int build; // 用于比较的 build 号（= CI run_number）
  final String version; // 形如 1.0.41
  final String? notes; // 更新说明（纯文本，可能多行）
  final int? sizeBytes; // 安装包大小（字节）
  final String? androidUrl; // 蒲公英应用页（兜底入口）
  final String? androidApkUrl; // 安卓直装/直下链接（浏览器打开即开始下载）
  final String? iosPgyerUrl; // 蒲公英签名 IPA 直链（仅几分钟时效，通常为空）
  final String? iosPgyerManagerUrl; // 蒲公英管理中心直下链接（国内快，需浏览器有蒲公英登录态）
  final String? iosGithubUrl; // 公开 Release 的 IPA 直链（永久有效）
  final String? iosTrollstore; // apple-magnifier:// 一键装 scheme
  final String source; // 来源标记，排错用（如 pgyer-api+version.json）

  const AppUpdate({
    required this.build,
    required this.version,
    this.notes,
    this.sizeBytes,
    this.androidUrl,
    this.androidApkUrl,
    this.iosPgyerUrl,
    this.iosPgyerManagerUrl,
    this.iosGithubUrl,
    this.iosTrollstore,
    this.source = '',
  });

  factory AppUpdate.fromJson(Map<String, dynamic> j) => AppUpdate(
        build: _toInt(j['build']) ?? 0,
        version: '${j['version'] ?? ''}',
        // 一律 toString：version.json 是 CI 手写的 JSON，字段类型别太当真
        notes: _cleanNotes(j['notes']?.toString()),
        // 两个平台的安装包大小分开写，各取各的（否则 iOS 会显示成安卓 APK 的体积）
        sizeBytes: _toInt(
            j[Platform.isAndroid ? 'size_bytes_android' : 'size_bytes_ios']),
        androidUrl: _link(j['android_url']),
        androidApkUrl: _link(j['android_apk_url']),
        iosPgyerUrl: _link(j['ios_pgyer_url']),
        iosPgyerManagerUrl: _link(j['ios_pgyer_manager_url']),
        iosGithubUrl: _link(j['ios_github_url']),
        iosTrollstore: _link(j['ios_trollstore']),
        source: 'version.json',
      );

  /// 用 [other] 的非空字段补全自己：build 号大的那份做基准，另一份只填空缺。
  AppUpdate mergeWith(AppUpdate? other) {
    if (other == null) return this;
    final AppUpdate base = other.build > build ? other : this;
    final AppUpdate extra = identical(base, this) ? other : this;
    return AppUpdate(
      build: base.build,
      version: base.version.isNotEmpty ? base.version : extra.version,
      notes: base.notes ?? extra.notes,
      sizeBytes: base.sizeBytes ?? extra.sizeBytes,
      androidUrl: base.androidUrl ?? extra.androidUrl,
      androidApkUrl: base.androidApkUrl ?? extra.androidApkUrl,
      iosPgyerUrl: base.iosPgyerUrl ?? extra.iosPgyerUrl,
      iosPgyerManagerUrl: base.iosPgyerManagerUrl ?? extra.iosPgyerManagerUrl,
      iosGithubUrl: base.iosGithubUrl ?? extra.iosGithubUrl,
      iosTrollstore: base.iosTrollstore ?? extra.iosTrollstore,
      source: [base.source, extra.source]
          .where((s) => s.isNotEmpty)
          .toSet()
          .join('+'),
    );
  }

  /// 人类可读的包大小，如 `48.5 MB`；取不到返回空串。
  String get sizeText {
    final b = sizeBytes;
    if (b == null || b <= 0) return '';
    const mb = 1048576;
    if (b >= mb) return '${(b / mb).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }
}

// ---------------------------------------------------------------- 三路取源

/// 上一次 fetchLatestUpdate 的逐源结果，供失败提示展示 ——
/// 不用连电脑抓日志，在手机上就能看出到底是「没网」「404」还是「凭据失效」。
/// ⚠️ 这里只记状态码与来源名，绝不记 URL 查询串（可能含 _api_key）。
final List<String> lastUpdateAttempts = <String>[];

/// 两路并发取源并合并；全都失败返回 null。
Future<AppUpdate?> fetchLatestUpdate(
    {Duration timeout = const Duration(seconds: 15)}) async {
  lastUpdateAttempts.clear();
  final results = await Future.wait<AppUpdate?>([
    fetchFromPgyerApi(timeout: timeout),
    fetchFromPgyerPage(timeout: timeout),
  ]);
  AppUpdate? best;
  for (final r in results) {
    if (r == null) continue;
    best = best == null ? r : best.mergeWith(r);
  }
  return best;
}

/// ① 蒲公英 API：信息最全的一路。未注入凭据时直接跳过。
Future<AppUpdate?> fetchFromPgyerApi(
    {Duration timeout = const Duration(seconds: 15)}) async {
  if (!pgyerApiEnabled) {
    lastUpdateAttempts.add('跳过 · 未注入蒲公英凭据（PGYER_API_KEY / PGYER_APP_KEY）');
    return null;
  }
  try {
    final resp = await http
        .post(
          Uri.parse(_pgyerCheckUrl),
          body: {
            '_api_key': _pgyerApiKey,
            'appKey': _pgyerAppKey,
            // 带上本机版本，蒲公英据此给出 buildHaveNewVersion / needForceUpdate。
            // 注意：不能传 buildBuildVersion —— 那是蒲公英自己的自增号（如 22），
            // 与我们的 APP_BUILD（= CI run_number）不是同一个东西。
            'buildVersion': '1.0.$currentBuild',
          },
        )
        .timeout(timeout);
    if (resp.statusCode != 200) {
      lastUpdateAttempts.add('HTTP ${resp.statusCode} · 蒲公英 API check');
      return null;
    }
    final j = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final code = _toInt(j['code']) ?? -1;
    if (code != 0) {
      // message 只是错误描述（如「_api_key not found」），不含凭据，可以安全展示。
      lastUpdateAttempts.add(
          'code=$code ${j['message'] ?? ''} · 蒲公英 API（0=成功，1001/1002=凭据无效）');
      return null;
    }
    final d = (j['data'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    lastUpdateAttempts.add('HTTP 200 / code=0 · 蒲公英 API check');

    final ver = '${d['buildVersion'] ?? ''}'.trim();
    // CI 用 --build-name=1.0.<run_number> 构建两个平台，所以优先按这个格式取 run_number；
    // 格式对不上再退到 versionCode，最后才是「版本名末尾的数字」兜底。
    int build = 0;
    final m10 = RegExp(r'^1\.0\.(\d{1,7})$').firstMatch(ver);
    if (m10 != null) {
      build = int.tryParse(m10.group(1)!) ?? 0;
    } else {
      build = _toInt(d['buildVersionNo']) ?? 0;
      if (build == 0) {
        final tail = RegExp(r'(\d{1,7})\s*$').firstMatch(ver);
        if (tail != null) build = int.tryParse(tail.group(1)!) ?? 0;
      }
    }
    return AppUpdate(
      build: build,
      version: ver,
      // 全部走 toString 兜底：蒲公英偶有字段类型漂移（数字/字符串），
      // 一个类型转换异常会连带整路 API 源作废，不值得。
      notes: _cleanNotes(d['buildUpdateDescription']?.toString()),
      sizeBytes: _toInt(d['buildFileSize']),
      androidUrl: _link(pgyerPageUrl),
      // downloadURL 里带 _api_key：只在本机内存里用，绝不打印。
      // 安卓上打开它 = 直接开始下载 APK；iOS 上它走 itms-services（未签名装不上，不采用）。
      androidApkUrl: _link(d['downloadURL']),
      source: 'pgyer-api',
    );
  } catch (e) {
    lastUpdateAttempts.add('${e.runtimeType} · 蒲公英 API check');
    return null;
  }
}

/// ② 蒲公英公开页（零凭据兜底）：版本、大小、更新说明都能从 SSR 的 HTML 里取到。
Future<AppUpdate?> fetchFromPgyerPage(
    {Duration timeout = const Duration(seconds: 15)}) async {
  // 短链未注入（本地 dev 构建）→ 这一路数据源整个停用
  if (pgyerPageUrl.isEmpty) {
    lastUpdateAttempts.add('跳过 · 未注入蒲公英短链（PGYER_SHORTCUT_*）');
    return null;
  }
  try {
    // 带浏览器 UA：蒲公英对非常规客户端可能返回拦截页，带上 UA 稳一点。
    final resp = await http.get(Uri.parse(pgyerPageUrl), headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml',
    }).timeout(timeout);
    lastUpdateAttempts.add('HTTP ${resp.statusCode} · 蒲公英公开页');
    if (resp.statusCode != 200) return null;
    final html = utf8.decode(resp.bodyBytes, allowMalformed: true);

    // 版本：页面下方还列着历史版本，build 号只增不减，取所有匹配里的最大值最稳。
    var best = 0;
    for (final m in RegExp(r'1\.0\.(\d{1,7})').allMatches(html)) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > best) best = n;
    }
    if (best <= 0) return null;

    // 大小：面包屑里是「大小：48.5 MB」/「大小：60.1 MB」
    // ✅ 现在取的是**本平台**的页面（安卓 APK 48.5MB / iOS IPA 60.1MB 各自独立），
    //    所以这个值可以直接用；早前那个「iOS 上把大小置空」的补丁是因为当时两个平台
    //    都读安卓页，会把 APK 体积当成 IPA 的体积。
    int? sizeBytes;
    final ms = RegExp(r'大小[：:]\s*([\d.]+)\s*(GB|MB|KB|B)',
            caseSensitive: false)
        .firstMatch(html);
    if (ms != null) {
      final v = double.tryParse(ms.group(1)!);
      final unit = ms.group(2)!.toUpperCase();
      const k = 1024;
      final mul = switch (unit) {
        'GB' => k * k * k,
        'MB' => k * k,
        'KB' => k,
        _ => 1,
      };
      if (v != null) sizeBytes = (v * mul).round();
    }

    // 更新说明：<div class="update-description"> … </div>
    String? notes;
    final mn = RegExp(r'class="update-description"[^>]*>([\s\S]*?)</div>')
        .firstMatch(html);
    if (mn != null) notes = _cleanNotes(mn.group(1));

    return AppUpdate(
      build: best,
      version: '1.0.$best',
      notes: notes,
      sizeBytes: sizeBytes, // 本平台页面 → 本平台体积，可直接用（见上）
      androidUrl: _link(pgyerPageUrl),
      // 兜底路径拿不到文件直链：安卓点开下载页手动装一下就行；
      // iOS 连页面都装不上（未签名），由 UI 层改走「蒲公英管理中心」入口。
      source: 'pgyer-page',
    );
  } catch (e) {
    lastUpdateAttempts.add('${e.runtimeType} · 蒲公英公开页');
    return null;
  }
}

// ---------------------------------------------------------------- 工具

/// 打开外链 / scheme；失败仅打印（不抛，避免卡住 UI）。
Future<void> openLink(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[duidui] 打开链接失败 -> $e');
  }
}

int? _toInt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final s = v.toString().replaceAll(RegExp(r'[^0-9]'), '');
  return s.isEmpty ? null : int.tryParse(s);
}

/// 链接字段归一化：空串 → null（=「没有这个入口」）。
/// version.json / 蒲公英接口里的链接可能给空串，统一归 null 后 UI 层的
/// `?? 兜底` 与 isNotEmpty 判断才不会拿着空串去 openLink。
String? _link(dynamic v) {
  final s = v?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

/// HTML 片段 → 纯文本：保留换行、去掉标签、还原常见实体。
String? _cleanNotes(String? raw) {
  if (raw == null) return null;
  var s = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  // 压掉多余空行（蒲公英页面的 div 里带大量缩进空白）
  s = s
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n')
      .trim();
  return s.isEmpty ? null : s;
}
