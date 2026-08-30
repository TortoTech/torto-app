import 'dart:async';

import 'package:flutter/material.dart';

import '../library/library_page.dart';
import '../library/library_store.dart';
import '../profile/profile_page.dart';
import '../progress_store.dart';
import '../sync/cloud_sync_controller.dart';
import '../../l10n/app_localizations.dart';

class HomePage extends StatefulWidget {
  final Widget? library;

  const HomePage({super.key, this.library});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  final LibraryStore _libraryStore = LibraryStore();
  final ProgressStore _progressStore = ProgressStore();
  CloudSyncController? _cloudSync;
  bool _servicesReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.library == null) {
      unawaited(_initializeServices());
    } else {
      _servicesReady = true;
    }
  }

  Future<void> _initializeServices() async {
    CloudSyncController? cloud;
    try {
      cloud = await CloudSyncController.create(
        libraryStore: _libraryStore,
        progressStore: _progressStore,
      );
    } catch (_) {
      // Local reading remains available even when secure storage or the sync
      // database is temporarily unavailable.
    }
    if (!mounted) {
      cloud?.dispose();
      return;
    }
    setState(() {
      _cloudSync = cloud;
      _servicesReady = true;
    });
  }

  @override
  void dispose() {
    _cloudSync?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final library =
        widget.library ??
        (_servicesReady
            ? LibraryPage(
                store: _libraryStore,
                progressStore: _progressStore,
                cloudSyncController: _cloudSync,
                initializeCloudSync: false,
              )
            : const Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          library,
          ProfilePage(cloudSyncController: _cloudSync),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.library_books_outlined),
            selectedIcon: const Icon(Icons.library_books),
            label: l10n.text('书架', 'Library'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: l10n.text('我', 'Me'),
          ),
        ],
      ),
    );
  }
}
