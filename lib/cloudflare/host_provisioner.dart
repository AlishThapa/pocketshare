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
  /// Any failure after the tunnel exists deletes it again. Without that, a
  /// half-made claim leaves a tunnel holding the name, and the same name can
  /// never be claimed again — which is exactly the state a wiped install left
  /// behind and had to be cleaned up by hand.
  Future<Provisioned> provision(String rawName) async {
    final name = DriveName.normalize(rawName);
    final problem = DriveName.problem(name);
    if (problem != null) throw CloudflareError(problem);

    final hostname = '$name.$zone';

    CfTunnel? tunnel;
    try {
      tunnel = await api.createTunnel(
        accountId: accountId,
        name: DriveName.tunnelName(name),
      );
      await api.configureIngress(
        accountId: accountId,
        tunnelId: tunnel.id,
        hostname: hostname,
      );
      await api.upsertCname(
        zoneId: zoneId,
        fqdn: hostname,
        content: '${tunnel.id}.cfargotunnel.com',
      );
    } catch (_) {
      final made = tunnel;
      if (made != null) {
        try {
          await api.deleteTunnel(accountId: accountId, tunnelId: made.id);
        } catch (_) {
          // Rollback is best effort: the original failure is what matters,
          // and swallowing a cleanup error keeps it from masking that.
        }
      }
      rethrow;
    }

    // Ask for the token rather than trusting create's copy: a tunnel that
    // already existed and was adopted does not carry one.
    final token = tunnel.token.isNotEmpty
        ? tunnel.token
        : await api.tunnelToken(accountId: accountId, tunnelId: tunnel.id);

    return Provisioned(hostname: hostname, tunnelToken: token);
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
