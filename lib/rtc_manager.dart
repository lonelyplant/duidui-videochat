// 声网通话核心封装：初始化、加入房间、本地/远端视图、画质切换、离开
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'config.dart';
import 'profile.dart';

/// 远端画面当前的可用性。通话页据此决定显示视频还是显示占位提示。
///
/// ⚠️ 必须按「原因」区分，不能一看到非 Decoding 就提示「对方关闭了摄像头」：
///   · [live]       —— 正在出图。**画面冻结也算 live**：弱网降级、对方在小窗里，
///                    保留最后一帧比弹一个假提示更准确。
///   · [cameraOff]  —— 对方主动点了「关摄像头」，声网回调 reason = RemoteMuted。
///   · [background] —— 对方 App 退到了后台。**仅 iOS 会报**（reason = SdkInBackground）：
///                    一进悬浮窗(PiP)，iOS 就暂停摄像头采集，声网随之停发视频流，
///                    对端收到 Stopped —— 但对方并没有关摄像头，提示要写清楚。
enum PeerVideoState { live, cameraOff, background }

class RtcManager {
  RtcEngine? _engine;
  int? _remoteUid;
  RtcConnection? _remoteConn;
  RtcConnection? _localConn;   // onJoinChannelSuccess 给的本端连接（含 SDK 分配的 localUid）
  bool _joined = false;
  String _channel = '';
  int? _dataStreamId;          // 互传昵称/头像用的数据流通道（join 成功后创建）
  String _myProfileJson = '';  // 我方资料 JSON，进房后与对方进房时各广播一次
  int _lastEncHeight = 0;      // 上次编码高度，用于判断是否"降档"

  RtcEngine? get engine => _engine;
  int? get remoteUid => _remoteUid;
  int? get localUid => _localConn?.localUid;

  /// 对方资料（昵称/头像），通过数据流收到后更新；通话页监听显示。
  final ValueNotifier<PeerProfile?> peerProfileNotifier =
      ValueNotifier<PeerProfile?>(null);

  /// 远端 uid 的可监听版本。
  ///
  /// 关键：onUserJoined / onUserOffline 发生在 Dart 回调里，**不会**自动触发
  /// 任何 Widget 重建。之前 UI 只读 `rtc.remoteUid` 这个普通字段，导致对方进房后
  /// 通话页仍停留在「等待对方进入…」。界面必须监听这个 notifier 才会刷新。
  final ValueNotifier<int?> remoteUidNotifier = ValueNotifier<int?>(null);

  /// 引擎每 2 秒回调一次的 RTC 统计（时长/收发字节/码率），左上角流量卡用。
  final ValueNotifier<RtcStats?> statsNotifier = ValueNotifier<RtcStats?>(null);

  /// 频道连接状态：断网/重连横幅 + 恢复后重新套画质用。
  final ValueNotifier<ConnectionStateType> connectionStateNotifier =
      ValueNotifier<ConnectionStateType>(
          ConnectionStateType.connectionStateDisconnected);

  /// 远端画面状态（正常 / 对方关了摄像头 / 对方 App 在后台）。通话页据此显示占位提示。
  final ValueNotifier<PeerVideoState> remoteVideoStateNotifier =
      ValueNotifier<PeerVideoState>(PeerVideoState.live);

  /// 对方是否处于「后台 / 悬浮窗」状态：由对端通过数据流显式告知（见 onStreamMessage）。
  ///
  /// ⚠️ 为什么需要它：iOS 进 PiP 时系统会暂停本机摄像头采集，声网给对端报的是
  /// `RemoteMuted`(5) 而非 `SdkInBackground`(12)，单看 reason 码会把「对方在后台」
  /// 误判成「对方关了摄像头」。所以 iOS 退后台时主动发 {bg:1} 兜底，比猜 reason 码可靠。
  /// 显示逻辑里它优先级最高：只要为 true，远端画面一律按「对方在后台」处理（保留冻结帧 + 横幅）。
  final ValueNotifier<bool> peerBackgroundNotifier = ValueNotifier<bool>(false);

  // 统计增量入库的记账：上次已入库的 时长/字节 快照 + 采样计数
  int _statsTick = 0;
  int _savedDur = 0;
  int _savedBytes = 0;

  void _resetStatsBookkeeping() {
    _statsTick = 0;
    _savedDur = 0;
    _savedBytes = 0;
    statsNotifier.value = null; // RtcStats 是整通累计，跨通话必须清
  }

  /// 把「上次入库快照 → 当前」的增量写入本地统计（进程被杀最多丢一个周期）
  Future<void> _flushStatsDelta() async {
    final s = statsNotifier.value;
    if (s == null) return;
    final dur = s.duration ?? 0;
    final bytes = (s.txBytes ?? 0) + (s.rxBytes ?? 0);
    var dSec = dur - _savedDur;
    var dBytes = bytes - _savedBytes;
    if (dSec < 0) dSec = 0;
    if (dBytes < 0) dBytes = 0;
    if (dSec == 0 && dBytes == 0) return;
    await CallStats.addTraffic(seconds: dSec, bytes: dBytes);
    _savedDur = dur;
    _savedBytes = bytes;
  }

  /// 挂断时调用：冲掉最后一段增量；整通 ≥3 秒则记一通。
  Future<void> finalizeCallStats() async {
    await _flushStatsDelta();
    final s = statsNotifier.value;
    if (s != null && (s.duration ?? 0) >= 3) await CallStats.countCall();
  }

  void _setRemote(int? uid, RtcConnection? conn) {
    _remoteUid = uid;
    _remoteConn = conn;
    remoteUidNotifier.value = uid;
    if (uid == null) {
      peerProfileNotifier.value = null; // 对方离开一并清掉资料
    }
    remoteVideoStateNotifier.value = PeerVideoState.live; // 新一通/对方重进，默认在出图
    peerBackgroundNotifier.value = false; // 对方后台状态同样跨通话残留，一并归零
  }

  /// 远端用户所属的 RtcConnection（悬浮窗 PiP 组装视频流时需要，来自 onUserJoined 回调）。
  RtcConnection? get remoteConnection => _remoteConn;
  /// 本端连接（悬浮窗里显示自己那一路时要用真实的 localUid，uid:0 会让画面出不来）。
  RtcConnection? get localConnection => _localConn;
  bool get joined => _joined;
  String get channel => _channel;

  /// 初始化声网引擎并打开视频/预览。
  /// [token] 留空字符串表示项目为「仅 App ID」测试模式；否则填临时 Token。
  /// [qualityKey] 本次的画质档位：仅语音档跳过 startPreview，摄像头一次都不用开。
  Future<void> init({required String token, String qualityKey = defaultQualityKey}) async {
    // 运行时权限必须显式申请：iOS 首次访问会自动弹窗，Android 6+ 不会——
    // 不申请的话安卓摄像头/麦克风根本打不开（本地预览黑屏、对端也看不到/听不到我们）。
    await [Permission.camera, Permission.microphone].request();
    _resetStatsBookkeeping();
    // 连接状态/对方画面状态同样跨通话残留：上一通若以 Failed 结束，
    // 下一通进房瞬间会闪一下「连接已断开」横幅，这里一并归零。
    connectionStateNotifier.value = ConnectionStateType.connectionStateDisconnected;
    remoteVideoStateNotifier.value = PeerVideoState.live;
    peerBackgroundNotifier.value = false;
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(appId: agoraAppId));
    // 音频只传人声：speech_standard（32 kHz 单声道，约 24 kbps），与 Web 版已验证的
    // 省流档一致。通话用不到 48 kHz 音乐档；显式设置不依赖 SDK 各版本的默认值。
    // ⚠️ 必须在 joinChannel 之前调用。
    await _engine!.setAudioProfile(
        profile: AudioProfileType.audioProfileSpeechStandard);
    await _engine!.enableVideo();
    // 仅语音档跳过 startPreview：下面 join 里的 applyQuality('audio') 反正会
    // enableLocalVideo(false)，先开预览等于让摄像头完整地开一次再关，白费电。
    if (qualityKey != 'audio') await _engine!.startPreview();
    _engine!.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
        _joined = true;
        _localConn = conn;
        _channel = conn.channelId ?? _channel;
        debugPrint('[duidui] join success: ${conn.channelId} uid=${conn.localUid}');
        _setupDataStream(); // 进房后建数据流，广播我的昵称/头像
      },
      onUserJoined: (RtcConnection conn, int uid, int elapsed) {
        _setRemote(uid, conn);
        debugPrint('[duidui] user joined: $uid');
        // 对方后进房时收不到我进房时的那次广播，进人后补发一次
        Future.delayed(const Duration(milliseconds: 600), _sendMyProfile);
      },
      onUserOffline: (RtcConnection conn, int uid, UserOfflineReasonType reason) {
        if (_remoteUid == uid) _setRemote(null, null);
        debugPrint('[duidui] user offline: $uid');
      },
      onConnectionStateChanged: (RtcConnection conn, ConnectionStateType state,
          ConnectionChangedReasonType reason) {
        connectionStateNotifier.value = state;
      },
      onRemoteVideoStateChanged: (RtcConnection conn, int remoteUid,
          RemoteVideoState state, RemoteVideoStateReason reason, int elapsed) {
        if (_remoteUid == null || remoteUid != _remoteUid) return;
        if (state == RemoteVideoState.remoteVideoStateDecoding ||
            state == RemoteVideoState.remoteVideoStateStarting) {
          remoteVideoStateNotifier.value = PeerVideoState.live;
          // 画面重新出图 = 对方必然不在后台了：清掉可能丢失的 bg:0 信令，
          // 避免一直挂着「对方在后台」横幅（bg 信令走不可靠数据流，drop 时靠这里自愈）。
          peerBackgroundNotifier.value = false;
          return;
        }
        if (state == RemoteVideoState.remoteVideoStateStopped) {
          // 对方已显式声明在后台（数据流 {bg:1}）：iOS 进 PiP 时系统暂停摄像头，
          // 声网给对端报的是 RemoteMuted(5)——那是「后台」不是「关摄像头」。
          // 交给 bg 横幅处理，不要把状态降级成 cameraOff 占位。
          if (peerBackgroundNotifier.value) return;
          // 只有「远端用户主动停发视频」才提示对方关了摄像头；
          // 其余停止原因（对方进悬浮窗/退后台、编解码异常…）保持最后一帧，不乱提示。
          if (reason ==
              RemoteVideoStateReason.remoteVideoStateReasonRemoteMuted) {
            remoteVideoStateNotifier.value = PeerVideoState.cameraOff;
          } else if (reason ==
              RemoteVideoStateReason.remoteVideoStateReasonSdkInBackground) {
            remoteVideoStateNotifier.value = PeerVideoState.background;
          }
        }
        // Frozen / Failed / 其它原因：保持现状（冻结的画面照常显示）
      },
      onRtcStats: (RtcConnection conn, RtcStats stats) {
        statsNotifier.value = stats;
        // 每 15 个采样（约 30 秒）增量入库一次，防进程被杀整通统计丢失
        _statsTick++;
        if (_statsTick % 15 == 0) _flushStatsDelta();
      },
      onStreamMessage: (RtcConnection conn, int remoteUid, int streamId,
          Uint8List data, int length, int sentTs) {
        try {
          final obj = jsonDecode(utf8.decode(data));
          if (obj is Map) {
            // 对方进/出后台（PiP 或按 Home）的显式信令：比声网 reason 码可靠。
            // iOS 进 PiP 系统暂停摄像头，声网给对端报 RemoteMuted(5)，单看 reason
            // 会把「在后台」误判成「关了摄像头」，所以这里用应用层信令兜底。
            if (obj['bg'] != null) {
              final b = obj['bg'];
              peerBackgroundNotifier.value = b == 1 || b == true;
              return;
            }
            peerProfileNotifier.value = PeerProfile(
              name: ProfileStore.sanitizeName('${obj['n'] ?? ''}'),
              emoji: ProfileStore.sanitizeEmoji('${obj['e'] ?? ''}'),
            );
          }
        } catch (_) {}
      },
      onError: (ErrorCodeType err, String msg) {
        debugPrint('[duidui] agora error: $err $msg');
      },
    ));
  }

  /// 建数据流并广播我的资料。必须在 join 成功之后调用（createDataStream 要求已进频道）。
  Future<void> _setupDataStream() async {
    try {
      final engine = _engine;
      if (engine == null) return;
      _dataStreamId =
          await engine.createDataStream(const DataStreamConfig(
        syncWithAudio: false,
        ordered: true,
      ));
      final name = await ProfileStore.getName();
      final emoji = await ProfileStore.getEmoji();
      _myProfileJson = jsonEncode({
        'n': name.isEmpty ? '对方' : ProfileStore.cappedName(name),
        'e': emoji.isEmpty ? ProfileStore.defaultEmoji : emoji,
      });
      await _sendMyProfile();
    } catch (e) {
      debugPrint('[duidui] data stream setup failed: $e');
    }
  }

  Future<void> _sendMyProfile() async {
    final id = _dataStreamId;
    final engine = _engine;
    if (id == null || engine == null || _myProfileJson.isEmpty) return;
    final bytes = Uint8List.fromList(utf8.encode(_myProfileJson));
    try {
      await engine.sendStreamMessage(
          streamId: id, data: bytes, length: bytes.length);
    } catch (e) {
      debugPrint('[duidui] send profile failed: $e');
    }
  }

  /// 应用画质档位：设置竖屏编码器配置 + 强制固定竖屏方向（原生 SDK 真正旋转像素）。
  ///
  /// [camOn]：用户当前的摄像头开关。⚠️ 必须传，否则切档位会把用户手动关掉的
  /// 摄像头重新打开（开关状态在 call_page，本类不掌握）。
  Future<void> applyQuality(String key, {bool camOn = true}) async {
    final q = qualityByKey(key);
    if (q.key == 'audio') {
      // 仅语音：直接关闭本地视频，不再设编码器参数
      await _engine?.enableLocalVideo(false);
      _lastEncHeight = 0;
      return;
    }
    await _engine?.enableLocalVideo(camOn);
    final config = VideoEncoderConfiguration(
      dimensions: VideoDimensions(width: q.w, height: q.h),
      frameRate: q.fps,
      bitrate: q.bitrate,
      // 关键：原生端固定竖屏，声网会把横屏传感器帧旋转成像素级竖屏，不会像 Web 那样中心裁切放大
      orientationMode: OrientationMode.orientationModeFixedPortrait,
      // ⚠️ 出流【不】镜像：若这里开镜像，发出去的画面是左右颠倒的，对端看到的就是反的
      // （之前“对方画面左右颠倒”的根因——两端都把自己镜像发出，彼此收到都反了）。
      // 自己的预览镜像感由本地 VideoCanvas 的 mirrorMode 单独控制（见 call_page），不影响出流。
      mirrorMode: VideoMirrorModeType.videoMirrorModeDisabled,
    );
    // 已在房间内且是"降档"（如 720p → 90p）：编码器热降档会长时间处在低码率高压缩状态，
    // 对端画面出现锯齿/马赛克。先关再开本地视频，强制编码器按新档位"冷启动"，
    // 得到与一进房就选 90p 相同的干净缩放效果（仅一瞬间黑帧，画面立刻恢复）。
    final isDowngrade =
        _joined && _lastEncHeight > 0 && q.h < _lastEncHeight;
    if (isDowngrade) {
      await _engine?.enableLocalVideo(false);
      await _engine?.setVideoEncoderConfiguration(config);
      await _engine?.enableLocalVideo(camOn);
    } else {
      await _engine?.setVideoEncoderConfiguration(config);
    }
    _lastEncHeight = q.h;
  }

  /// 加入频道（房间名即为频道名）。房间名仅允许 ASCII，非 ASCII 会被清洗。
  Future<void> join({required String room, required String token, required String qualityKey}) async {
    _channel = _sanitizeRoom(room);
    peerProfileNotifier.value = null; // 新的一通，清掉上一位的资料
    await applyQuality(qualityKey);
    await _engine?.joinChannel(
      token: token,
      channelId: _channel,
      uid: 0,
      options: ChannelMediaOptions(
        autoSubscribeVideo: true,
        autoSubscribeAudio: true,
        publishCameraTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
  }

  String _sanitizeRoom(String room) {
    final cleaned = room.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return cleaned.isEmpty ? 'duidui' : cleaned;
  }

  Future<void> switchCamera() async => _engine?.switchCamera();
  Future<void> setMicMuted(bool muted) async => _engine?.muteLocalAudioStream(muted);
  Future<void> setCamEnabled(bool enabled) async => _engine?.enableLocalVideo(enabled);

  /// 告诉对端「我进了后台 / 悬浮窗」（inBg=true）或「回到前台」（inBg=false）。
  ///
  /// 用途：iOS 进 PiP 时系统暂停本机摄像头，对端声网收到的是停发视频(RemoteMuted)，
  /// 单看 reason 码会把「在后台」误判成「关了摄像头」。用应用层数据流显式告知，
  /// 对端据此显示「对方在后台」并保留冻结帧，文案才准确。
  /// 仅在 iOS 调用（安卓进后台不会暂停摄像头，无需发）；数据流走不可靠通道，
  /// 但进/出后台都会各发一次，且对端在收到 Decoding 时会自愈清掉过期状态。
  Future<void> sendPeerBackground(bool inBg) async {
    final id = _dataStreamId;
    final engine = _engine;
    if (id == null || engine == null) return;
    final bytes =
        Uint8List.fromList(utf8.encode(jsonEncode({'bg': inBg ? 1 : 0})));
    try {
      await engine.sendStreamMessage(streamId: id, data: bytes, length: bytes.length);
    } catch (e) {
      debugPrint('[duidui] send peer background failed: $e');
    }
  }

  bool _screenSharing = false;
  bool get screenSharing => _screenSharing;

  /// 开始屏幕共享（本项目仅安卓落地；iOS 未做 ReplayKit 扩展，按钮不展示）。
  ///
  /// 采用「同 uid 切换」：关闭摄像头出流、开启屏幕出流，远端仍是同一个 uid，
  /// 渲染端（含 iOS 接收方）无需任何改动。先 startScreenCapture 拉起系统
  /// MediaProjection 授权弹窗，再 updateChannelMediaOptions 把出流从摄像头切到屏幕。
  Future<bool> startScreenShare() async {
    final engine = _engine;
    if (engine == null || !_joined) return false;
    try {
      await engine.startScreenCapture(ScreenCaptureParameters2(
        captureVideo: true,
        captureAudio: false, // 只共享画面，不采集系统声音（避免与麦克风音频冲突 / 省流）
        videoParams: ScreenVideoParameters(
          dimensions: VideoDimensions(width: 1280, height: 720),
          frameRate: 15,
        ),
      ));
      await engine.updateChannelMediaOptions(ChannelMediaOptions(
        publishCameraTrack: false,
        publishScreenCaptureVideo: true,
        publishScreenCaptureAudio: false,
        publishMicrophoneTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        autoSubscribeVideo: true,
        autoSubscribeAudio: true,
      ));
      // 关掉本地摄像头采集（省电；共享期间本地预览由 UI 显示占位）
      await engine.enableLocalVideo(false);
      _screenSharing = true;
      return true;
    } catch (e) {
      debugPrint('[duidui] startScreenShare failed: $e');
      return false;
    }
  }

  /// 停止屏幕共享：停采集、把出流切回摄像头、恢复本地摄像头采集。
  Future<void> stopScreenShare() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.stopScreenCapture();
      await engine.updateChannelMediaOptions(ChannelMediaOptions(
        publishCameraTrack: true,
        publishScreenCaptureVideo: false,
        publishScreenCaptureAudio: false,
        publishMicrophoneTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        autoSubscribeVideo: true,
        autoSubscribeAudio: true,
      ));
      await engine.enableLocalVideo(true);
      _screenSharing = false;
    } catch (e) {
      debugPrint('[duidui] stopScreenShare failed: $e');
    }
  }

  /// 离开频道。悬浮窗（PiP）由 PipHelper 单独管理，这里不动。
  Future<void> leave() async {
    // 共享中挂断：先停屏幕采集，避免退出后系统仍认为在共享
    try { if (_screenSharing) await stopScreenShare(); } catch (_) {}
    try { await _engine?.leaveChannel(); } catch (_) {}
    _setRemote(null, null);
    _joined = false;
  }

  Future<void> dispose() async {
    try { await _engine?.leaveChannel(); } catch (_) {}
    try { await _engine?.release(); } catch (_) {}
    _engine = null;
    _setRemote(null, null);
    _joined = false;
    _resetStatsBookkeeping(); // 同上：避免残留累计值混入下一通
  }
}

final RtcManager rtc = RtcManager();
