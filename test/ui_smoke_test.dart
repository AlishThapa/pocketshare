// Renders the running screens against stubbed platform channels.
//
// The app's own screens are the part nobody can check on a laptop: the drive,
// the tunnel and the Keystore all need a phone. Stubbing the four channels
// they talk to is enough to prove that both tabs build, lay out at phone
// size without overflowing, and show what they are supposed to show.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:pocketshare/main.dart' show appTheme;
import 'package:pocketshare/state/drive_controller.dart';
import 'package:pocketshare/tunnel/cloudflared.dart';
import 'package:pocketshare/tunnel/provision.dart';
import 'package:pocketshare/ui/drive_tab.dart';
import 'package:pocketshare/files/listing.dart';
import 'package:pocketshare/ui/files_tab.dart';
import 'package:pocketshare/ui/home_screen.dart';

late Directory root;
final List<MethodCall> nativeCalls = [];

void stubChannels(TestWidgetsFlutterBinding binding) {
  void stub(String name, Object? Function(MethodCall) handler) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      (call) async => handler(call),
    );
  }

  stub('pocketshare/native', (call) {
    nativeCalls.add(call);
    return switch (call.method) {
      'isIgnoringBatteryOptimizations' => true,
      'hasAllFilesAccess' => true,
      'hasAutostartSettings' => false,
      'storageVolumes' => [
          {
            'path': root.path,
            'removable': false,
            'totalBytes': 64 * 1024 * 1024 * 1024,
            'freeBytes': 12 * 1024 * 1024 * 1024,
          },
        ],
      'shareText' || 'openFolder' || 'openFile' => true,
      _ => null,
    };
  });

  stub('plugins.it_nomads.com/flutter_secure_storage', (call) => null);
  stub('plugins.flutter.io/path_provider', (_) => root.path);
}

/// A controller with the fields the running screens read, without touching
/// init() — which opens SQLite and starts a foreground service.
DriveController controllerAt(
  Directory drive, {
  bool live = true,
  bool host = false,
}) {
  final c = DriveController(provisionEndpoint: 'https://example.invalid');
  c.claim = const Claim(
    hostname: 'text.example.com',
    tunnelToken: 'not-a-real-token',
    reused: true,
  );
  c.driveRootPath = drive.path;
  c.tunnelState = live ? TunnelState.live : TunnelState.stopped;
  c.isHost = host;
  c.stage = SetupStage.ready;
  return c;
}

Widget wrap(Widget child) => MaterialApp(
      theme: appTheme(Brightness.light),
      home: child,
    );

/// Reads a directory synchronously, so the Files tab has something to draw.
///
/// A widget test runs on a fake clock, and the real async file I/O behind
/// `Listing.read` never completes under it — the screen would sit on its
/// spinner forever. Listing is covered against real directories in
/// tool/smoke_files.dart; what is being checked here is the screen.
Future<List<Entry>> readSync(Directory dir) async {
  final entries = <Entry>[];
  for (final entity in dir.listSync(followLinks: false)) {
    final stat = entity.statSync();
    final isDir = stat.type == FileSystemEntityType.directory;
    entries.add(Entry(
      path: entity.path,
      isDirectory: isDir,
      size: isDir
          ? (entity as Directory).listSync(followLinks: false).length
          : stat.size,
      modified: stat.modified,
    ));
  }
  return Listing.sort(entries);
}

/// One frame for the state change, one for the rebuilt list. Not
/// `pumpAndSettle`: the loading spinner animates forever, so settling never
/// happens while one is on screen.
Future<void> settleIO(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // Everything that touches the disk does so synchronously, or in setUp and
  // tearDown. A testWidgets body runs on a fake clock, and an awaited async
  // file operation inside one never completes: the test hangs with no error.
  setUp(() {
    nativeCalls.clear();
    root = Directory.systemTemp.createTempSync('ps-ui-');
    stubChannels(binding);
  });

  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('the drive tab leads with the address and its state',
      (tester) async {
    final c = controllerAt(root);
    await tester.pumpWidget(wrap(DriveTab(controller: c)));
    await tester.pumpAndSettle();

    expect(find.text('text.example.com'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Stop the drive'), findsOneWidget);
  });

  testWidgets('sharing sends the address and nothing else', (tester) async {
    final c = controllerAt(root);
    await tester.pumpWidget(wrap(DriveTab(controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();

    final shared = nativeCalls.firstWhere((call) => call.method == 'shareText');
    final text = (shared.arguments as Map)['text'] as String;
    expect(text, contains('text.example.com'));
    // The login is handed over separately on purpose: forwarding the message
    // must not forward the way in.
    expect(text.toLowerCase(), isNot(contains('password')));
    expect(text, isNot(contains('not-a-real-token')));
  });

  testWidgets('a stopped drive offers to start it', (tester) async {
    final c = controllerAt(root, live: false);
    await tester.pumpWidget(wrap(DriveTab(controller: c)));
    await tester.pumpAndSettle();

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('Start the drive'), findsOneWidget);
  });

  testWidgets('the invite card is host-only', (tester) async {
    await tester.pumpWidget(wrap(DriveTab(controller: controllerAt(root))));
    await tester.pumpAndSettle();
    expect(find.text('INVITE'), findsNothing);

    await tester.pumpWidget(
      wrap(DriveTab(controller: controllerAt(root, host: true))),
    );
    await tester.pumpAndSettle();
    expect(find.text('INVITE'), findsOneWidget);
  });

  testWidgets('the files tab lists the drive folder', (tester) async {
    File(p.join(root.path, 'holiday.jpg')).writeAsStringSync('x' * 2048);
    Directory(p.join(root.path, 'Documents')).createSync();

    final c = controllerAt(root);
    await tester.pumpWidget(wrap(
      Scaffold(body: FilesTab(controller: c, active: true, read: readSync)),
    ));
    await settleIO(tester);

    expect(find.text('Your drive folder'), findsOneWidget);
    expect(find.text(root.path), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('holiday.jpg'), findsOneWidget);
    expect(find.text('Open in Files'), findsOneWidget);
  });

  testWidgets('tapping a folder goes into it and back comes out',
      (tester) async {
    final sub = Directory(p.join(root.path, 'Trip'))..createSync();
    File(p.join(sub.path, 'ticket.pdf')).writeAsStringSync('pdf');

    final c = controllerAt(root);
    await tester.pumpWidget(wrap(
      Scaffold(body: FilesTab(controller: c, active: true, read: readSync)),
    ));
    await settleIO(tester);

    await tester.tap(find.text('Trip'));
    await settleIO(tester);
    expect(find.text('ticket.pdf'), findsOneWidget);

    await tester.tap(find.byTooltip('Up one level'));
    await settleIO(tester);
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('ticket.pdf'), findsNothing);
  });

  testWidgets('an empty drive folder says so rather than showing nothing',
      (tester) async {
    final c = controllerAt(root);
    await tester.pumpWidget(wrap(
      Scaffold(body: FilesTab(controller: c, active: true, read: readSync)),
    ));
    await settleIO(tester);

    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('both tabs are reachable from the home screen', (tester) async {
    await tester.pumpWidget(wrap(HomeScreen(controller: controllerAt(root), read: readSync)));
    await settleIO(tester);

    expect(find.text('PocketShare'), findsOneWidget);
    await tester.tap(find.text('Files'));
    await settleIO(tester);

    expect(find.text('Your files'), findsOneWidget);
    expect(find.text('Your drive folder'), findsOneWidget);
  });
}
