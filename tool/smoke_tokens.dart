// Checks the pure token helpers. Run: dart run tool/smoke_tokens.dart
import 'package:pocketshare/storage/token_format.dart';
import 'package:pocketshare/tunnel/device_id.dart';

int passed = 0, failed = 0;

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    passed++;
    print('  PASS  $label');
  } else {
    failed++;
    print('  FAIL  $label  $detail');
  }
}

void main() {
  // A real-shaped Cloudflare API token. Not a live one.
  const api = 'cfut_0123456789abcdefghijklmnopqrstuvwxyz9a2f';
  // A tunnel token is base64 JSON: the credential people most often paste by
  // mistake, because both come from the same dashboard.
  const tunnel = 'eyJhIjoiMDAwIiwidCI6IjExMSIsInMiOiIyMjIifQ';

  print('\n-- masking --');
  final masked = TokenFormat.mask(api);
  check('keeps the prefix', masked.startsWith('cfut_'), masked);
  check('keeps the last 4', masked.endsWith('9a2f'), masked);
  check('hides the middle', !masked.contains('0123456789'), masked);
  check('hides all but 4 of the secret',
      !masked.contains('abcdefghijklmnopqrstuvwxyz'), masked);
  check('fixed width, so length does not leak',
      TokenFormat.mask('cfut_${'a' * 80}9a2f').length == masked.length);
  check('short input is masked entirely',
      !TokenFormat.mask('abc').contains('abc'));
  check('empty input does not throw', TokenFormat.mask('').isNotEmpty);

  print('\n-- fingerprint --');
  check('stable', TokenFormat.fingerprint(api) == TokenFormat.fingerprint(api));
  check('differs for a different token',
      TokenFormat.fingerprint(api) != TokenFormat.fingerprint('$api-x'));
  check('ignores surrounding whitespace',
      TokenFormat.fingerprint('  $api  ') == TokenFormat.fingerprint(api));
  check('does not contain the token',
      !TokenFormat.fingerprint(api).contains('9a2f'));
  check('sameToken agrees', TokenFormat.sameToken(' $api', api));
  check('sameToken rejects a different one',
      !TokenFormat.sameToken(api, '$api-x'));

  print('\n-- shape checks --');
  check('accepts an API token', TokenFormat.looksLikeApiToken(api));
  check('accepts one with no prefix',
      TokenFormat.looksLikeApiToken('a' * 41));
  check('rejects a tunnel token', !TokenFormat.looksLikeApiToken(tunnel));
  check('rejects a truncated paste',
      !TokenFormat.looksLikeApiToken('cfut_tooshort'));
  check('rejects text with spaces',
      !TokenFormat.looksLikeApiToken('${'a' * 40} ${'b' * 10}'));
  check('rejects empty', !TokenFormat.looksLikeApiToken(''));
  check('spots a tunnel token', TokenFormat.looksLikeTunnelToken(tunnel));
  check('does not call an API token a tunnel token',
      !TokenFormat.looksLikeTunnelToken(api));

  print('\n-- device ids --');
  const a = 'cafebabe12345678';
  const b = 'cafebabe12345679';

  check('the same phone derives the same id',
      DeviceId.fromAndroidId(a) == DeviceId.fromAndroidId(a));
  check('a different phone derives a different one',
      DeviceId.fromAndroidId(a) != DeviceId.fromAndroidId(b));

  // The raw value outlives the app, so it is worth not handing out: the
  // Worker has no use for it beyond telling phones apart.
  check('the raw ANDROID_ID is not recoverable from it',
      !DeviceId.fromAndroidId(a).contains(a));
  check('nor is it the bare hash of the id alone',
      DeviceId.fromAndroidId(a) !=
          DeviceId.fromAndroidId('${DeviceId.salt}:$a'));
  check('it is marked as derived', DeviceId.fromAndroidId(a).startsWith('a'));
  check('it is long enough for the Worker to accept',
      DeviceId.fromAndroidId(a).length >= 8);
  check('it is url-safe',
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(DeviceId.fromAndroidId(a)));

  // Several phones of one model sharing an id would let any of them take
  // another's address.
  check('the famous broken ANDROID_ID is refused',
      !DeviceId.usable('9774d56d682e549c'));
  check('a missing id is refused', !DeviceId.usable(null));
  check('an empty id is refused', !DeviceId.usable(''));
  check('a blank id is refused', !DeviceId.usable('   '));
  check('a real id is accepted', DeviceId.usable(a));

  print('\n$passed passed, $failed failed\n');
  if (failed > 0) throw StateError('$failed checks failed');
}
