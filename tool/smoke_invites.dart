// Checks invite codes. Run: dart run tool/smoke_invites.dart
import 'dart:io';

import 'package:pocketshare/invites/invite_store.dart';
import 'package:sqlite3/sqlite3.dart';

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
  final db = sqlite3.openInMemory();
  final invites = InviteStore(db);

  print('\n-- generated codes --');
  final codes = {for (var i = 0; i < 400; i++) InviteStore.generateCode()};
  check('six characters long',
      codes.every((c) => c.length == InviteStore.codeLength));
  check('only uses the safe alphabet',
      codes.every((c) => c.split('').every(InviteStore.alphabet.contains)));
  check('no ambiguous characters',
      codes.every((c) => !RegExp('[OIL01U]').hasMatch(c)));
  check('400 codes, no repeats', codes.length == 400, '${codes.length}');

  print('\n-- what a person types --');
  check('lowercase is accepted', InviteStore.normalize('k7m2qx') == 'K7M2QX');
  check('surrounding space is ignored',
      InviteStore.normalize('  K7M2QX  ') == 'K7M2QX');
  check('a pasted share string yields the code',
      InviteStore.normalize('K7M2QX@alishm.thapaalish.com.np') == 'K7M2QX');
  check('hyphens typed for readability are ignored',
      InviteStore.normalize('K7M-2QX') == 'K7M2QX');
  check('host is read back out',
      InviteStore.hostFrom('K7M2QX@alishm.thapaalish.com.np') ==
          'alishm.thapaalish.com.np');
  check('no host when none was given',
      InviteStore.hostFrom('K7M2QX') == null);
  check('host is lowercased',
      InviteStore.hostFrom('K7M2QX@ALISHM.Thapaalish.com.np') ==
          'alishm.thapaalish.com.np');

  print('\n-- issuing --');
  final one = invites.create(label: 'Kishan', maxUses: 1);
  check('starts unused', one.uses == 0 && one.remaining == 1);
  check('is usable', one.usable);
  check('keeps its label', one.label == 'Kishan');
  check('share string carries the host',
      one.shareString('alishm.thapaalish.com.np') ==
          '${one.code}@alishm.thapaalish.com.np');
  check('maxUses below 1 is corrected',
      invites.create(maxUses: 0).maxUses == 1);

  print('\n-- redeeming --');
  final five = invites.create(label: 'family', maxUses: 5);
  check('a fresh code has no problem', invites.problem(five.code) == null);
  check('lowercase redeems too',
      invites.problem(five.code.toLowerCase()) == null);
  check('the whole share string redeems too',
      invites.problem('${five.code}@alishm.thapaalish.com.np') == null);
  check('an unknown code is refused',
      invites.problem('ZZZZZZ') == 'that invite code is not valid');

  invites.consume(five.code);
  invites.consume(five.code);
  check('two uses counted', invites.find(five.code)!.uses == 2);
  check('three left', invites.find(five.code)!.remaining == 3);
  check('still usable', invites.find(five.code)!.usable);

  for (var i = 0; i < 3; i++) {
    invites.consume(five.code);
  }
  check('used up', invites.find(five.code)!.exhausted);
  check('refused once used up',
      invites.problem(five.code) == 'that invite code has been used up');
  check('remaining never goes negative',
      invites.find(five.code)!.remaining == 0);

  print('\n-- revoking --');
  final doomed = invites.create(maxUses: 3);
  invites.revoke(doomed.code);
  check('refused after revoking',
      invites.problem(doomed.code) == 'that invite code was cancelled');
  check('revoking does not consume uses',
      invites.find(doomed.code)!.uses == 0);
  check('revoked code still listed, so it can be explained',
      invites.list().any((i) => i.code == doomed.code));
  invites.remove(doomed.code);
  check('removing takes it off the list',
      !invites.list().any((i) => i.code == doomed.code));

  print('\n-- listing --');
  final all = invites.list();
  check('newest first',
      all.first.createdAt.millisecondsSinceEpoch >=
          all.last.createdAt.millisecondsSinceEpoch);
  check('survives a reopen', () {
    final again = InviteStore(db);
    return again.find(one.code)?.code == one.code;
  }());

  db.dispose();
  print('\n$passed passed, $failed failed\n');
  if (failed > 0) exitCode = 1;
}
