// Runs the drive server on this machine against a scratch directory, so the
// web UI can be exercised in a desktop browser without a phone in the loop.
//
//   dart run tool/dev_server.dart [port]
//
// Login is alish / dev-password-1234. The drive root and database live under
// .dev_drive/ and persist between runs.
import 'dart:io';

import 'package:pocketshare/server/auth.dart';
import 'package:pocketshare/server/files.dart';
import 'package:pocketshare/server/server.dart';
import 'package:pocketshare/server/store.dart';
import 'package:pocketshare/server/uploads.dart';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8080 : int.parse(args.first);

  final base = Directory('.dev_drive');
  final root = Directory('${base.path}/files')..createSync(recursive: true);
  final staging = Directory('${base.path}/staging')..createSync(recursive: true);
  final web = Directory('assets/web');
  if (!web.existsSync()) {
    stderr.writeln('run this from the project root: assets/web not found');
    exit(1);
  }

  final store = await DriveStore.open(
    root: root,
    dbFile: File('${base.path}/meta.db'),
  );
  final auth = Auth(store);
  if (!auth.hasAccount) {
    await auth.createAccount(username: 'alish', password: 'dev-password-1234');
    stdout.writeln('created account alish / dev-password-1234');
  }

  final server = DriveServer(
    store: store,
    auth: auth,
    files: DriveFiles(root),
    uploads: UploadManager(root: root, staging: staging),
    webRoot: web,
    port: port,
  );
  await server.start();
  stdout.writeln('drive on http://127.0.0.1:${server.boundPort}  root=${root.absolute.path}');
}
