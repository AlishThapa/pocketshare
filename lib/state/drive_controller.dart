import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../server/auth.dart';
import '../server/store.dart';
import '../service/drive_task.dart';
import '../storage/drive_location.dart';
import '../tunnel/cloudflared.dart';
import '../tunnel/provision.dart';

enum SetupStage { loading, claimName, createLogin, ready }

/// Setup state machine, and a remote control for the drive.
///
/// The drive itself runs in the foreground service isolate (see
/// [DriveTaskHandler]); this class only starts and stops it and mirrors the
/// status it reports back. Account creation happens here because it must
/// finish before the service is allowed to start.
class DriveController extends ChangeNotifier {
  DriveController({required String provisionEndpoint})
      : provisioner = Provisioner(endpoint: provisionEndpoint);

  final Provisioner provisioner;

  DriveStore? _store;
  Auth? _auth;

  SetupStage stage = SetupStage.loading;
  Claim? claim;
  String? errorMessage;

  TunnelState tunnelState = TunnelState.stopped;
  String? tunnelError;
  List<String> tunnelLogs = const [];

  String get hostname => claim?.hostname ?? '';
  String? get username => _store?.account?.username;

  /// Absolute path the drive serves from, shown in the UI so the location is
  /// never a mystery.
  String? driveRootPath;

  bool get storageSurvivesUninstall =>
      driveRootPath != null && DriveLocation.survivesUninstall(driveRootPath!);

  /// Whether the user has told us they handled the vendor autostart screen.
  /// MIUI exposes no way to read that setting, so acknowledgement is the only
  /// signal available.
  bool autostartAcknowledged = false;
  bool get isLive => tunnelState == TunnelState.live;
  bool get isBusy =>
      tunnelState == TunnelState.starting ||
      tunnelState == TunnelState.registered ||
      tunnelState == TunnelState.verifying;

  Future<void> init() async {
    _configureService();

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);

    final root = await DriveLocation.resolve();
    driveRootPath = root.path;
    final support = await getApplicationSupportDirectory();

    _store = await DriveStore.open(
      root: root,
      dbFile: File(p.join(support.path, 'meta.db')),
    );
    _auth = Auth(_store!);

    autostartAcknowledged =
        await _settings.read(key: _kAutostartDone) == 'yes';

    claim = await provisioner.saved();

    if (claim == null) {
      stage = SetupStage.claimName;
    } else if (!_auth!.hasAccount) {
      stage = SetupStage.createLogin;
    } else {
      stage = SetupStage.ready;
      unawaited(startDrive());
    }
    notifyListeners();
  }

  static const _settings = FlutterSecureStorage();
  static const _kAutostartDone = 'autostart_done';

  /// Volumes the user can move the drive to. UI isolate only.
  Future<List<StorageVolume>> storageVolumes() => DriveLocation.volumes();

  /// Moves the drive to [volume], carrying existing files across.
  ///
  /// The service is stopped first: it holds the SQLite handle and is actively
  /// serving from the old path, and copying files out from under it would race
  /// any in-flight upload.
  Future<int> changeStorage(StorageVolume volume) async {
    final wasRunning = await FlutterForegroundTask.isRunningService;
    if (wasRunning) await stopDrive();

    final from = Directory(driveRootPath ?? (await DriveLocation.resolve()).path);
    final to = Directory(volume.drivePath);

    final moved = await DriveLocation.migrate(from, to);
    await DriveLocation.save(to.path);
    driveRootPath = to.path;
    notifyListeners();

    if (wasRunning) await startDrive();
    return moved;
  }

  Future<void> markAutostartDone() async {
    autostartAcknowledged = true;
    notifyListeners();
    await _settings.write(key: _kAutostartDone, value: 'yes');
  }

  /// Replaces the login and kills every browser session.
  ///
  /// There is deliberately no "forgot password" flow over the web: the drive
  /// has no email address and no second factor, so anything reachable from the
  /// internet would be a bypass. Holding the phone is the credential.
  Future<bool> resetLogin({
    required String username,
    required String password,
  }) async {
    final problem = validateCredentials(username, password);
    if (problem != null) {
      errorMessage = problem;
      notifyListeners();
      return false;
    }

    await _auth!.createAccount(username: username, password: password);
    _store!.dropAllSessions();

    errorMessage = null;
    notifyListeners();
    return true;
  }

  void _configureService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pocketshare_drive',
        channelName: 'Drive status',
        channelDescription:
            'Shows whether your drive is reachable. Dismissing this stops '
            'the drive.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // A heartbeat, not a work loop: it re-publishes status so a screen
        // that was reopened sees current state without asking.
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        // The drive is useless without the network, and Android will park an
        // idle Wi-Fi radio.
        allowWifiLock: true,
      ),
    );
  }

  /// Mirrors status published by the service isolate.
  void _onServiceData(Object data) {
    if (data is! String) return;

    try {
      final payload = jsonDecode(data) as Map<String, Object?>;
      tunnelState = TunnelState.values.firstWhere(
        (s) => s.name == payload['state'],
        orElse: () => tunnelState,
      );
      tunnelError = payload['error'] as String?;
      tunnelLogs = (payload['logs'] as List?)?.cast<String>() ?? const [];
      notifyListeners();
    } on FormatException {
      // Malformed status is not worth failing the UI over.
    }
  }

  // --- setup ---------------------------------------------------------------

  Future<NameCheck> checkName(String name) => provisioner.checkAvailable(name);

  Future<bool> claimName({required String name, required String inviteCode}) async {
    errorMessage = null;
    notifyListeners();

    try {
      claim = await provisioner.claim(name: name, inviteCode: inviteCode);
      stage = SetupStage.createLogin;
      notifyListeners();
      return true;
    } on ProvisionError catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    } catch (_) {
      errorMessage = 'Could not reach the signup service. Check the connection.';
      notifyListeners();
      return false;
    }
  }

  Future<bool> createLogin({
    required String username,
    required String password,
  }) async {
    final problem = validateCredentials(username, password);
    if (problem != null) {
      errorMessage = problem;
      notifyListeners();
      return false;
    }

    await _auth!.createAccount(username: username, password: password);
    stage = SetupStage.ready;
    notifyListeners();

    await startDrive();
    return true;
  }

  static String? validateCredentials(String username, String password) {
    final u = username.trim();
    if (u.length < 3 || u.length > 32) return 'Username must be 3-32 characters.';
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(u)) {
      return 'Username can use letters, digits, and _ . - only.';
    }
    // This login is the only thing between the internet and every file on the
    // card, so a short password is not an acceptable trade for convenience.
    if (password.length < 10) return 'Password must be at least 10 characters.';
    return null;
  }

  // --- running -------------------------------------------------------------

  Future<void> startDrive() async {
    if (claim == null) return;

    // Android 13+ refuses to show the service notification without this, and
    // a foreground service with no visible notification gets killed.
    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask('status');
      return;
    }

    tunnelState = TunnelState.starting;
    tunnelError = null;
    notifyListeners();

    final result = await FlutterForegroundTask.startService(
      serviceId: 2601,
      notificationTitle: 'PocketShare',
      notificationText: 'Starting the drive…',
      callback: startDriveCallback,
    );

    if (result is ServiceRequestFailure) {
      tunnelState = TunnelState.failed;
      tunnelError =
          'Could not start the background service: ${result.error}';
      notifyListeners();
    }
  }

  Future<void> stopDrive() async {
    await FlutterForegroundTask.stopService();
    tunnelState = TunnelState.stopped;
    tunnelError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    _store?.close();
    super.dispose();
  }
}
