import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config.dart';
import '../main.dart';
import '../native_bridge.dart';
import '../profile.dart';
import '../rtc_manager.dart';
import '../pip_helper.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> with WidgetsBindingObserver {
  bool _micMuted = false;
  bool _camOn = true;
  bool _screenSharing = false;
  bool _pipOn = false;
  String _qualityKey = defaultQualityKey;
  bool _pipBusy = false;
  bool _hangingUp = false; // 挂断防抖：连点会导致流量被重复累加
  // 退后台（含安卓按 Home 自动进悬浮窗、iOS 进悬浮窗）时置 true
  bool _lifecycleHidden = false;
  // 沉浸模式：点画面空白处切换，隐藏左上角信息与底部按钮
  bool _immersive = false;
  // 左上角流量卡是否展开：收起时只留「通话时长」，点一下切换（默认展开，和以前一样）
  bool _statsExpanded = true;
  // 悬浮窗每次进出都会改变窗口尺寸，安卓 TextureView 平台视图可能停留在旧尺寸
  // （返回大屏后画面缩在角落）——计数变化即强制重建视频视图
  int _pipGen = 0;
  // 断网重连中标记：恢复连接后重新套一次画质（弱网期间 SDK 可能降过码率）
  bool _reconnecting = false;
  // 通话开始时刻：时长显示由下面的 _DurationText 独立计时/重绘，
  // 不再用 Timer.periodic 每秒 setState 整页（整页里有两个 TextureView 平台视图，
  // 低端机上每秒全页重建会掉帧、更耗电）。
  final DateTime _callStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initQuality();
    // 视频期间保持屏幕常亮（含悬浮窗/后台），挂断时释放
    WakelockPlus.enable().catchError((_) {});
    // 进通话即“布好”悬浮窗（pipSetup），这样按 Home / 退后台会自动进小窗
    pip.prepareAutoEnter(remoteUid: rtc.remoteUid);
    // 对方进/出房间是在 SDK 回调里发生的，需要监听后手动刷新（否则永远停在「等待对方进入…」）；
    // 同时若此刻正在悬浮窗里，顺带把小窗的画面切一遍（自己 ⇄ 对方）。
    rtc.remoteUidNotifier.addListener(_onRemoteChanged);
    // 悬浮窗出现/消失时也要刷新：安卓的悬浮窗镜像整个 Activity 画面，
    // 必须在窗口激活期间把按钮等控件藏掉，小窗里才会只剩视频画面。
    pip.activeNotifier.addListener(_onPipChanged);
    // 连接状态：断网横幅 + 重连恢复后重新套画质
    rtc.connectionStateNotifier.addListener(_onConnStateChanged);
  }

  void _onRemoteChanged() {
    final uid = rtc.remoteUidNotifier.value;
    if (pip.isActive) {
      pip.refresh(remoteUid: uid);
    } else {
      // 还没进小窗：刷新“待自动进小窗”的布局，确保对方进/出房后，按 Home 进小窗时
      // 显示的是当前该显示的那一方（有对方显示对方，否则显示自己）。
      pip.prepareAutoEnter(remoteUid: uid);
    }
    if (mounted) setState(() {});
  }

  void _onPipChanged() {
    // 从系统侧退出悬浮窗（如 iOS 点小窗的「还原」回 App）时，同步按钮状态
    if (!pip.isActive && _pipOn) _pipOn = false;
    // 悬浮窗进出 = 窗口尺寸变化：换 key 强制重建视频视图，防返回大屏后画面残留小尺寸
    _pipGen++;
    if (mounted) setState(() {});
  }

  void _onConnStateChanged() {
    final st = rtc.connectionStateNotifier.value;
    if (st == ConnectionStateType.connectionStateConnected && _reconnecting) {
      // 弱网期间声网会主动降码率，恢复后不会自己升回来 → 重新套当前档位
      // （带上摄像头开关，别把用户手动关掉的摄像头误开）
      rtc.applyQuality(_qualityKey, camOn: _camOn);
    }
    _reconnecting = st == ConnectionStateType.connectionStateReconnecting ||
        st == ConnectionStateType.connectionStateFailed;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 按 Home 自动进悬浮窗走的是「先退后台、后出小窗」：必须在退后台那一刻就藏控件，
    // 否则悬浮窗首帧还带着按钮。回到前台（含退出悬浮窗还原回来）再恢复。
    if (mounted) setState(() => _lifecycleHidden = state != AppLifecycleState.resumed);
    // 省电：彻底退后台（息屏/切走、且不在悬浮窗里）时暂停摄像头采集，回前台恢复。
    // 悬浮窗期间（inactive，活动仍可见）不停——悬浮窗可能显示自己，对端也要看到我们。
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      if (!_pipOn && !pip.isActive) rtc.setCamEnabled(false);
      // iOS 进后台（含 PiP）：显式告知对端「我在后台」。否则对端声网收到的是
      // 停发视频(RemoteMuted)，会把系统暂停的摄像头误判成「对方关了摄像头」。
      if (Platform.isIOS) rtc.sendPeerBackground(true);
    } else if (state == AppLifecycleState.resumed) {
      // 从桌面/图标重新进 App：若悬浮窗还开着，关掉它、回到正常大屏
      // （需求：点桌面图标进 App 要自动关闭悬浮窗，展示大屏视频）。
      if (pip.isActive) {
        pip.stop();
        _pipOn = false;
      }
      // ⚠️ 仅语音档下摄像头必须是关的（applyQuality('audio') 关过它），
      //    不看档位直接恢复会把摄像头误开、开始偷跑视频流量。
      rtc.setCamEnabled(_camOn && _qualityKey != 'audio');
      if (Platform.isIOS) rtc.sendPeerBackground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable().catchError((_) {});
    rtc.remoteUidNotifier.removeListener(_onRemoteChanged);
    pip.activeNotifier.removeListener(_onPipChanged);
    rtc.connectionStateNotifier.removeListener(_onConnStateChanged);
    super.dispose();
  }

  Future<void> _initQuality() async => _qualityKey = await Settings.getQuality();

  Future<void> _changeQuality(String key) async {
    _qualityKey = key;
    await Settings.setQuality(key);
    // ⚠️ 必须把摄像头开关传进去：否则切档位会把用户手动关掉的摄像头重新打开
    await rtc.applyQuality(key, camOn: _camOn);
    if (mounted) setState(() {});
  }

  /// 仅语音档下摄像头/翻转按钮点了只提示，不真开摄像头（与档位语义一致）
  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _togglePip() async {
    if (_pipBusy) return;
    setState(() => _pipBusy = true);
    if (pip.isActive) {
      await pip.stop();
      if (mounted) setState(() => _pipOn = false);
    } else {
      // iOS 要求 PiP 必须由用户手势触发，所以只能从这里的点按进入
      // 先藏控件再启动：悬浮窗起播的首帧就不带按钮（启动失败会在下面恢复并提示）
      setState(() => _pipOn = true);
      final uid = rtc.remoteUid;
      final ok = await pip.start(remoteUid: uid);
      if (mounted) {
        setState(() => _pipOn = ok);
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(pip.lastError ?? '当前设备不支持悬浮窗')),
          );
        } else {
          // 进小窗后把 App 退到桌面（小窗浮在桌面上，通话不断）。
          //
          // ⚠️ 这里【绝不能】用 SystemNavigator.pop()：
          //    · 安卓上它执行的是 Activity.finish() → Activity 被销毁，声网的 PiP 小窗
          //      跟着消失；重开 App 还会从首页重新开始。表现就是「回到桌面但没有小窗，
          //      再次打开 App 回到输入房间名的界面」。
          //    · iOS 上它是 exit(0)，直接杀进程，小窗同样会没。
          //    所以统一走原生通道做「只退后台、不销毁 Activity/进程」。
          //
          // 安卓：pipStart 成功时系统一般已经把我们切进 PiP（桌面会自动显示在小窗后面），
          //       这时什么都不用做；只有没进成才补一次 moveTaskToBack —— 它会触发
          //       AgoraPIPFlutterActivity.onUserLeaveHint() 去进小窗。
          // iOS：系统不会自己切后台（PiP 小窗只浮在当前 App 之上），必须显式退到后台；
          //      而且只有真正退到后台，PiP 才会走系统托管的渲染路径（前台启动容易黑屏）。
          if (Platform.isAndroid) {
            await Future.delayed(const Duration(milliseconds: 400));
            if (!await pip.isActivated()) await NativeBridge.goHome();
          } else if (Platform.isIOS) {
            await Future.delayed(const Duration(milliseconds: 250));
            // ⚠️ 时序保险：iOS 退后台走的是私有 suspend（**把进程冻住**），而「我在后台」
            // 的信令是 Dart 侧数据流发的。必须赶在冻结之前显式发一次，不能只赌
            // didChangeAppLifecycleState 能抢到执行机会 —— 那一路同样保留（覆盖「按 Home
            // 不点按钮」的场景），重复发是幂等的。
            await rtc.sendPeerBackground(true);
            await NativeBridge.goHome();
          }
          // 注：对方还没进房时小窗显示的是自己（见 PipHelper 里的说明），这里不再弹
          // SnackBar —— 此时 App 已经退到后台，提示根本看不到。退后台后 iOS 会暂停
          // 摄像头采集，小窗里自己那一路会静止，属系统限制（声网 issue #2429）。
        }
      }
    }
    if (mounted) setState(() => _pipBusy = false);
  }

  Future<void> _hangUp() async {
    if (_hangingUp) return;
    _hangingUp = true;
    await rtc.finalizeCallStats(); // 冲最后一段增量；整通 ≥3 秒记一通
    await pip.stop(); // 先关悬浮窗（若还开着），避免挂断后小窗残留在桌面
    await pip.dispose();
    await rtc.leave();
    await rtc.dispose();
    if (mounted) Navigator.of(context).pushReplacementNamed('/');
  }

  /// 安卓返回键/返回手势：不直接退出，先确认是否挂断
  Future<void> _confirmHangUp() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('挂断通话？', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('挂断', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) _hangUp();
  }

  Future<void> _toggleScreenShare() async {
    if (_screenSharing) {
      await rtc.stopScreenShare();
      await rtc.setCamEnabled(_camOn); // 还原用户摄像头开关（stopScreenShare 默认开了摄像头）
      if (mounted) setState(() => _screenSharing = false);
    } else {
      final ok = await rtc.startScreenShare();
      if (mounted) {
        setState(() => _screenSharing = ok);
        if (!ok) _toast('屏幕共享启动失败（需系统授权，且仅安卓支持）');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = rtc.engine;
    // 安卓的悬浮窗显示的是整个 Activity 画面（Flutter 界面），激活期间必须把
    // 按钮等控件整体藏掉，小窗里才会只剩视频；沉浸模式（点画面切换）同理。
    final hideControls = _immersive || _pipOn || pip.isActive || _lifecycleHidden;
    // 悬浮窗期间有对方 → 只显示远端；再放本地小窗看起来就像「悬浮窗里又套了个悬浮窗」。
    // 对方还没进房时保留本地画面，免得小窗一片黑。
    final inPip = _pipOn || pip.isActive;
    // 视频一律用 TextureView（useAndroidSurfaceView: false）：
    // SurfaceView 在安卓悬浮窗（PiP）里会黑屏、且小窗层级会被全屏画面盖住。
    // 安卓返回键/手势不直接退出，先弹挂断确认。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmHangUp();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 断网/重连横幅（置于画面之上、控制区之下）
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 88,
            child: ValueListenableBuilder<ConnectionStateType>(
              valueListenable: rtc.connectionStateNotifier,
              builder: (context, st, _) {
                String? msg;
                if (st == ConnectionStateType.connectionStateReconnecting) {
                  msg = '网络不稳定，重连中…';
                } else if (st == ConnectionStateType.connectionStateFailed) {
                  msg = '连接已断开，请检查网络';
                }
                if (msg == null) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orangeAccent, width: 1),
                  ),
                  child: Text(msg,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 13)),
                );
              },
            ),
          ),

          // 远端主画面（全屏）——监听远端 uid，对方一进房就自动重建画面；
          // 点画面空白处切换沉浸模式（隐藏/显示信息与按钮）
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _immersive = !_immersive),
              child: ValueListenableBuilder<int?>(
                valueListenable: rtc.remoteUidNotifier,
                builder: (context, remoteUid, _) {
                  if (engine != null && remoteUid != null) {
                    // 对方关摄像头 / 退后台 → 占位提示，不再渲染冻结帧
                    return ValueListenableBuilder<PeerVideoState>(
                      valueListenable: rtc.remoteVideoStateNotifier,
                      builder: (context, vs, _) {
                        // 嵌套监听「对方是否在后台」：iOS 进 PiP 时系统暂停摄像头，
                        // 声网给本端报的是停发视频(RemoteMuted)，单看 reason 码会误判成
                        // 「关了摄像头」。用对端显式发的 bg 信令兜底，文案才准确。
                        return ValueListenableBuilder<bool>(
                          valueListenable: rtc.peerBackgroundNotifier,
                          builder: (context, peerBg, _) {
                            final bool bg =
                                peerBg || vs == PeerVideoState.background;
                            // 仅「对方真的关了摄像头」才显示占位；在后台不算关摄像头
                            final bool camOff =
                                vs == PeerVideoState.cameraOff && !peerBg;
                            if (camOff) {
                              return Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                        rtc.peerProfileNotifier.value?.emoji ??
                                            '🙂',
                                        style: const TextStyle(fontSize: 56)),
                                    const SizedBox(height: 12),
                                    const Text('对方关闭了摄像头',
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 15)),
                                  ],
                                ),
                              );
                            }
                            // 出图中，或对方在后台(PiP/按 Home)：都渲染视频画面。
                            // 后台时系统暂停对方摄像头，远端视频会冻结在最后一帧（或黑屏），
                            // 叠加一条横幅说明「对方在后台」比直接说「关了摄像头」更准确。
                            return Stack(
                              children: [
                                Positioned.fill(
                                  // 平台视图隔成独立重绘层：左上角流量卡每 2 秒刷文字、
                                  // 沉浸模式切换横幅等局部变化不波及视频层的重绘
                                  child: RepaintBoundary(
                                    child: AgoraVideoView(
                                      // 悬浮窗进出会改变窗口尺寸，换 key 强制重建，防画面残留小尺寸
                                      key: ValueKey(
                                          'remote-$_pipGen-${remoteUid ?? 0}'),
                                      controller: VideoViewController.remote(
                                        rtcEngine: engine,
                                        // 对方画面【不】镜像：出流由编码器控制，这里只管渲染方向，
                                        // 显式关掉避免在某些 SDK 版本上出现左右颠倒。
                                        canvas: VideoCanvas(
                                          uid: remoteUid,
                                          mirrorMode:
                                              VideoMirrorModeType.videoMirrorModeDisabled,
                                        ),
                                        connection:
                                            RtcConnection(channelId: rtc.channel),
                                        useAndroidSurfaceView: false,
                                      ),
                                    ),
                                  ),
                                ),
                                if (bg)
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: Container(
                                      color: Colors.black54,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 6, horizontal: 10),
                                      child: const Text(
                                        '对方在后台（悬浮窗），画面已暂停',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  }
                  return const Center(
                    child: Text('等待对方进入…', style: TextStyle(color: Colors.white70)),
                  );
                },
              ),
            ),
          ),

          // 本地小窗（右上角）。悬浮窗里有对方时不显示（否则像「窗里套窗」）
          if (engine != null && !(inPip && rtc.remoteUid != null))
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 12,
              width: 104,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.grey[900],
                  child: rtc.screenSharing
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.screen_share,
                                  color: Colors.white54, size: 28),
                              SizedBox(height: 8),
                              Text('正在共享屏幕',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        )
                      : RepaintBoundary(
                          child: AgoraVideoView(
                            key: ValueKey('local-$_pipGen'),
                            controller: VideoViewController(
                              rtcEngine: engine,
                              // 自己的预览开镜像（像照镜子一样自然）；不影响发出去的流（编码器已设不镜像）
                              canvas: const VideoCanvas(
                                uid: 0,
                                mirrorMode:
                                    VideoMirrorModeType.videoMirrorModeEnabled,
                              ),
                              useAndroidSurfaceView: false,
                            ),
                          ),
                        ),
                ),
              ),
            ),

          // 顶部中央：对方昵称/头像（通过数据流互传，收到后显示）
          Positioned(
            top: MediaQuery.of(context).padding.top + 54,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: ValueListenableBuilder<PeerProfile?>(
                  valueListenable: rtc.peerProfileNotifier,
                  builder: (context, p, _) {
                    if (p == null || (p.name.isEmpty && p.emoji.isEmpty)) {
                      return const SizedBox.shrink();
                    }
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(p.emoji.isEmpty
                              ? ProfileStore.defaultEmoji
                              : p.emoji,
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Text(p.name.isEmpty ? '对方' : p.name,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // 左上角：画质选择 + 流量统计
          if (!hideControls)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: DropdownButton<String>(
                      value: _qualityKey,
                      dropdownColor: const Color(0xFF1E1E1E),
                      underline: const SizedBox(),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      items: qualities
                          .map((q) => DropdownMenuItem(
                                value: q.key,
                                child: Text(q.label,
                                    style: const TextStyle(color: Colors.white)),
                              ))
                          .toList(),
                      onChanged: (v) => _changeQuality(v ?? defaultQualityKey),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<RtcStats?>(
                    valueListenable: rtc.statsNotifier,
                    builder: (context, s, _) => GestureDetector(
                      // 点一下收起（只留通话时长）/ 再点展开，省得流量卡一直挡在画面左上角
                      onTap: () =>
                          setState(() => _statsExpanded = !_statsExpanded),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 时长自带每秒计时器，只重建自己这一小块文本，
                            // 不再跟着整页重建（也不受展开/收起切换重置计时影响）
                            _DurationText(
                              startedAt: _callStart,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                            if (_statsExpanded) ...[
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  _fmtTraffic(s),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11),
                                ),
                              ),
                            ],
                            const SizedBox(width: 3),
                            Icon(
                              _statsExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 14,
                              color: Colors.white54,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 底部控制栏
          if (!hideControls)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 18,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _roundBtn(_micMuted ? Icons.mic_off : Icons.mic, _micMuted ? '取消静音' : '静音', () {
                    _micMuted = !_micMuted;
                    rtc.setMicMuted(_micMuted);
                    setState(() {});
                  }),
                  _roundBtn(_camOn ? Icons.videocam : Icons.videocam_off, _camOn ? '关摄像头' : '开摄像头', () {
                    if (_screenSharing) {
                      _toast('正在共享屏幕，请先停止共享');
                      return;
                    }
                    if (_qualityKey == 'audio') {
                      _toast('当前是仅语音模式，切到视频档位才能开摄像头');
                      return;
                    }
                    _camOn = !_camOn;
                    rtc.setCamEnabled(_camOn);
                    setState(() {});
                  }),
                  _roundBtn(Icons.flip_camera_ios, '翻转', () {
                    if (_screenSharing) {
                      _toast('正在共享屏幕，请先停止共享');
                      return;
                    }
                    if (_qualityKey == 'audio') {
                      _toast('当前是仅语音模式，翻转不可用');
                      return;
                    }
                    rtc.switchCamera();
                  }),
                  if (Platform.isAndroid)
                    _roundBtn(
                      _screenSharing
                          ? Icons.stop_screen_share
                          : Icons.screen_share,
                      _screenSharing ? '停止共享' : '共享屏幕',
                      _toggleScreenShare,
                      color: _screenSharing ? Colors.blue : null,
                    ),
                  _roundBtn(_pipOn ? Icons.picture_in_picture_alt : Icons.picture_in_picture, '悬浮窗', _togglePip),
                  _roundBtn(Icons.call_end, '挂断', _hangUp, color: Colors.red),
                ],
              ),
            ),
        ],
      ),
      ),
    );
  }

  /// 左上角流量卡（展开态）：时长右侧的「已用流量 · 实时上/下行码率」段。
  /// 时长本身由 [_DurationText] 独立显示，这里不再拼时长。
  /// RtcStats 各字段在 6.x SDK 里都是可空的，逐个兜底为 0。
  String _fmtTraffic(RtcStats? s) {
    if (s == null) return '· 流量统计中…';
    final tx = s.txBytes ?? 0, rx = s.rxBytes ?? 0;
    final mb = (tx + rx) / 1048576;
    return '· 已用 ${mb.toStringAsFixed(1)}MB · '
        '↑${s.txKBitRate ?? 0} ↓${s.rxKBitRate ?? 0} kbps';
  }

  Widget _roundBtn(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: color ?? Colors.white24, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}

/// 通话时长：独立小部件自带每秒计时器，每秒只重建自己这一小块文本。
/// 以前是 CallPage 用 Timer.periodic 每秒 setState 整页 —— 整页里有两个
/// TextureView 平台视图（远端全屏 + 本地小窗），低端机上每秒全页重建会掉帧、更耗电。
/// 计时基准从外部传入 [startedAt]：控件随「隐藏控件」被拆掉再重建时，时长也不会归零。
class _DurationText extends StatefulWidget {
  const _DurationText({required this.startedAt, this.style});

  final DateTime startedAt;
  final TextStyle? style;

  @override
  State<_DurationText> createState() => _DurationTextState();
}

class _DurationTextState extends State<_DurationText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = DateTime.now().difference(widget.startedAt).inSeconds;
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return Text('通话 $m:$s', style: widget.style);
  }
}
