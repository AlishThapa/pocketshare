// Checks the folder rules and the directory listing.
// Run: dart run tool/smoke_files.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketshare/files/listing.dart';
import 'package:pocketshare/storage/folder_rules.dart';
import 'package:pocketshare/storage/migrate.dart';

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

Future<void> main() async {
  const roots = ['/storage/emulated/0', '/storage/1A2B-3C4D'];

  print('\n-- folders the drive may serve --');
  check('a normal folder is fine',
      FolderRules.problem('/storage/emulated/0/PocketShare', roots) == null);
  check('nested is fine',
      FolderRules.problem('/storage/emulated/0/Docs/Share', roots) == null);
  check('a folder on the card is fine',
      FolderRules.problem('/storage/1A2B-3C4D/Drive', roots) == null);

  // The one that matters: picking the volume root would publish the whole
  // phone — camera roll, downloads, every other app's shared files.
  check('refuses the internal volume root',
      FolderRules.problem('/storage/emulated/0', roots) != null);
  check('refuses the card root',
      FolderRules.problem('/storage/1A2B-3C4D', roots) != null);
  check('refuses a trailing slash on the root',
      FolderRules.problem('/storage/emulated/0/', roots) != null);
  check('says why the root is refused',
      FolderRules.problem('/storage/emulated/0', roots)!.contains('published'));

  check('refuses app sandboxes',
      FolderRules.problem('/storage/emulated/0/Android', roots) != null);
  check('refuses inside Android/data',
      FolderRules.problem('/storage/emulated/0/Android/data/x', roots) != null);

  check('refuses somewhere off the volumes',
      FolderRules.problem('/data/data/np.com.thapaalish.pocketshare', roots) !=
          null);
  check('refuses the filesystem root', FolderRules.problem('/', roots) != null);
  check('refuses a relative path',
      FolderRules.problem('PocketShare', roots) != null);
  check('refuses empty', FolderRules.problem('', roots) != null);

  // A path that normalises to something legal is still refused: the path on
  // screen has to be the path served, or the warning about what is published
  // is about a different folder than the one that ends up published.
  check('refuses a path with ..',
      FolderRules.problem('/storage/emulated/0/a/../Android', roots) != null);
  check('refuses a doubled separator',
      FolderRules.problem('/storage/emulated/0//Docs', roots) != null);
  check('refuses a trailing slash',
      FolderRules.problem('/storage/emulated/0/Docs/', roots) != null);

  check('picks the longest matching root', () {
    // A card mounted under the internal root must not be read as a folder on
    // it, or its own root would pass the "not a volume root" check.
    const nested = ['/storage/emulated/0', '/storage/emulated/0/card'];
    return FolderRules.problem('/storage/emulated/0/card', nested) != null;
  }());

  check('no volumes means nothing is allowed',
      FolderRules.problem('/storage/emulated/0/PocketShare', const []) != null);

  print('\n-- sizes and counts --');
  check('bytes', Listing.humanSize(512) == '512 B', Listing.humanSize(512));
  check('kilobytes', Listing.humanSize(2048) == '2.0 KB');
  check('megabytes', Listing.humanSize(5 * 1024 * 1024) == '5.0 MB');
  check('drops the decimal when big',
      Listing.humanSize(500 * 1024 * 1024) == '500 MB',
      Listing.humanSize(500 * 1024 * 1024));
  check('zero', Listing.humanSize(0) == '0 B');
  check('empty folder', Listing.humanCount(0) == 'Empty');
  check('one item', Listing.humanCount(1) == '1 item');
  check('many', Listing.humanCount(12) == '12 items');
  check('caps the count', Listing.humanCount(1000) == '999+ items');

  print('\n-- dates --');
  final now = DateTime(2026, 3, 14, 18, 30);
  check('today shows the time',
      Listing.humanWhen(DateTime(2026, 3, 14, 9, 5), now: now) == '09:05',
      Listing.humanWhen(DateTime(2026, 3, 14, 9, 5), now: now));
  check('this week shows the weekday',
      Listing.humanWhen(DateTime(2026, 3, 11, 9, 5), now: now) == 'Wed',
      Listing.humanWhen(DateTime(2026, 3, 11, 9, 5), now: now));
  check('older shows the date',
      Listing.humanWhen(DateTime(2026, 1, 2), now: now) == '2 Jan',
      Listing.humanWhen(DateTime(2026, 1, 2), now: now));
  check('another year is spelled out',
      Listing.humanWhen(DateTime(2024, 1, 2), now: now) == '2 Jan 2024');
  check('null is blank', Listing.humanWhen(null) == '');

  print('\n-- reading a real directory --');
  final tmp = await Directory.systemTemp.createTemp('ps-files-');
  try {
    await File(p.join(tmp.path, 'zebra.txt')).writeAsString('hello');
    await File(p.join(tmp.path, 'Apple.txt')).writeAsString('hi');
    await Directory(p.join(tmp.path, 'mid')).create();
    await File(p.join(tmp.path, 'mid', 'one')).writeAsString('1');
    await File(p.join(tmp.path, 'mid', 'two')).writeAsString('2');

    // The drive's own trash lives here; the web UI hides it and so must this.
    await Directory(p.join(tmp.path, Listing.internalFolder, 'trash'))
        .create(recursive: true);

    // stat() follows links, so a symlink to a directory used to be cast to
    // Directory and throw a TypeError that no catch here would have seen.
    await Link(p.join(tmp.path, 'shortcut')).create(p.join(tmp.path, 'mid'));

    final entries = await Listing.read(tmp);
    check('hides the drive\'s own folder',
        entries.every((e) => e.name != Listing.internalFolder));
    check('survives a symlink to a directory',
        entries.any((e) => e.name == 'shortcut'));
    check('finds everything else', entries.length == 4, '${entries.length}');
    check('folders come first', entries.first.isDirectory);
    check('folder counts its contents', entries.first.size == 2);
    check('then names, case-insensitively',
        entries[1].name == 'Apple.txt' && entries[3].name == 'zebra.txt',
        entries.map((e) => e.name).join(','));
    check('file size is in bytes', entries[3].size == 5);
    check('does not descend',
        entries.every((e) => p.dirname(e.path) == tmp.path));
    check('has a modified time', entries[3].modified != null);

    // A listing is drawn from a card other apps write to; one unreadable row
    // must not take the screen down with it.
    final gone = await Listing.read(Directory(p.join(tmp.path, 'nope')))
        .then<Object?>((e) => e)
        .catchError((Object e) => e);
    check('a missing directory throws rather than lying',
        gone is FileSystemException, '$gone');
  } finally {
    await tmp.delete(recursive: true);
  }

  print('\n-- moving the drive to another folder --');
  final work = await Directory.systemTemp.createTemp('ps-move-');
  try {
    Future<Directory> fresh(String name) =>
        Directory(p.join(work.path, name)).create(recursive: true);

    // The ordinary case.
    var from = await fresh('a/old');
    var to = Directory(p.join(work.path, 'a/new'));
    await File(p.join(from.path, 'notes.txt')).writeAsString('one');
    await Directory(p.join(from.path, 'sub')).create();
    await File(p.join(from.path, 'sub', 'deep.txt')).writeAsString('two');

    var result = await FolderMigration.move(from, to, deleteSource: true);
    check('carries every file across', result.moved == 2);
    check('keeps the folder structure',
        await File(p.join(to.path, 'sub', 'deep.txt')).readAsString() == 'two');
    check('removes an app-made folder', !await from.exists());
    check('and says it did', result.sourceRemoved);

    // The destination is now any folder the user picked, so it can already
    // hold a file of the same name that has nothing to do with the drive.
    from = await fresh('b/old');
    to = await fresh('b/new');
    await File(p.join(from.path, 'report.pdf')).writeAsString('mine');
    await File(p.join(to.path, 'report.pdf')).writeAsString('theirs');

    result = await FolderMigration.move(from, to, deleteSource: true);
    check('moves in beside a name that is taken', result.moved == 1);
    check('leaves what was already there alone',
        await File(p.join(to.path, 'report.pdf')).readAsString() == 'theirs');
    check('and keeps the moved file under another name',
        await File(p.join(to.path, 'report (1).pdf')).readAsString() == 'mine');

    // The one that loses everything: copy inwards, then delete the folder
    // the copies are now inside.
    from = await fresh('c/drive');
    await File(p.join(from.path, 'keep.txt')).writeAsString('precious');
    final inside = Directory(p.join(from.path, 'inner'));
    Object? thrown;
    try {
      await FolderMigration.move(from, inside, deleteSource: true);
    } catch (e) {
      thrown = e;
    }
    check('refuses a folder inside the current one',
        thrown is FileSystemException, '\$thrown');
    check('and does not touch the files',
        await File(p.join(from.path, 'keep.txt')).readAsString() == 'precious');

    check('moving to the same folder does nothing',
        (await FolderMigration.move(from, from, deleteSource: true)).moved == 0);
    check(
        'a source that is gone is not an error',
        (await FolderMigration.move(Directory(p.join(work.path, 'nowhere')), to,
                    deleteSource: true))
                .moved ==
            0);

    // The one the folder picker made reachable: once the drive can live in
    // DCIM or Download, moving it elsewhere must not delete the folder it was
    // living in, along with everything of the user's that was already there.
    from = await fresh('d/Camera');
    to = await fresh('d/Drive');
    await File(p.join(from.path, 'IMG_0001.jpg')).writeAsString('photo');

    result = await FolderMigration.move(from, to, deleteSource: false);
    check('copies out of a folder the user picked', result.moved == 1);
    check('leaves that folder where it was', await from.exists());
    check('and leaves its contents alone',
        await File(p.join(from.path, 'IMG_0001.jpg')).readAsString() == 'photo');
    check('and says the old folder is still there', !result.sourceRemoved);
    check('while the drive has its copy',
        await File(p.join(to.path, 'IMG_0001.jpg')).readAsString() == 'photo');
  } finally {
    await work.delete(recursive: true);
  }

  print('\n$passed passed, $failed failed\n');
  if (failed > 0) throw StateError('$failed checks failed');
}
