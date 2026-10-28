// Exercises the recovery crypto and payload. No device, no network.
// Run: dart run tool/smoke_recovery.dart
import 'package:pocketshare/tunnel/recovery_crypto.dart';
import 'package:pocketshare/tunnel/recovery_payload.dart';

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

RecoveryPayload sample({String hostname = 'tests.thapaalish.com.np'}) =>
    RecoveryPayload(
      hostname: hostname,
      tunnelToken: 'a-tunnel-token-that-is-not-real',
      driveRoot: '/storage/emulated/0/PocketShare',
      rootAppCreated: true,
      username: 'alish',
      passwordHash: 'aGFzaA==',
      passwordSalt: 'c2FsdA==',
      passwordIterations: 600000,
      invites: [
        {'code': 'ABC123', 'uses': 0, 'maxUses': 3},
      ],
      savedAt: 1730000000000,
    );

Future<void> main() async {
  const idA = 'cafebabe12345678';
  const idB = 'cafebabe12345679';

  print('\n-- derivation --');
  final a1 = await RecoveryCrypto.derive(idA);
  final a2 = await RecoveryCrypto.derive(idA);
  final b = await RecoveryCrypto.derive(idB);

  check('the same phone derives the same lookupId', a1.lookupId == a2.lookupId);
  check('and the same key', '${a1.encKey}' == '${a2.encKey}');
  check('a different phone gets a different lookupId', a1.lookupId != b.lookupId);
  check('and a different key', '${a1.encKey}' != '${b.encKey}');

  // The three outputs are what the server may hold versus what it may not.
  // If any two matched, holding one would hand over the other.
  check('lookupId and writeAuth differ', a1.lookupId != a1.writeAuth);
  check('the key is not the lookupId', '${a1.encKey}' != a1.lookupId);
  check('the key is not the writeAuth', '${a1.encKey}' != a1.writeAuth);
  check('the key is 256 bits', a1.encKey.length == 32, '${a1.encKey.length}');
  check('lookupId is url-safe and long enough',
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(a1.lookupId), a1.lookupId);
  check('writeAuth is url-safe and long enough',
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(a1.writeAuth), a1.writeAuth);

  print('\n-- sealing --');
  final sealed = await RecoveryCrypto.seal(sample().toJson(), a1.encKey);
  check('output is versioned', sealed.startsWith('v1.'));
  check('the plaintext is not in the output',
      !sealed.contains('alish') && !sealed.contains('thapaalish'));

  final opened = await RecoveryCrypto.open(sealed, a1.encKey);
  check('it round-trips', opened == sample().toJson());

  final again = await RecoveryCrypto.seal(sample().toJson(), a1.encKey);
  check('sealing twice gives different ciphertext', sealed != again,
      'a fixed nonce would leak that nothing changed');
  check('and both still open',
      await RecoveryCrypto.open(again, a1.encKey) == sample().toJson());

  print('\n-- what must not open --');
  check('another phone cannot read it',
      await RecoveryCrypto.open(sealed, b.encKey) == null);

  // GCM's tag is what makes this one check rather than a hopeful parse.
  final parts = sealed.split('.');
  final flipped = parts[2].replaceRange(5, 6, parts[2][5] == 'A' ? 'B' : 'A');
  check('a single edited character is refused',
      await RecoveryCrypto.open('${parts[0]}.${parts[1]}.$flipped', a1.encKey) == null);
  check('a swapped nonce is refused',
      await RecoveryCrypto.open(
              '${parts[0]}.${(await RecoveryCrypto.seal('x', a1.encKey)).split('.')[1]}.${parts[2]}',
              a1.encKey) ==
          null);
  check('truncation is refused',
      await RecoveryCrypto.open('${parts[0]}.${parts[1]}.${parts[2].substring(0, 8)}',
              a1.encKey) ==
          null);
  check('a future version is refused',
      await RecoveryCrypto.open('v2.${parts[1]}.${parts[2]}', a1.encKey) == null);
  check('nonsense is refused', await RecoveryCrypto.open('nope', a1.encKey) == null);
  check('empty is refused', await RecoveryCrypto.open('', a1.encKey) == null);

  print('\n-- payload --');
  final parsed = RecoveryPayload.parse(sample().toJson())!;
  check('hostname survives', parsed.hostname == 'tests.thapaalish.com.np');
  check('tunnel token survives', parsed.tunnelToken.isNotEmpty);
  check('the login survives as a hash', parsed.passwordHash == 'aGFzaA==');
  check('iterations survive', parsed.passwordIterations == 600000);
  check('invites survive', parsed.invites.single['code'] == 'ABC123');
  check('the drive root survives',
      parsed.driveRoot == '/storage/emulated/0/PocketShare');

  // The deliberate omission: a cracked backup must not hand over a
  // zone-editing credential.
  check('no Cloudflare API token is carried',
      !sample().toJson().toLowerCase().contains('apitoken'));

  print('\n-- payloads that must not parse --');
  check('a newer version is refused',
      RecoveryPayload.parse('{"v":99,"hostname":"a","tunnelToken":"b"}') == null);
  check('a missing hostname is refused',
      RecoveryPayload.parse('{"v":1,"tunnelToken":"b","username":"u"}') == null);
  check('a missing tunnel token is refused',
      RecoveryPayload.parse('{"v":1,"hostname":"a","username":"u"}') == null);
  check('an empty hostname is refused',
      RecoveryPayload.parse(
              '{"v":1,"hostname":"","tunnelToken":"b","username":"u","passwordHash":"h","passwordSalt":"s","passwordIterations":1}') ==
          null);
  check('a wrong-typed iteration count is refused',
      RecoveryPayload.parse(
              '{"v":1,"hostname":"a","tunnelToken":"b","username":"u","passwordHash":"h","passwordSalt":"s","passwordIterations":"lots"}') ==
          null);
  check('garbage is refused', RecoveryPayload.parse('not json') == null);

  print('\n$passed passed, $failed failed\n');
  if (failed > 0) throw StateError('$failed checks failed');
}
