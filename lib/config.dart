// 对对视频 — 全局配置：画质档位等
//
// ⚠️ 声网 App ID 等应用标识不写在源码里：仓库公开后任何人可读，
//    全部走构建期 --dart-define 注入（真值放 GitHub Secrets，公开仓库也读不到），
//    见 build.yml 与 scripts/resolve_pgyer_appkey.py 头部说明。

/// 声网项目 App ID：CI 构建时由 --dart-define=AGORA_APP_ID 注入。
/// 留空 = 本次构建没注入（如本地直接 flutter run）——进入房间时会提示。
/// 本地开发：flutter run --dart-define=AGORA_APP_ID=<你的ID>
const String agoraAppId = String.fromEnvironment('AGORA_APP_ID');

/// CI 构建号：workflow 里 --dart-define=APP_BUILD=${{ github.run_number }} 注入，
/// 与 GitHub Actions 的 run number / 蒲公英的构建号一致，用于分辨手机上装的是不是最新包。
/// 本地 flutter run 未注入时显示 dev。
const String appBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');

/// 画质档位。竖屏 9:16 比例，与采集同方向，原生端用 orientationModeFixedPortrait 真正旋转像素
/// （这正是 Web 端做不到、导致“脸被放大”的根因；原生 SDK 原生支持，无需 canvas 旋转）。
///
/// [dim] 为编码器输出分辨率；[fps] 帧率；[bitrate] 码率上限(kbps)。
/// [mbPerHour] 为「本机」单小时流量估算（上下行合计约 = 码率×3.6×2 / 1000），用于档位标签。
class QualityTier {
  final String key;
  final String label;
  final int w;
  final int h;
  final int fps;
  final int bitrate;
  final String mbPerHour;

  const QualityTier(this.key, this.label, this.w, this.h, this.fps, this.bitrate, this.mbPerHour);
}

const List<QualityTier> qualities = [
  QualityTier('audio', '仅语音', 0, 0, 0, 0, '约 22MB/时'),
  // 极省档：比 90p 再低一档，给“能看清脸就行、流量能省则省”的场景（如对方在弱网/按量计费）
  QualityTier('extreme', '极省 64p', 64, 112, 8, 30, '约 20~30MB/时'),
  QualityTier('90', '省流 90p', 90, 160, 10, 60, '约 35~45MB/时'),
  QualityTier('120', '省流 120p（默认）', 120, 216, 12, 90, '约 55~75MB/时'),
  QualityTier('180', '流畅 180p', 180, 320, 15, 170, '约 110~150MB/时'),
  QualityTier('240', '清晰 240p', 240, 426, 15, 250, '约 160~220MB/时'),
  QualityTier('360', '高清 360p', 360, 640, 15, 500, '约 320~430MB/时'),
  // 720p 用 15fps 而不是 20fps：说话人头场景 15fps 足够，编码 CPU 和流量省约 1/4
  QualityTier('720', '超清 720p', 720, 1280, 15, 1100, '约 700~950MB/时'),
];

const String defaultQualityKey = '120';

QualityTier qualityByKey(String key) =>
    qualities.firstWhere((q) => q.key == key, orElse: () => qualities[2]);
