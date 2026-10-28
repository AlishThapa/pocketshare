import 'package:flutter/material.dart';

import 'state/drive_controller.dart';
import 'ui/claim_screen.dart';
import 'ui/connect_cloudflare_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/start_screen.dart';

/// Worker base URL. The default is the deployed provisioning Worker; a fork
/// points at its own with:
///   flutter build apk --dart-define=PROVISION_ENDPOINT=https://...
const String provisionEndpoint = String.fromEnvironment(
  'PROVISION_ENDPOINT',
  defaultValue: 'https://provision.thapaalish.com.np',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PocketShareApp());
}


/// The seed every colour in the app comes from. One sober blue, because this
/// screen asks people to trust it with their files and a loud palette reads
/// as a different kind of app entirely.
const Color _seed = Color(0xFF3B5BDB);

/// Shared theme, defined once so both tabs and every setup screen agree.
///
/// Mostly a flattening pass: Material 3 tints and elevates surfaces by
/// default, which on a page made of stacked panels produces a gradient of
/// near-identical greys. Flat panels on a plain background separate by shape
/// and spacing instead.
ThemeData appTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      filled: true,
      fillColor: scheme.surfaceContainerLow,
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    // Floating, so it clears the navigation bar instead of sitting under it.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(shape: shape),
  );
}

class PocketShareApp extends StatefulWidget {
  const PocketShareApp({super.key});

  @override
  State<PocketShareApp> createState() => _PocketShareAppState();
}

class _PocketShareAppState extends State<PocketShareApp> {
  late final DriveController _controller;

  @override
  void initState() {
    super.initState();
    _controller = DriveController(provisionEndpoint: provisionEndpoint)..init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketShare',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => switch (_controller.stage) {
          SetupStage.loading => const _Splash(),
          SetupStage.choosePath => StartScreen(controller: _controller),
          SetupStage.claimName => ClaimScreen(controller: _controller),
          SetupStage.connectCloudflare =>
            ConnectCloudflareScreen(controller: _controller),
          SetupStage.createLogin => LoginSetupScreen(controller: _controller),
          SetupStage.ready => HomeScreen(controller: _controller),
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_queue_rounded, size: 44, color: scheme.primary),
            const SizedBox(height: 22),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                borderRadius: BorderRadius.circular(4),
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
