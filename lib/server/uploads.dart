import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'files.dart';
import 'store.dart';

/// Resumable chunked uploads.
///
/// The browser opens a session, PUTs fixed-size chunks (retrying individually
/// on failure), then asks to finalize. Chunks land in a staging directory and
/// are concatenated on completion, so a dropped connection costs one chunk
/// rather than the whole transfer.
class UploadManager {
  UploadManager({required this.root, required this.staging});

  final Directory root;
  final Directory staging;

  final Map<String, UploadSession> _sessions = {};
  static final _rng = Random.secure();

  /// Abandoned sessions are swept after this long so a cancelled 4 GB upload
  /// does not hold the card hostage.
  static const Duration sessionTtl = Duration(hours: 12);

  Future<UploadSession> create({
    required String destinationPath,
    required int totalSize,
    required int chunkSize,
  }) async {
    if (totalSize < 0) throw DriveConflict('bad size');
    if (chunkSize <= 0) throw DriveConflict('bad chunk size');

    final target = resolveFile(root, destinationPath);
    if (target == null) throw DrivePathError('path outside drive');
    if (await target.exists()) throw DriveConflict('file already exists');

    final id = _newId();
    final dir = Directory(p.join(staging.path, id));
    await dir.create(recursive: true);

    final session = UploadSession(
      id: id,
      destination: target.path,
      totalSize: totalSize,
      chunkSize: chunkSize,
      staging: dir,
    );
    _sessions[id] = session;
    return session;
  }

  UploadSession? find(String id) => _sessions[id];

  Future<void> writeChunk(UploadSession s, int index, Stream<List<int>> body) async {
    if (index < 0 || index >= s.chunkCount) {
      throw DriveConflict('chunk index out of range');
    }

    // Write to a temp name and rename, so a half-written chunk interrupted
    // mid-PUT is never mistaken for a complete one on resume.
    final partial = File(p.join(s.staging.path, '$index.part'));
    // addStream + close, not pipe(): pipe() closes the sink itself, so a
    // close() in a finally would double-close and throw.
    final sink = partial.openWrite();
    try {
      await sink.addStream(body);
    } finally {
      await sink.close();
    }

    await partial.rename(p.join(s.staging.path, '$index'));
    s.received.add(index);
    s.touch();
  }

  /// Indices the client still owes us. Lets an interrupted upload resume
  /// without re-sending what already landed.
  Future<List<int>> missing(UploadSession s) async {
    final have = <int>{};
    await for (final e in s.staging.list(followLinks: false)) {
      final name = p.basename(e.path);
      final n = int.tryParse(name);
      if (n != null) have.add(n);
    }
    return [
      for (var i = 0; i < s.chunkCount; i++)
        if (!have.contains(i)) i,
    ];
  }

  Future<File> complete(UploadSession s) async {
    final gaps = await missing(s);
    if (gaps.isNotEmpty) {
      throw DriveConflict('missing ${gaps.length} chunk(s)');
    }

    final dest = File(s.destination);
    await dest.parent.create(recursive: true);

    // Assemble into a sibling temp file first; a crash mid-assembly then
    // leaves no partial file sitting at the destination looking complete.
    final tmp = File('${s.destination}.ps-incoming');
    final sink = tmp.openWrite();
    try {
      for (var i = 0; i < s.chunkCount; i++) {
        await sink.addStream(File(p.join(s.staging.path, '$i')).openRead());
      }
    } finally {
      await sink.close();
    }

    final written = await tmp.length();
    if (written != s.totalSize) {
      await tmp.delete();
      throw DriveConflict('size mismatch: got $written, expected ${s.totalSize}');
    }

    await tmp.rename(s.destination);
    await discard(s);
    return dest;
  }

  Future<void> discard(UploadSession s) async {
    _sessions.remove(s.id);
    if (await s.staging.exists()) {
      await s.staging.delete(recursive: true);
    }
  }

  /// Drops sessions idle past [sessionTtl]. Called periodically by the server.
  Future<void> sweep() async {
    final dead = _sessions.values
        .where((s) => DateTime.now().difference(s.lastTouched) > sessionTtl)
        .toList();
    for (final s in dead) {
      await discard(s);
    }
  }

  static String _newId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => alphabet[_rng.nextInt(alphabet.length)]).join();
  }
}

class UploadSession {
  UploadSession({
    required this.id,
    required this.destination,
    required this.totalSize,
    required this.chunkSize,
    required this.staging,
  }) : lastTouched = DateTime.now();

  final String id;
  final String destination;
  final int totalSize;
  final int chunkSize;
  final Directory staging;

  final Set<int> received = {};
  DateTime lastTouched;

  int get chunkCount =>
      totalSize == 0 ? 0 : (totalSize + chunkSize - 1) ~/ chunkSize;

  void touch() => lastTouched = DateTime.now();

  Map<String, Object?> toJson() => {
        'id': id,
        'chunkSize': chunkSize,
        'chunkCount': chunkCount,
        'totalSize': totalSize,
      };
}
