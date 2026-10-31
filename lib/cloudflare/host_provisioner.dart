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

  /// Moves a drive to a new name on the same domain, keeping its tunnel.
  ///
  /// The tunnel's id and token are unchanged, so the running cloudflared
  /// keeps its connection and the phone keeps the only credential it has.
  /// What moves is the tunnel's name, its ingress hostname, and DNS.
  ///
  /// The old name is left genuinely free: its DNS record is deleted and the
  /// tunnel stops carrying it, so re-claiming it later takes the ordinary
  /// path rather than running into a live leftover.
  ///
  /// Returns the new hostname. Needs the Cloudflare token, so this is the
  /// host path only — a guest's claim lives on the provisioning Worker, which
  /// has no rename of its own.
  Future<String> rename({required String from, required String to}) async {
    final source = DriveName.normalize(from);
    final target = DriveName.normalize(to);

    final problem = DriveName.problem(target);
    if (problem != null) throw CloudflareError(problem);
    if (source == target) {
      throw CloudflareError('The drive is already called $target.');
    }

    final oldHost = '$source.$zone';
    final newHost = '$target.$zone';
    final oldTunnel = DriveName.tunnelName(source);
    final newTunnel = DriveName.tunnelName(target);

    final (tunnelId, alreadyRenamed) = await _tunnelToMove(oldTunnel, newTunnel);

    if (!alreadyRenamed) {
      // First, because it is the step that can discover the new name is
      // taken, and the only one that changes nothing when it fails.
      await api.renameTunnel(
        accountId: accountId,
        tunnelId: tunnelId,
        name: newTunnel,
      );
    }

    try {
      // Both addresses at once, so the drive keeps answering on the old one
      // until the new record is live. Without this there is a gap where
      // neither works: ingress no longer matches the old hostname and DNS
      // for the new one has not been written yet.
      await api.configureIngressFor(
        accountId: accountId,
        tunnelId: tunnelId,
        hostnames: [newHost, oldHost],
      );
      await api.upsertCname(
        zoneId: zoneId,
        fqdn: newHost,
        content: '$tunnelId.cfargotunnel.com',
      );
    } catch (_) {
      // Nothing published yet, so put the tunnel back as it was and let the
      // caller report a move that simply did not happen.
      await _undo(tunnelId, oldTunnel, oldHost, renamed: !alreadyRenamed);
      rethrow;
    }

    // Past here the new address exists and works. The rest is releasing the
    // old one, and a failure must not be reported as a failed rename: the
    // move happened. Retrying rename() picks up where this left off, which is
    // what _tunnelToMove's second lookup is for.
    await api.configureIngressFor(
      accountId: accountId,
      tunnelId: tunnelId,
      hostnames: [newHost],
    );
    await api.deleteCname(zoneId: zoneId, fqdn: oldHost);

    return newHost;
  }

  /// The tunnel a rename should move, and whether it has already been renamed.
  ///
  /// Looks for the old name first, then the new one. The second lookup is how
  /// a retry works: a rename interrupted after the tunnel was renamed but
  /// before DNS was written leaves nothing under the old name, and asking
  /// Cloudflare to rename a tunnel to the name it already has is not
  /// something to rely on.
  Future<(String, bool)> _tunnelToMove(String oldTunnel, String newTunnel) async {
    final current = await api.findTunnel(accountId: accountId, name: oldTunnel);
    if (current != null) return (current.id, false);

    final moved = await api.findTunnel(accountId: accountId, name: newTunnel);
    if (moved != null) return (moved.id, true);

    throw CloudflareError(
      'No tunnel named $oldTunnel on this account, so there is nothing to '
      'rename. The drive may have been set up on another phone, or the '
      'tunnel deleted in the Cloudflare dashboard.',
    );
  }

  /// Best effort return to the pre-rename state. The original failure is what
  /// the user needs to hear, so nothing in here is allowed to replace it.
  Future<void> _undo(
    String tunnelId,
    String oldTunnel,
    String oldHost, {
    required bool renamed,
  }) async {
    try {
      await api.configureIngressFor(
        accountId: accountId,
        tunnelId: tunnelId,
        hostnames: [oldHost],
      );
    } catch (_) {}

    if (!renamed) return;
    try {
      await api.renameTunnel(
        accountId: accountId,
        tunnelId: tunnelId,
        name: oldTunnel,
      );
    } catch (_) {}
  }
}
