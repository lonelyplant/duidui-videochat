// 悬浮窗（PiP）封装：直接使用声网 Flutter SDK 6.6.2+ 自带的官方 AgoraPipController。
//
// 为什么不用自写原生桥（历史教训）：
//   iOS 的 AgoraRtcEngineKit **没有** startPictureInPicture / stopPictureInPicture 方法，
//   声网的画中画能力封装在 SDK 内部（AVPictureInPictureController），只通过
//   createPipController() → pipSetup() / pipStart() / pipStop() 这条 Dart 通道暴露。
//   之前自写 MethodChannel + `kit.startPictureInPicture()` 会让 Xcode 直接编译失败：
//   "value of type 'AgoraRtcEngineKit' has no member 'startPictureInPicture'"。
//
// 官方接口（v6.6.2 起）：
//   final c = engine.createPipController();
//   c.registerPipStateChangedObserver(AgoraPipStateChangedObserver(...));
//   await c.pipIsSupported(); await c.pipIsAutoEnterSupported();
//   await c.pipSetup(AgoraPipOptions(...));
//   await c.pipStart();   // iOS 必须由用户手势触发（点按钮），不能自动调用
//   await c.pipStop();    // 会话级停止
//   await c.pipDispose(); // 释放 PiP 资源
//   await c.dispose();    // 控制器本身不再需要时释放
//
// 平台前提：
//   安卓：AndroidManifest 的 Activity 声明 android:supportsPictureInPicture="true"
//         （且 configChanges 含 screenSize|smallestScreenSize|screenLayout|orientation），
//         MainActivity 继承 AgoraPIPFlutterActivity 才能支持「按 Home 自动进小窗」。
//   iOS：需 iOS 15+，Info.plist 的 UIBackgroundModes 含 audio（已配置）。
//
// 【画面选择策略】小窗**永远只显示一路画面**：
//   对方在房间里 → 显示对方；对方还没进来 → 显示自己。
//   所以布局恒为 1 行 1 列，不存在空格子（之前按 2 格布局时，单人场景下半屏会全黑）。
//
// 【已知限制】iOS 上小窗里的「自己」会静止（冻结在进入小窗的那一帧）：
//   进入 PiP 后 App 会退到后台，iOS 会暂停 App 的摄像头采集；iOS 16+ 要求开启
//   AVCaptureSession.multitaskingCameraAccessEnabled 才能在后台继续采集，而这个开关
//   必须在原生侧设置，声网 Flutter SDK 目前没有暴露（官方 issue #2429 标注 coming soon）。
//   → 这是系统/SDK 限制，Dart 侧无法绕过；远端画面不受影响，照常动态。
//   → 实际影响很小：只要对方在场，小窗显示的就是对方，画面正常。
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';

import 'rtc_manager.dart';

class PipHelper {
  AgoraPipController? _controller;
  String? _lastError;

  /// 悬浮窗是否活跃。安卓的悬浮窗显示的是整个 Activity 画面（整个 Flutter 界面），
  /// 不像 iOS 那样由 SDK 托管原生视图只渲染 videoStreams —— 所以悬浮窗激活时，
  /// 通话页必须监听这个状态把按钮等控件藏起来，小窗里才会只剩视频画面。
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);
  bool get isActive => activeNotifier.value;
  void _setActive(bool v) => activeNotifier.value = v;

  /// 当前小窗里显示的是谁：null = 本地自己，非 null = 远端 uid。
  /// 用于判断对方进/出房间时是否真的需要重配小窗。
  int? _shownUid;

  /// 最近一次 pipSetup 布局对应的 uid（prepareAutoEnter 去重用）。
  int? _preparedUid;

  /// 小窗当前显示的是远端 uid（null 表示显示的是自己）。
  int? get shownUid => _shownUid;

  /// 最近一次失败原因，供 UI 提示用。
  String? get lastError => _lastError;

  AgoraPipController? _ensureController() {
    final engine = rtc.engine;
    if (engine == null) return null;
    if (_controller != null) return _controller;
    final controller = engine.createPipController();
    controller.registerPipStateChangedObserver(AgoraPipStateChangedObserver(
      onPipStateChanged: (state, error) {
        _setActive(state == AgoraPipState.pipStateStarted);
        if (error != null && error.isNotEmpty) _lastError = error;
        debugPrint('[duidui] pip state=$state error=${error ?? '-'}');
      },
    ));
    _controller = controller;
    return controller;
  }

  /// 系统侧此刻是否真的处在 PiP 里。
  ///
  /// 别用 activeNotifier 代替：安卓上 FlutterActivity 不会把 PiP 状态变化转发给 Dart
  /// 侧（声网文档专门为此提供了 useExternalStateMonitor 开关），那个状态可能滞后。
  /// 这里是直接问原生控制器，用来判断「点了悬浮窗按钮之后到底进没进小窗」最准。
  Future<bool> isActivated() async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      return await controller.isPipActivated();
    } catch (_) {
      return false;
    }
  }

  /// 当前设备是否支持悬浮窗（iOS 需 15+；安卓需 8+ 且系统允许）。
  Future<bool> isSupported() async {
    final controller = _ensureController();
    if (controller == null) return false;
    try {
      return await controller.pipIsSupported();
    } catch (e) {
      _lastError = '$e';
      return false;
    }
  }

  /// 进入悬浮窗。
  ///
  /// [remoteUid] 为空时小窗只显示本地画面（对方还没进房）。
  /// 注意：iOS 要求由用户手势触发，务必从按钮点击里调用。
  Future<bool> start({int? remoteUid}) async {
    final controller = _ensureController();
    if (controller == null) {
      _lastError = '通话尚未开始';
      return false;
    }
    try {
      if (!await controller.pipIsSupported()) {
        _lastError = '当前设备不支持悬浮窗';
        return false;
      }
      final autoEnter = await controller.pipIsAutoEnterSupported();
      await controller.pipSetup(_buildOptions(remoteUid, autoEnterEnabled: autoEnter));
      final ok = await controller.pipStart();
      _setActive(ok);
      if (ok) {
        _shownUid = remoteUid;
        _preparedUid = remoteUid; // start 里也真实 setup 过一次
      } else {
        _lastError = '悬浮窗启动失败（系统可能未允许）';
      }
      return ok;
    } catch (e) {
      _lastError = '$e';
      debugPrint('[duidui] pip start failed: $e');
      return false;
    }
  }

  /// 进通话时「布好」悬浮窗，但不真正启动：等系统/按 Home 自动进小窗用。
  ///
  /// 关键：Agora 的「退后台自动进 PiP」(autoEnterEnabled) 只在 **已经 pipSetup 过** 时才生效，
  /// 所以一进通话就必须 setup 一次（不调 pipStart）。这样：
  ///   - 安卓按 Home → AgoraPIPFlutterActivity 自动进小窗；
  ///   - iOS 退后台 → 系统自动进小窗（autoEnter 由系统触发，不受“必须用户手势”限制）。
  /// [remoteUid] 为当前该显示的方（null = 自己）；对方进/出房时由 call_page 重新调用刷新布局。
  Future<void> prepareAutoEnter({int? remoteUid}) async {
    if (isActive) return; // 已经在小窗里了，交给 refresh/stop 处理
    // 同一个 uid 已经布过局就别反复 pipSetup：每次 setup 都是两次平台通道往返，
    // 重复 setup 还可能让小窗闪一下（与 refresh 的去重同理）。
    // 控制器被 dispose 重建后 _preparedUid 已清空，不会误跳过。
    if (_controller != null && _preparedUid == remoteUid) return;
    final controller = _ensureController();
    if (controller == null) return;
    try {
      final autoEnter = await controller.pipIsAutoEnterSupported();
      await controller.pipSetup(_buildOptions(remoteUid, autoEnterEnabled: autoEnter));
      _preparedUid = remoteUid;
      debugPrint('[duidui] pip prepared (autoEnter=$autoEnter) for remoteUid=${remoteUid ?? '-'}');
    } catch (e) {
      debugPrint('[duidui] pip prepareAutoEnter failed: $e');
    }
  }

  /// 组装 PiP 选项：恒为 1 格。
  AgoraPipOptions _buildOptions(int? remoteUid, {required bool autoEnterEnabled}) {
    return AgoraPipOptions(
      // 切到后台自动进小窗（安卓 12+ / iOS 支持时最顺滑）
      autoEnterEnabled: autoEnterEnabled,

      // ---------- 安卓 ----------
      // 竖屏通话：小窗按 9:16 显示
      aspectRatioX: 9,
      aspectRatioY: 16,
      seamlessResizeEnabled: true,

      // ---------- iOS ----------
      // 0 = 让 SDK 自己托管 PiP 里的原生视图与布局
      sourceContentView: 0,
      contentView: 0,
      preferredContentWidth: 360,
      preferredContentHeight: 640,
      // 2 = 只保留「关闭 / 恢复」按钮，去掉播放控制（通话场景推荐）
      controlStyle: 2,
      // 只显示一路 → 永远 1 行 1 列，不会有空格子
      contentViewLayout: AgoraPipContentViewLayout(
        row: 1,
        column: 1,
        spacing: 0,
      ),
      videoStreams: _buildStream(remoteUid),
    );
  }

  /// 对方进/出房间后重配小窗（正在悬浮窗中时才生效）。
  ///
  /// PiP 的视频流是在 pipSetup 时固定的，对方后加入不会自动补上，
  /// 所以要重新 setup 一次：自己 ⇄ 对方。
  Future<void> refresh({int? remoteUid}) async {
    final controller = _controller;
    if (controller == null || !isActive) return;
    // 显示的还是同一方（比如重复的回调）就别折腾了，反复 setup 会让小窗闪一下
    if (_shownUid == remoteUid) return;
    try {
      final autoEnter = await controller.pipIsAutoEnterSupported();
      await controller.pipSetup(_buildOptions(remoteUid, autoEnterEnabled: autoEnter));
      await controller.pipStart();
      _shownUid = remoteUid;
      _preparedUid = remoteUid;
      debugPrint('[duidui] pip refreshed with remoteUid=${remoteUid ?? '-'}');
    } catch (e) {
      debugPrint('[duidui] pip refresh failed: $e');
    }
  }

  /// 组装要在小窗里显示的**唯一一路**视频流：有对方就显示对方，否则显示自己。
  List<AgoraPipVideoStream> _buildStream(int? remoteUid) {
    if (remoteUid != null) {
      // 远端流优先用 SDK 回调（onUserJoined）里给的真实 RtcConnection，避免 localUid
      // 不匹配导致画面出不来；万一没拿到（极端时序）就用「本端 channel + localUid」兜底
      // —— 同一频道里远端流用的就是这套 connection（声网官方示例里远端流的 connection
      // 也正是直接取自 onUserJoined 回调）。
      //
      // ⚠️ 这里【绝不能】因为 remoteConn 为空就退回「显示自己」：一旦退回本地流，
      //    iOS 退到后台后摄像头会被系统暂停，小窗里就变成黑屏（用户报的
      //    「打开悬浮窗是黑的、看不到对方」）。有对方就一定要显示对方。
      final remoteConn = rtc.remoteConnection ??
          RtcConnection(channelId: rtc.channel, localUid: rtc.localUid);
      return [
        AgoraPipVideoStream(
          connection: remoteConn,
          canvas: VideoCanvas(
            uid: remoteUid,
            view: 0, // 0 = 由 SDK 替换为托管的原生视图
            sourceType: VideoSourceType.videoSourceRemote,
            setupMode: VideoViewSetupMode.videoViewSetupAdd,
            renderMode: RenderModeType.renderModeHidden,
          ),
        ),
      ];
    }
    // 对方还没进房：显示自己（镜像，和 App 内的自拍视角一致）。
    // ⚠️ connection 必须带上真实的 localUid：join 用的是 uid:0（由 SDK 随机分配），
    // 传 channelId 而不传 localUid 时 SDK 绑定不到本端流 → 小窗里就是黑的。
    return [
      AgoraPipVideoStream(
        connection: RtcConnection(channelId: rtc.channel, localUid: rtc.localUid),
        canvas: const VideoCanvas(
          uid: 0,
          view: 0,
          sourceType: VideoSourceType.videoSourceCamera,
          setupMode: VideoViewSetupMode.videoViewSetupAdd,
          renderMode: RenderModeType.renderModeHidden,
          mirrorMode: VideoMirrorModeType.videoMirrorModeEnabled,
        ),
      ),
    ];
  }

  /// 退出悬浮窗（回到 App 内通话界面）。
  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.pipStop();
    } catch (_) {}
    _setActive(false);
    _shownUid = null;
  }

  /// 结束通话 / 离开页面时释放 PiP 资源。
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    _setActive(false);
    _shownUid = null;
    _preparedUid = null;
    if (controller == null) return;
    try {
      await controller.pipDispose();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }
}

final PipHelper pip = PipHelper();
