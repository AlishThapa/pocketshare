import 'package:flutter/material.dart';

import '../files/listing.dart';
import '../state/drive_controller.dart';
import 'drive_tab.dart';
import 'files_tab.dart';

/// The app once setup is done: two tabs, and nothing else.
///
/// One screen used to hold the status, the address, the storage location, the
/// permission chores, the invites and the login. Splitting it in two puts the
/// question each tab answers in its name: "is my drive up, and what is its
/// address" in one, "what is actually in it" in the other.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.read});

  final DriveController controller;

  /// Only set by widget tests; see [DirectoryReader].
  final DirectoryReader? read;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _tab == 0 ? 'PocketShare' : 'Your files',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (_tab == 1 && c.hostname.isNotEmpty)
              Text(
                c.hostname,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            DriveTab(controller: c),
            FilesTab(
              controller: c,
              active: _tab == 1,
              read: widget.read ?? Listing.read,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'Drive',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
        ],
      ),
    );
  }
}
