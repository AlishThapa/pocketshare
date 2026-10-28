import 'api.dart';
import 'names.dart';

class Provisioned {
  const Provisioned({required this.hostname, required this.tunnelToken});
  final String hostname;
  final String tunnelToken;
}

/// Creates a drive address on a domain this phone's Cloudflare token owns.
///
/// This is the host side. It runs on the owner's phone, so the API token
/// never leaves the device that created it — a guest asks its host to do
/// this rather than holding a credential of its own.
class HostProvisioner {
  HostProvisioner({
    required this.api,
    required this.accountId,
    required this.zoneId,
    required this.zone,
  });

  final CloudflareApi api;
  final String accountId;
  final String zoneId;
  final String zone;

  /// Creates a tunnel, points it at the drive, and publishes the DNS record.
  ///
  /// When a tunnel of that name already exists and nothing is connected to
  /// it, it is adopted instead of refused. That is what a reinstall looks
  /// like: uninstalling wipes the app's copy of the tunnel token but leaves
  /// the tunnel standing on the account, so without this, re-claiming your
  /// own name means a trip to the Cloudflare dashboard to delete it by hand.
  /// A tunnel with a live connection is still refused — see
  /// [CfExistingTunnel.active].
  ///
  /// Any failure after the tunnel exists deletes it again, but only if this
  /// call is what created it. Without the rollback, a half-made claim leaves
  /// a tunnel holding the name; without the condition, a failed re-claim
  /// would delete the very tunnel the user is trying to recover.
  Future<Provisioned> provision(String rawName) async {
    final name = DriveName.normalize(rawName);
    final problem = DriveName.problem(name);
    if (problem != null) throw CloudflareError(problem);

    final hostname = '$name.$zone';
    final tunnelName = DriveName.tunnelName(name);

    final (tunnelId, createdToken, adopted) = await _tunnelFor(tunnelName);

    try {
      await api.configureIngress(
        accountId: accountId,
        tunnelId: tunnelId,
        hostname: hostname,
      );
      await api.upsertCname(
        zoneId: zoneId,
        fqdn: hostname,
        content: '$tunnelId.cfargotunnel.com',
      );
    } catch (_) {
      if (!adopted) {
        try {
          await api.deleteTunnel(accountId: accountId, tunnelId: tunnelId);
        } catch (_) {
          // Rollback is best effort: the original failure is what matters,
          // and swallowing a cleanup error keeps it from masking that.
        }
      }
      rethrow;
    }

    // Ask for the token rather than trusting create's copy: a tunnel that
    // already existed and was adopted does not carry one.
    final token = createdToken.isNotEmpty
        ? createdToken
        : await api.tunnelToken(accountId: accountId, tunnelId: tunnelId);

    return Provisioned(hostname: hostname, tunnelToken: token);
  }

  /// The tunnel to use for [tunnelName]: a new one, or a dormant existing one.
  ///
  /// Returns its id, the token creation handed back (empty when adopted), and
  /// whether it was adopted — which decides whether rollback may delete it.
  Future<(String, String, bool)> _tunnelFor(String tunnelName) async {
    try {
      final made =
          await api.createTunnel(accountId: accountId, name: tunnelName);
      return (made.id, made.token, false);
    } on CloudflareError catch (e) {
      if (!e.isDuplicateTunnel) rethrow;

      final existing =
          await api.findTunnel(accountId: accountId, name: tunnelName);
      // Gone between the two calls, or named something this token cannot
      // see. Either way the original refusal is the truthful answer.
      if (existing == null) rethrow;

      if (existing.active) {
        throw CloudflareError(
          'A drive is running at that name right now, on this phone or '
          'another one. Stop it there before claiming the name here, or '
          'pick a different name.',
        );
      }
      return (existing.id, '', true);
    }
  }

  /// Moves a drive to a new name, keeping its tunnel.
  ///
  /// Only DNS changes, so the tunnel token stays valid and the running
  /// service does not have to reconnect.
  Future<String> rename({
    required String from,
    required String to,
    required String tunnelId,
  }) async {
    final target = DriveName.normalize(to);
    final problem = DriveName.problem(target);
    if (problem != null) throw CloudflareError(problem);

    final hostname = '$target.$zone';
    await api.configureIngress(
      accountId: accountId,
      tunnelId: tunnelId,
      hostname: hostname,
    );
    await api.upsertCname(
      zoneId: zoneId,
      fqdn: hostname,
      content: '$tunnelId.cfargotunnel.com',
    );
    // Only now release the old name, so a failure above leaves the drive
    // reachable at the address it already had.
    await api.deleteCname(zoneId: zoneId, fqdn: '${DriveName.normalize(from)}.$zone');
    return hostname;
  }
}
