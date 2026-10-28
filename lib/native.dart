import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Platform glue.
///
/// Note which calls work where: the method channel is registered by
/// MainActivity, so it exists only in the UI isolate. The foreground service
/// runs in its own engine with no Activity, and any channel call there throws
/// [MissingPluginException]. [nativeLibraryDir] is needed in both, so it falls
/// back to deriving the path itself.
class Native {
  static const MethodChannel _channel = MethodChannel('pocketshare/native');

  static String? _cachedLibDir;

  /// Directory holding the packaged cloudflared binary — the only directory
  /// an Android app may execute a file from.
  static Future<String> nativeLibraryDir() async {
    final cached = _cachedLibDir;
    if (cached != null) return cached;

    try {
      final viaChannel = await _channel.invokeMethod<String>('nativeLibraryDir');
      if (viaChannel != null && viaChannel.isNotEmpty) {
        return _cachedLibDir = viaChannel;
      }
    } on MissingPluginException {
      // Service isolate: no MainActivity, so derive it below.
    }

    return _cachedLibDir = _libDirFromProcMaps();
  }

  /// Reads the app's native library directory out of its own memory map.
  ///
  /// libflutter.so is loaded from that directory, so its mapped path names it
  /// — no platform channel, works in any isolate. This holds because the build
  /// sets extractNativeLibs=true; without that, libraries are mapped straight
  /// out of the APK and there is no directory to find.
  static String _libDirFromProcMaps() {
    final lines = File('/proc/self/maps').readAsLinesSync();

    for (final line in lines) {
      final slash = line.indexOf('/');
      if (slash < 0) continue;

      final path = line.substring(slash).trim();
      if (path.endsWith('/libflutter.so')) return p.dirname(path);
    }

    throw StateError(
      'could not locate the native library directory in /proc/self/maps',
    );
  }

  // --- UI-isolate only -------------------------------------------------------

  static Future<bool> isIgnoringBatteryOptimizations() async =>
      await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _channel.invokeMethod('requestIgnoreBatteryOptimizations');

  /// Storage roots on this device (internal, plus SD card when present).
  static Future<List<Map<String, Object?>>> storageVolumes() async {
    final raw = await _channel.invokeListMethod<Object?>('storageVolumes');
    return [
      for (final entry in raw ?? const <Object?>[])
        (entry as Map).cast<String, Object?>(),
    ];
  }

  /// Settings.Secure.ANDROID_ID, or null where it cannot be trusted. Hashed
  /// before use — see [Provisioner.deviceId].
  static Future<String?> androidId() async {
    try {
      return await _channel.invokeMethod<String>('androidId');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> hasAllFilesAccess() async =>
      await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;

  static Future<void> requestAllFilesAccess() =>
      _channel.invokeMethod('requestAllFilesAccess');

  /// Opens the vendor autostart screen if this ROM has one. False means no
  /// known screen exists, so the UI can say so rather than promise nothing.
  static Future<bool> openAutostartSettings() async =>
      await _channel.invokeMethod<bool>('openAutostartSettings') ?? false;

  /// Whether this phone has a vendor autostart screen at all. False on stock
  /// Android, Samsung and Pixel, where the prompt would be noise.
  static Future<bool> hasAutostartSettings() async =>
      await _channel.invokeMethod<bool>('hasAutostartSettings') ?? false;

  /// Hands [text] to the phone's share sheet. False when nothing on the
  /// device can receive it.
  static Future<bool> shareText(String text, {String? subject}) async =>
      await _channel.invokeMethod<bool>('shareText', {
        'text': text,
        'subject': subject,
      }) ??
      false;

  /// Opens [path] in the phone's file manager. Android specifies no intent
  /// for this, so false is a real outcome and the UI has to cope with it.
  static Future<bool> openFolder(String path) async =>
      await _channel.invokeMethod<bool>('openFolder', {'path': path}) ?? false;

  /// Opens one file in whatever app can display it.
  static Future<bool> openFile(String path) async =>
      await _channel.invokeMethod<bool>('openFile', {'path': path}) ?? false;
}
