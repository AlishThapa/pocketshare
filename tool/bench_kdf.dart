import 'dart:convert';
import 'package:pocketshare/server/auth.dart';
import 'package:pocketshare/server/store.dart';
import 'dart:io';

void main() async {
  final dir = Directory.systemTemp.createTempSync('ps_bench');
  final store = await DriveStore.open(
    root: Directory('${dir.path}/root'),
    dbFile: File('${dir.path}/meta.db'),
  );
  final auth = Auth(store);

  var sw = Stopwatch()..start();
  await auth.createAccount(username: 'alish', password: 'correct horse battery');
  print('createAccount: ${sw.elapsedMilliseconds} ms');

  sw = Stopwatch()..start();
  final tok = await auth.login(username: 'alish', password: 'correct horse battery');
  print('login(ok):     ${sw.elapsedMilliseconds} ms  token=${tok != null}');

  sw = Stopwatch()..start();
  final bad = await auth.login(username: 'alish', password: 'wrong');
  print('login(bad):    ${sw.elapsedMilliseconds} ms  token=${bad != null}');

  print('validate:      ${auth.validate(tok!)}');
  store.close();
  dir.deleteSync(recursive: true);
}
