// Windows 电脑版自定义标题栏（微信视频通话同款交互）：
//   [拖动区……]        [置顶] [最小化] [最大化/还原] [关闭]
// 系统自带标题栏在 main 里已隐藏（TitleBarStyle.hidden），整条都由这里绘制。
// 置顶 = setAlwaysOnTop，通话时对方画面浮在所有窗口之上，不影响边干别的事边看娃/看对方。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 标题栏高度（微信同款 32px 视觉密度）
const double kTitleBarHeight = 34;

/// 仅 Windows 需要自绘标题栏；其他平台返回 null（布局层直接跳过）。
Widget? maybeWindowTitleBar({Color color = Colors.black}) =>
    Platform.isWindows ? WindowTitleBar(color: color) : null;

class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, this.color = Colors.black});

  final Color color;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _alwaysOnTop = false;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _restoreState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _restoreState() async {
    _alwaysOnTop = await windowManager.isAlwaysOnTop();
    _maximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _togglePin() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    if (mounted) setState(() {});
  }

  /// 标题栏按钮的统一样式：无底色，悬停时浅灰；关闭键悬停变红（与系统习惯一致）。
  Widget _btn(Widget child, VoidCallback onTap, {bool danger = false}) {
    return SizedBox(
      width: 44,
      height: kTitleBarHeight,
      child: InkWell(
        onTap: onTap,
        hoverColor: danger ? const Color(0xFFE81123) : Colors.white12,
        child: Center(child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.color,
      child: DragToMoveArea(
        child: SizedBox(
          height: kTitleBarHeight,
          child: Row(
            children: [
              const Spacer(),
              // 置顶：钉住后窗口浮在所有应用之上（通话场景核心诉求）
              _btn(
                Icon(Icons.push_pin,
                    size: 16,
                    color: _alwaysOnTop ? const Color(0xFF07C160) : Colors.white70),
                _togglePin,
              ),
              _btn(const Icon(Icons.minimize, size: 16, color: Colors.white70),
                  () => windowManager.minimize()),
              _btn(
                Icon(
                  _maximized
                      ? Icons.filter_none // 还原（双层小方块）
                      : Icons.crop_square, // 最大化（单层方框）
                  size: 14,
                  color: Colors.white70,
                ),
                () async {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
              ),
              _btn(const Icon(Icons.close, size: 16, color: Colors.white70),
                  () => windowManager.destroy(), danger: true),
            ],
          ),
        ),
      ),
    );
  }
}
