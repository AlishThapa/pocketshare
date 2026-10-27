import 'package:flutter/material.dart';

import 'state/drive_controller.dart';
import 'ui/claim_screen.dart';
import 'ui/login_screen.dart';
import 'ui/running_screen.dart';

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
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3B5BDB));

    return MaterialApp(
      title: 'PocketShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B5BDB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => switch (_controller.stage) {
          SetupStage.loading => const _Splash(),
          SetupStage.claimName => ClaimScreen(controller: _controller),
          SetupStage.createLogin => LoginSetupScreen(controller: _controller),
          SetupStage.ready => RunningScreen(controller: _controller),
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
