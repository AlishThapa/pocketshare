import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'dns_check.dart';

enum TunnelState { stopped, starting, registered, verifying, live, failed }

/// Supervises the bundled cloudflared process and proves the hostname is
/// actually reachable before reporting success.
///
/// cloudflared reporting "connected" only means it reached Cloudflare's edge;
/// the hostname can still 1033 for a few seconds until the new connection
/// propagates. Probing once at that moment is a race, so [_verify] polls until
/// the edge agrees or the budget runs out.
class TunnelManager {
  TunnelManager({
    required this.binaryPath,
    required this.hostname,
    required this.token,
    this.localPort = 8080,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String binaryPath;
  final String hostname;
  final String token;
  final int localPort;
  final http.Client _http;

  /// How long to keep asking the edge before giving up. Propagation is usually
  /// seconds; this is deliberately generous because the alternative is telling
  /// the user their setup is broken when it merely needs another moment.
  static const Duration verifyBudget = Duration(seconds: 120);
  static const Duration _probeInterval = Duration(seconds: 3);

  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  Timer? _restartTimer;

  final _stateController = StreamController<TunnelState>.broadcast();
  final _logController = StreamController<String>.broadcast();

  TunnelState _state = TunnelState.stopped;
  TunnelState get state => _state;
  Stream<TunnelState> get states => _stateController.stream;
  Stream<String> get logs => _logController.stream;

  /// Rolling tail kept for the in-app diagnostics screen.
  final List<String> recentLogs = [];
  static const int _maxLogLines = 300;

  String? lastError;
  int _restartAttempt = 0;
  int _verifyGeneration = 0;
  bool _stopRequested = false;

  void _setState(TunnelState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _log(String line) {
    recentLogs.add(line);
    if (recentLogs.length > _maxLogLines) {
      recentLogs.removeRange(0, recentLogs.length - _maxLogLines);
    }
    if (!_logController.isClosed) _logController.add(line);
  }

  Future<void> start() async {
    if (_process != null) return;
    _stopRequested = false;
    lastError = null;
    _setState(TunnelState.starting);

    final binary = File(binaryPath);
    if (!await binary.exists()) {
      lastError = 'cloudflared is missing from this build';
      _setState(TunnelState.failed);
      return;
    }

    // cloudflared is a cgo-free Go binary, so it uses Go's own resolver, which
    // reads /etc/resolv.conf. Android has no such file — DNS goes through
    // netd — so Go falls back to localhost:53 and every lookup fails. Dart's
    // resolver does work here, so resolve the edge ourselves and pass the
    // addresses in, bypassing cloudflared's discovery entirely.
    final edges = await _resolveEdgeAddresses();
    if (edges.isEmpty) {
      lastError = 'No internet connection.';
      _setState(TunnelState.failed);
      return;
    }
    _log('using ${edges.length} edge address(es)');

    try {
      _process = await Process.start(
        binaryPath,
        [
          'tunnel',
          '--no-autoupdate',
          // --edge is repeatable, not comma-separated: one flag per address.
          for (final edge in edges) ...['--edge', edge],
          // Keep cloudflared's own metrics server off; nothing reads it and it
          // would be one more listening socket on the device.
          '--metrics', '127.0.0.1:0',
          'run',
          '--token', token,
        ],
        // cloudflared writes its own state under HOME; without this it tries
        // paths the app sandbox cannot create.
        environment: {'HOME': File(binaryPath).parent.path, 'TMPDIR': '/data/local/tmp'},
      );
    } on ProcessException catch (e) {
      lastError = 'could not start cloudflared: ${e.message}';
      _setState(TunnelState.failed);
      return;
    }

    _stdout = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLogLine);
    _stderr = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLogLine);

    unawaited(_process!.exitCode.then(_onExit));
    unawaited(_verify());
  }

  void _onLogLine(String line) {
    _log(line);

    final lower = line.toLowerCase();
    if (lower.contains('registered tunnel connection') ||
        lower.contains('connection established')) {
      if (_state == TunnelState.starting) _setState(TunnelState.registered);
    }

    // Token problems are terminal: retrying cannot fix them, so surface the
    // cause instead of letting the backoff loop hide it.
    if (lower.contains('invalid tunnel secret') ||
        lower.contains('token is not valid') ||
        lower.contains('unauthorized')) {
      lastError = 'Cloudflare rejected this drive\'s tunnel token.';
    }
  }

  /// Polls the public hostname until it answers, then reports [TunnelState.live].
  Future<void> _verify() async {
    // Each restart starts a fresh probe; older loops must stand down or they
    // race each other and report stale results.
    final generation = ++_verifyGeneration;

    _setState(TunnelState.verifying);
    final deadline = DateTime.now().add(verifyBudget);
    final url = Uri.parse('https://$hostname/api/health');

    var attempt = 0;
    // Counted separately from other failures: a name that will not resolve
    // and an address that will not answer need opposite advice, and only one
    // of them is the drive's fault.
    var lookupFailures = 0;
    while (DateTime.now().isBefore(deadline) &&
        !_stopRequested &&
        generation == _verifyGeneration) {
      attempt++;
      try {
        final res = await _http.get(url).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          _log('health check passed after $attempt attempt(s)');
          _restartAttempt = 0;
          _setState(TunnelState.live);
          return;
        }
        // 530 here is Cloudflare error 1033: the edge has the route but has
        // not yet seen this connection. Expected for the first few seconds.
        _log('health check: HTTP ${res.statusCode} (attempt $attempt)');
      } on TimeoutException {
        _log('health check timed out (attempt $attempt)');
      } on SocketException catch (e) {
        if (DnsCheck.isLookupFailure(e)) lookupFailures++;
        _log('health check network error: ${e.message} (attempt $attempt)');
      } on http.ClientException catch (e) {
        _log('health check failed: ${e.message} (attempt $attempt)');
      }

      await Future<void>.delayed(_probeInterval);
    }

    if (_stopRequested || generation != _verifyGeneration) return;
    lastError ??= await _explainFailure(lookupFailures);
    _setState(TunnelState.failed);
  }

  /// Turns a verify timeout into advice the user can act on.
  ///
  /// The case worth separating is a hostname this phone cannot resolve while
  /// the rest of the internet can. That happens after a rename: the record is
  /// seconds old, something here asked before it existed, and the "no such
  /// name" got cached for the zone's SOA minimum. Reporting that as "the
  /// drive did not answer" sends the user to debug a drive that is serving
  /// perfectly well to everyone else.
  Future<String> _explainFailure(int lookupFailures) async {
    if (lookupFailures == 0) {
      return '$hostname did not answer within ${verifyBudget.inSeconds}s. '
          'The drive is running; the address may still be propagating.';
    }

    switch (await DnsCheck.published(hostname, client: _http)) {
      case true:
        return 'This phone cannot look up $hostname, but the address is live '
            '— public DNS has it, and other devices can reach it now. This '
            'phone asked for the name moments before it existed and cached '
            'the "not found", which clears within about half an hour. '
            'Switching to mobile data and back is the quick way round it.';
      case false:
        return '$hostname has no DNS record yet. The drive itself is running '
            'and will answer as soon as the record appears.';
      case null:
        return 'Could not look up $hostname, and could not reach public DNS '
            'to find out why. Check this phone\'s connection.';
    }
  }

  /// Resolves the Cloudflare tunnel edge via Dart's resolver.
  ///
  /// These are the hosts cloudflared's own SRV discovery would find
  /// (`_v2-origintunneld._tcp.argotunnel.com` -> region1/region2, port 7844).
  static Future<List<String>> _resolveEdgeAddresses() async {
    const hosts = ['region1.v2.argotunnel.com', 'region2.v2.argotunnel.com'];
    const edgePort = 7844;

    final addresses = <String>[];
    for (final host in hosts) {
      try {
        final found = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 10));
        // Anycast: a few addresses per region is ample, and each one becomes
        // two more argv entries.
        addresses.addAll(
          found.take(4).map((a) => '${a.address}:$edgePort'),
        );
      } on SocketException {
        continue;
      } on TimeoutException {
        continue;
      }
    }
    return addresses;
  }

  Future<void> _onExit(int code) async {
    _log('cloudflared exited with code $code');
    await _cleanupProcess();

    if (_stopRequested) {
      _setState(TunnelState.stopped);
      return;
    }

    // Exponential backoff, capped. A phone that loses Wi-Fi overnight should
    // reconnect on its own rather than needing someone to open the app.
    _restartAttempt++;
    final delay = Duration(
      seconds: [2, 5, 15, 30, 60][
          _restartAttempt > 5 ? 4 : _restartAttempt - 1],
    );
    _log('restarting in ${delay.inSeconds}s (attempt $_restartAttempt)');
    _setState(TunnelState.starting);

    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (!_stopRequested) unawaited(start());
    });
  }

  Future<void> stop() async {
    _stopRequested = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    final proc = _process;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      // Give it a moment to close connections cleanly before forcing it.
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        proc.kill(ProcessSignal.sigkill);
      }
    }

    await _cleanupProcess();
    _setState(TunnelState.stopped);
  }

  Future<void> _cleanupProcess() async {
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    _process = null;
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
    await _logController.close();
    _http.close();
  }
}
