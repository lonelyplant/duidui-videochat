// 安卓「应用内下载 APK + 自动调起安装」：下载进度实时画在按钮里。
// iOS 不使用本文件（未签名 IPA 系统装不了，仍走蒲公英 / Release 页，见 settings_page）。
//
// 行为：点按钮 → 用 dio 在 App 内下载 APK，按钮背景按比例填充并显示「下载中 NN%」；
// 下完自动调起系统安装器（Android 无法完全静默安装，系统仍会弹一次「安装」确认，用户点一下即可）。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// 与设置页按钮一致的强调色
const _green = Color(0xFF07C160);

class ApkDownloadButton extends StatefulWidget {
  final String url;
  final String fallbackPageUrl;
  const ApkDownloadButton({
    super.key,
    required this.url,
    this.fallbackPageUrl = '',
  });

  @override
  State<ApkDownloadButton> createState() => _ApkDownloadButtonState();
}

class _ApkDownloadButtonState extends State<ApkDownloadButton> {
  double _progress = 0; // 0..1
  bool _busy = false; // 下载中或调安装中
  String? _error;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      // 存到 App 自己的外部存储目录：系统安装器（另一个 UID）能读到，
      // 且不需要 WRITE_EXTERNAL_STORAGE（Android 10+ 作用域存储下，自己的目录默认可读）。
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final apk = '${dir.path}/duidui_video_update.apk';
      await Dio().download(
        widget.url,
        apk,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) setState(() => _progress = received / total);
        },
      );
      if (!mounted) return;
      // 自动调起安装：Android 仍会弹系统安装确认（无法完全静默），用户点一下即可。
      final res = await OpenFilex.open(apk);
      if (!mounted) return;
      if (res.type != ResultType.done) {
        setState(() => _error = '自动安装未启动：${res.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_progress * 100).round();
    final downloading = _busy && _error == null;
    final text = _error != null
        ? '重试'
        : downloading
            ? '下载中 $pct%'
            : (_busy ? '正在安装…' : '下载安装包');
    return SizedBox(
      width: 150,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 进度填充层：从左向右覆盖按钮背景，直观显示下载百分比
          if (downloading)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: _progress.clamp(0.0, 1.0),
                child: Container(color: _green.withOpacity(.4)),
              ),
            ),
          TextButton(
            onPressed: _busy ? null : _run,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _green,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              padding: EdgeInsets.zero,
            ),
            child: Text(text, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
