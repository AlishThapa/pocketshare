import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../cloudflare/api.dart';
import '../invites/invite_store.dart';
import '../cloudflare/host_provisioner.dart';
import '../cloudflare/names.dart';
import '../native.dart';
import '../storage/secrets.dart';
import '../storage/token_format.dart';
import '../server/auth.dart';
import '../server/store.dart';
import '../service/drive_task.dart';
import '../storage/drive_location.dart';
import '../storage/folder_rules.dart';
import '../storage/migrate.dart';
import '../tunnel/cloudflared.dart';
import '../tunnel/dns_check.dart';
import '../tunnel/provision.dart';
import '../tunnel/recovery_payload.dart';
import '../tunnel/recovery_vault.dart';

enum SetupStage {
  loading,

  /// Screen one: invite code, or your own Cloudflare. Asking this first keeps
  /// someone who was simply handed a code from ever seeing a word about
  /// tokens or domains.
  choosePath,

  /// Guest path: invite code and name together.
  claimName,

  /// Host path: paste an API token, pick a domain, pick a name.
  connectCloudflare,

  createLogin,
  ready,
}

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

  /// Whether this phone has a vendor autostart screen. Samsung, Pixel and
  /// stock Android do not, and the prompt is meaningless there.
  bool hasAutostartScreen = false;
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
    recoveryEnabled = await _settings.read(key: _kRecoveryOn) == 'yes';
    recoveryAvailable = await vault.available();
    hasAutostartScreen = await Native.hasAutostartSettings();

    claim = await provisioner.saved();
    isHost = await Secrets.isHost;

    // An install that claimed its name before device ids were derived from
    // the hardware still holds a random one, which the next uninstall would
    // wipe and strand the name. Move it across now, while the phone still
    // knows the id the Worker has on file. Unawaited: it is a network call
    // at startup and nothing on screen depends on it.
    final existing = claim;
    if (existing != null && !isHost) {
      unawaited(provisioner.adoptStableId(existing.hostname));
    }

    if (claim == null) {
      stage = SetupStage.choosePath;
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
  static const _kRecoveryOn = 'recovery_backup';

  // --- reinstall recovery ---------------------------------------------------

  late final RecoveryVault vault = RecoveryVault(endpoint: provisioner.endpoint);

  /// Whether an encrypted backup is kept on the Worker. Off unless the user
  /// turns it on: it is the only thing in this app that puts a credential
  /// anywhere but the phone, even encrypted, and that is a choice to make
  /// rather than a default to discover.
  bool recoveryEnabled = false;

  /// False where ANDROID_ID cannot be trusted, in which case the setting is
  /// hidden rather than offered and silently broken.
  bool recoveryAvailable = false;

  Future<void> setRecoveryBackup(bool on) async {
    recoveryEnabled = on;
    notifyListeners();
    await _settings.write(key: _kRecoveryOn, value: on ? 'yes' : 'no');

    // Turning it off deletes the copy rather than just stopping updates,
    // because "off" has to mean there is nothing out there.
    if (on) {
      await backUpForRecovery();
    } else {
      await vault.forget();
    }
  }

  /// Writes the current state to the vault. Safe to call often and from
  /// anywhere: it is a no-op when the feature is off, and a failure never
  /// propagates — a backup that could not be written must not break the
  /// thing it was backing up.
  Future<void> backUpForRecovery() async {
    if (!recoveryEnabled) return;
    final current = claim;
    final account = _store?.account;
    if (current == null || account == null) return;

    await vault.save(RecoveryPayload(
      hostname: current.hostname,
      tunnelToken: current.tunnelToken,
      driveRoot: driveRootPath ?? '',
      rootAppCreated: await DriveLocation.rootIsAppCreated(),
      username: account.username,
      passwordHash: account.passwordHash,
      passwordSalt: account.salt,
      passwordIterations: account.iterations,
      invites: _store == null
          ? const []
          : (_inviteStore ??= InviteStore(_store!.db)).export(),
      savedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Looks for a backup belonging to this phone. Null when there is none, or
  /// when it cannot be read — which, since only this phone's key can open it,
  /// is the same answer.
  Future<RecoveryPayload?> findBackup() => vault.restore();

  /// Puts a drive back from [payload] and starts it.
  ///
  /// The login is restored from its stored hash, so the same password works
  /// without the password itself ever having been in the backup. The drive's
  /// folder is restored as a path: the files were never in the backup either,
  /// because they were never inside app storage to begin with.
  Future<void> restoreFromBackup(RecoveryPayload payload) async {
    final store = _store;
    if (store == null) return;

    if (payload.driveRoot.isNotEmpty) {
      await DriveLocation.save(
        payload.driveRoot,
        appCreated: payload.rootAppCreated,
      );
    }

    store.createAccount(
      username: payload.username,
      passwordHash: payload.passwordHash,
      salt: payload.passwordSalt,
      iterations: payload.passwordIterations,
    );

    if (payload.invites.isNotEmpty) {
      (_inviteStore ??= InviteStore(store.db)).restore(payload.invites);
    }

    claim = await provisioner.adopt(
      hostname: payload.hostname,
      tunnelToken: payload.tunnelToken,
    );

    recoveryEnabled = true;
    await _settings.write(key: _kRecoveryOn, value: 'yes');

    stage = SetupStage.ready;
    notifyListeners();

    await refreshInvites();
    await startDrive();
  }

  /// Volumes the user can move the drive to. UI isolate only.
  Future<List<StorageVolume>> storageVolumes() => DriveLocation.volumes();

  /// The storage roots this device reports, for validating a chosen folder.
  Future<List<String>> volumeRoots() async =>
      (await storageVolumes()).map((v) => v.path).toList();

  /// Moves the drive to any folder the user picked.
  ///
  /// The service is stopped first: it holds the SQLite handle and is actively
  /// serving from the old path, and copying files out from under it would race
  /// any in-flight upload.
  ///
  /// The path is re-checked here even though the picker already checked it.
  /// This is the one call that decides what the whole internet-facing drive
  /// serves, so it does not rely on its caller having been careful.
  Future<MoveResult> changeStorageToPath(String path) async {
    final roots = await volumeRoots();
    final problem = FolderRules.problem(path, roots);
    if (problem != null) throw FileSystemException(problem, path);

    final wasRunning = await FlutterForegroundTask.isRunningService;
    if (wasRunning) await stopDrive();

    final from = Directory(driveRootPath ?? (await DriveLocation.resolve()).path);
    final to = Directory(path);

    // The old folder is only deleted if this app made it. Once the user can
    // point the drive at Download or DCIM/Camera, "move the drive" must not
    // mean "and delete the folder it was living in". The second condition is
    // a backstop: a path that reached storage without passing the rules
    // never becomes the target of a recursive delete.
    final appMade = await DriveLocation.rootIsAppCreated() &&
        FolderRules.problem(from.path, roots) == null;

    final MoveResult result;
    try {
      result = await DriveLocation.migrate(from, to, deleteSource: appMade);
    } catch (_) {
      // The move failed, so the drive still belongs where it was. Leaving it
      // stopped would turn a refused folder into an address that went dark.
      if (wasRunning) await startDrive();
      rethrow;
    }

    await DriveLocation.save(to.path, appCreated: false);
    driveRootPath = to.path;
    notifyListeners();

    if (wasRunning) await startDrive();
    return result;
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

  Future<NameCheck> checkName(String name, {required String inviteCode}) =>
      provisioner.checkAvailable(name, inviteCode: inviteCode);

  /// Validates an invite code and learns the domain behind it. The claim
  /// screen cannot offer a name field before this succeeds.
  Future<InviteCheck> checkInvite(String code) =>
      provisioner.checkInvite(code);

  // --- screen one ----------------------------------------------------------

  void choosePathInvite() {
    errorMessage = null;
    stage = SetupStage.claimName;
    notifyListeners();
  }

  void choosePathCloudflare() {
    errorMessage = null;
    stage = SetupStage.connectCloudflare;
    notifyListeners();
  }

  void backToPathChoice() {
    errorMessage = null;
    cfZones = const [];
    _pendingToken = null;
    stage = SetupStage.choosePath;
    notifyListeners();
  }

  // --- host path -----------------------------------------------------------

  // --- invites (host only) -------------------------------------------------

  /// Non-null only on a host. A guest holds no Cloudflare token, so it could
  /// never honour a code it issued.
  InviteStore? _inviteStore;

  bool isHost = false;
  List<Invite> invites = const [];

  /// The address guests send their claim to: this phone's own.
  String? get inviteHostname => claim?.hostname;

  Future<void> refreshInvites() async {
    isHost = await Secrets.isHost;
    if (!isHost) {
      invites = const [];
      notifyListeners();
      return;
    }
    final store = _store;
    if (store == null) return;
    final inviteStore = _inviteStore ??= InviteStore(store.db);
    invites = inviteStore.list();
    notifyListeners();
  }

  Future<Invite?> createInvite({String label = '', int maxUses = 1}) async {
    final store = _store;
    if (store == null || !await Secrets.isHost) return null;
    final inviteStore = _inviteStore ??= InviteStore(store.db);
    final made = inviteStore.create(label: label, maxUses: maxUses);
    invites = inviteStore.list();
    notifyListeners();
    unawaited(backUpForRecovery());
    return made;
  }

  void revokeInvite(String code) {
    _inviteStore?.revoke(code);
    invites = _inviteStore?.list() ?? const [];
    notifyListeners();
  }

  void removeInvite(String code) {
    _inviteStore?.remove(code);
    invites = _inviteStore?.list() ?? const [];
    notifyListeners();
  }

  /// Domains the pasted token can reach. Empty until a token is accepted.
  List<CfZone> cfZones = const [];
  CfZone? cfZone;
  String? cfAccountId;

  /// Held only between pasting the token and choosing a zone. It is written
  /// to secure storage once there is a zone to store with it, and never kept
  /// anywhere else.
  String? _pendingToken;

  /// Verifies the token and loads its zones. This doubles as the scope check:
  /// a token created with no permissions ticked fails here, on the screen
  /// where it was pasted, rather than once a name has been chosen.
  Future<bool> connectCloudflare(String rawToken) async {
    final token = rawToken.trim();
    errorMessage = null;
    notifyListeners();

    if (TokenFormat.looksLikeTunnelToken(token)) {
      errorMessage = 'That is a tunnel token. It can run a tunnel that already '
          'exists, but it cannot create one or write DNS, so it cannot make an '
          'address. Create an API token instead.';
      notifyListeners();
      return false;
    }

    final api = CloudflareApi(token: token);
    try {
      await api.verify();
      final zones = await api.zones();
      if (zones.isEmpty) {
        errorMessage = 'This token cannot see any domain. Give it '
            'Zone / DNS / Edit on the domain you want to use.';
        notifyListeners();
        return false;
      }
      // Deliberately no /accounts call here. Listing accounts is its own
      // permission, so a token with exactly the scopes this needs is refused
      // by it — which looked like a missing permission when it was not one.
      // Each zone already names its owning account.
      cfZones = zones;
      cfZone = zones.length == 1 ? zones.first : null;
      _pendingToken = token;
      notifyListeners();
      return true;
    } on CloudflareError catch (e) {
      errorMessage = switch (e) {
        _ when e.isUnauthorized =>
          'Cloudflare does not recognise that token. Check it was copied whole.',
        _ when e.isForbidden =>
          'That token is missing permissions. It needs Account / Cloudflare '
              'Tunnel / Edit and Zone / DNS / Edit.',
        _ => e.message,
      };
      notifyListeners();
      return false;
    } finally {
      api.close();
    }
  }

  /// Only reached when a zone arrives without its account, which Cloudflare
  /// does not normally do. Listing accounts needs its own permission, so this
  /// is allowed to fail without turning into an error the user sees.
  Future<String?> _accountIdFallback(String token) async {
    final api = CloudflareApi(token: token);
    try {
      final accounts = await api.accounts();
      return accounts.isEmpty ? null : accounts.first.id;
    } on CloudflareError {
      return null;
    } finally {
      api.close();
    }
  }

  void chooseZone(CfZone zone) {
    cfZone = zone;
    notifyListeners();
  }

  /// Creates the address on the chosen domain using this phone's own token.
  Future<bool> provisionAsHost(String rawName) async {
    final token = _pendingToken;
    final zone = cfZone;
    if (token == null || zone == null) {
      errorMessage = 'Connect Cloudflare first.';
      notifyListeners();
      return false;
    }

    final accountId = zone.accountId.isNotEmpty
        ? zone.accountId
        : await _accountIdFallback(token);
    if (accountId == null) {
      errorMessage = 'Could not work out which Cloudflare account owns '
          '${zone.name}. Add Account / Cloudflare Tunnel / Edit to the token.';
      notifyListeners();
      return false;
    }
    cfAccountId = accountId;

    final problem = DriveName.problem(rawName);
    if (problem != null) {
      errorMessage = problem;
      notifyListeners();
      return false;
    }

    errorMessage = null;
    notifyListeners();

    final api = CloudflareApi(token: token);
    try {
      final host = HostProvisioner(
        api: api,
        accountId: accountId,
        zoneId: zone.id,
        zone: zone.name,
      );
      final made = await host.provision(rawName);

      // Store the credential only once something was successfully created
      // with it, so a token that cannot actually provision is never kept.
      await Secrets.saveCloudflare(
        apiToken: token,
        zone: zone.name,
        zoneId: zone.id,
        accountId: accountId,
      );
      claim = await provisioner.adopt(
        hostname: made.hostname,
        tunnelToken: made.tunnelToken,
      );
      _pendingToken = null;
      stage = SetupStage.createLogin;
      notifyListeners();
      return true;
    } on CloudflareError catch (e) {
      // A plain duplicate is handled for us now: HostProvisioner adopts a
      // dormant tunnel of the same name, which is what a reinstall needs.
      // Getting here means the tunnel exists but could not be read back, so
      // the only remaining advice is the manual one.
      errorMessage = e.isDuplicateTunnel
          ? 'A tunnel named ${DriveName.tunnelName(rawName)} is on your '
              'account but could not be read back. Delete it in the '
              'Cloudflare dashboard, or pick another name.'
          : e.message;
      notifyListeners();
      return false;
    } finally {
      api.close();
    }
  }

  /// Moves the drive to a new name on the same domain.
  ///
  /// Host path only: it spends the Cloudflare token, which a guest does not
  /// have. The tunnel is kept, so the phone's tunnel token stays valid and
  /// nothing has to be re-provisioned.
  ///
  /// The drive is restarted afterwards rather than left running. It would
  /// keep serving — the tunnel never dropped — but the service read the old
  /// hostname out of secure storage when it started and is the thing that
  /// proves the address answers. Restarting makes it prove the new one.
  /// What a rename is waiting on, shown while it runs. Null when idle.
  String? renameState;

  Future<bool> renameDrive(String rawName) async {
    final current = claim;
    if (current == null) return false;

    errorMessage = null;
    notifyListeners();

    final token = await Secrets.apiToken();
    final zone = await Secrets.zone();
    final zoneId = await Secrets.zoneId();
    final accountId = await Secrets.accountId();

    if (token == null || zone == null || zoneId == null || accountId == null) {
      errorMessage = 'Renaming needs the Cloudflare connection that made this '
          'address, and this phone does not have it.';
      notifyListeners();
      return false;
    }

    final from = current.hostname.split('.').first;
    final problem = DriveName.problem(rawName);
    if (problem != null) {
      errorMessage = problem;
      notifyListeners();
      return false;
    }

    final api = CloudflareApi(token: token);
    try {
      final host = HostProvisioner(
        api: api,
        accountId: accountId,
        zoneId: zoneId,
        zone: zone,
      );
      final hostname = await host.rename(from: from, to: rawName);

      claim = await provisioner.adopt(
        hostname: hostname,
        tunnelToken: current.tunnelToken,
      );
      notifyListeners();

      // The backup carries the hostname, so an un-refreshed one would restore
      // this phone onto the address it just gave up.
      await backUpForRecovery();

      await stopDrive();

      // Do not let anything on this phone ask for the new name until it
      // exists. The restart below probes it, and a probe that beats the
      // record by a few seconds gets "no such name" — which this phone's
      // resolver then caches for the zone's SOA minimum, half an hour on a
      // Cloudflare zone. The drive ends up live for the entire internet
      // except the phone serving it, and nothing clears that but time.
      //
      // Asked over DoH, so the local resolver is not the one asking and has
      // nothing to cache. A timeout here is not a failure: the rename worked,
      // and the health check is still free to report what it finds.
      renameState = 'Waiting for DNS to pick up $hostname…';
      notifyListeners();
      await DnsCheck.waitUntilPublished(hostname);
      renameState = null;
      notifyListeners();

      await startDrive();
      return true;
    } on CloudflareError catch (e) {
      renameState = null;
      errorMessage = e.isDuplicateTunnel
          ? 'A tunnel named ${DriveName.tunnelName(rawName)} already exists '
              'on your account, so that name is in use. Pick another, or '
              'delete it in the Cloudflare dashboard.'
          : e.message;
      notifyListeners();
      return false;
    } finally {
      api.close();
    }
  }

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

    unawaited(backUpForRecovery());
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
      // A service record can outlive the task inside it: if the isolate threw
      // on the way up, Android keeps the foreground service while nothing is
      // listening. Asking that for status gets no reply, so the drive stays
      // "not reachable" and this button does nothing, forever. When the last
      // thing we saw was a failure, tear the service down and start a fresh
      // one instead of talking to the dead one.
      if (tunnelState == TunnelState.failed ||
          tunnelState == TunnelState.stopped) {
        await FlutterForegroundTask.stopService();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } else {
        FlutterForegroundTask.sendDataToTask('status');
        return;
      }
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
