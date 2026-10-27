import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../native.dart';
import '../storage/drive_location.dart';
import '../server/auth.dart';
import '../server/files.dart';
import '../server/server.dart';
import '../server/store.dart';
import '../server/uploads.dart';
import '../tunnel/cloudflared.dart';

/// Entry point for the foreground service isolate.
///
/// Must be a top-level function annotated for AOT retention, or the tree
/// shaker drops it and the service starts into nothing.
@pragma('vm:entry-point')
void startDriveCallback() {
  FlutterForegroundTask.setTaskHandler(DriveTaskHandler());
}

/// Runs the drive inside the foreground service isolate.
///
/// The server and tunnel deliberately live here rather than in the UI isolate:
/// when Android destroys the Activity, the UI isolate goes with it, and a
/// drive whose server died with the last screen view is not a drive. The UI
/// becomes a remote control that reads status over the plugin's data channel.
class DriveTaskHandler extends TaskHandler {
  DriveStore? _store;
  DriveServer? _server;
  TunnelManager? _tunnel;
  StreamSubscription<TunnelState>? _states;

  TunnelState _lastState = TunnelState.stopped;
  String? _hostname;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _log('onStart: booting');
      await _boot();
    } catch (e, stack) {
      _log('onStart FAILED: $e\n$stack');
      _lastState = TunnelState.failed;
      _publish(error: 'Could not start the drive: $e');
    }
  }

  /// Goes to logcat under the `flutter` tag. The service isolate has no UI, so
  /// without this a failure in here is invisible.
  void _log(String message) => debugPrint('[pocketshare-service] $message');

  Future<void> _boot() async {
    const storage = FlutterSecureStorage();
    final hostname = await storage.read(key: 'hostname');
    final token = await storage.read(key: 'tunnel_token');

    _log('secure storage: hostname=${hostname ?? '<null>'} '
        'token=${token == null ? '<null>' : '${token.length} chars'}');

    if (hostname == null || token == null) {
      _lastState = TunnelState.failed;
      _publish(
        error: 'Could not read this drive\'s settings. '
            'Try setting it up again.',
      );
      return;
    }
    _hostname = hostname;

    final root = await DriveLocation.resolve();
    final support = await getApplicationSupportDirectory();
    _log('drive root: ${root.path}');

    _store = await DriveStore.open(
      root: root,
      dbFile: File(p.join(support.path, 'meta.db')),
    );

    final webRoot = Directory(p.join(support.path, 'web'));
    await _installWebUi(webRoot);

    _server = DriveServer(
      store: _store!,
      auth: Auth(_store!),
      files: DriveFiles(root),
      uploads: UploadManager(
        root: root,
        staging: Directory(p.join(support.path, 'staging')),
      ),
      webRoot: webRoot,
    );
    await _server!.start();
    _log('http server listening on 127.0.0.1:${_server!.boundPort}');

    final libDir = await Native.nativeLibraryDir();
    final binary = p.join(libDir, 'libcloudflared.so');
    _log('cloudflared path: $binary '
        '(exists=${File(binary).existsSync()})');
    _tunnel = TunnelManager(
      binaryPath: binary,
      hostname: hostname,
      token: token,
      localPort: _server!.boundPort,
    );

    _states = _tunnel!.states.listen((state) {
      _lastState = state;
      _publish();
      _updateNotification(state);
    });
    _tunnel!.logs.listen((line) => _log('cloudflared: $line'));

    await _tunnel!.start();
  }

  Future<void> _installWebUi(Directory webRoot) async {
    await webRoot.create(recursive: true);
    for (final name in ['index.html', 'app.js', 'style.css']) {
      final data = await rootBundle.load('assets/web/$name');
      await File(p.join(webRoot.path, name)).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
  }

  void _updateNotification(TunnelState state) {
    final text = switch (state) {
      TunnelState.live => _hostname == null
          ? 'Your drive is online.'
          : 'Reachable at $_hostname',
      TunnelState.verifying => 'Checking the address…',
      TunnelState.registered => 'Connected to Cloudflare…',
      TunnelState.starting => 'Starting…',
      TunnelState.failed => _tunnel?.lastError ?? 'Not reachable',
      TunnelState.stopped => 'Stopped',
    };

    FlutterForegroundTask.updateService(
      notificationTitle: 'PocketShare',
      notificationText: text,
    );
  }

  /// Pushes status to the UI isolate. Fire-and-forget: nothing here should
  /// fail just because no screen is currently listening.
  void _publish({String? error}) {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'state': _lastState.name,
      'hostname': _hostname,
      'error': error ?? _tunnel?.lastError,
      'logs': _tunnel?.recentLogs.take(200).toList() ?? const <String>[],
    }));
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _publish();

  @override
  void onReceiveData(Object data) {
    if (data == 'status') _publish();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _states?.cancel();
    await _tunnel?.dispose();
    await _server?.stop();
    _store?.close();
  }
}
