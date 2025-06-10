// -----------------------------------------------------------------------------
// Immich Mobile App
// Copyright © 2025 Immich Contributors
// Licensed under MIT (https://github.com/immich-app/immich/blob/master/LICENSE)
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert'; // ← this gives you utf8
import 'dart:io';

import 'package:immich_mobile/services/api.service.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/share_intent_upload.provider.dart';
import 'package:immich_mobile/providers/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/background.service.dart';
import 'package:immich_mobile/services/local_notification.service.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/cache/widgets_binding.dart';
import 'package:immich_mobile/utils/download.dart';
import 'package:immich_mobile/utils/http_ssl_options.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest.dart';
import 'package:worker_manager/worker_manager.dart';
import 'immich_discovery_port.dart';

String? discoveredServerEndpoint;

/// Listens for “IMMICH_IP:<ip>” on UDP port 42424 for up to 5s.
Future<String?> discoverImmichServer() async {
  final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, ImmichDiscoveryConfig.port);
  socket.broadcastEnabled = true;
  String? found;

  // 1) Listen for incoming packets
  final sub = socket.listen((event) {
    if (event == RawSocketEvent.read) {
      final dg = socket.receive(); // no await here!
      if (dg != null) {
        final msg = utf8.decode(dg.data);
        if (msg.startsWith('IMMICH_IP:')) {
          found = msg.split(':').last.trim();
        }
      }
    }
  });

  // 2) Wait either for found != null or for timeout
  final stop = DateTime.now().add(const Duration(seconds: 10));
  while (found == null && DateTime.now().isBefore(stop)) {
    await Future.delayed(const Duration(milliseconds: 100));
  }

  // 3) Clean up
  await sub.cancel();
  socket.close();

  return found;
}

void main() async {
  final ip = await discoverImmichServer();
  if (ip != null) {
    discoveredServerEndpoint = 'http://$ip:2283/api';
    ApiService().setEndpoint(discoveredServerEndpoint!);
    print('IP - http://$ip:2283/api');
  }
  ImmichWidgetsBinding();
  final db = await Bootstrap.initIsar();
  await Bootstrap.initDomain(db);
  await initApp();
  await workerManager.init(dynamicSpawning: true);
  await migrateDatabaseIfNeeded(db);
  HttpSSLOptions.apply();
  runApp(
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        isarProvider.overrideWithValue(db)
      ],
      child: const MainWidget(),
    ),
  );
}

Future<void> initApp() async {
  await EasyLocalization.ensureInitialized();
  await initializeDateFormatting();

  if (kReleaseMode && Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      debugPrint("Enabled high refresh mode");
    } catch (e) {
      debugPrint("Error setting high refresh rate: $e");
    }
  }

  await DynamicTheme.fetchSystemPalette();

  final log = Logger("ImmichErrorLogger");

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.severe(
      'FlutterError - Catch all',
      "${details.toString()}\nException: ${details.exception}\nLibrary: ${details.library}\nContext: ${details.context}",
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint("FlutterError - Catch all: $error \n $stack");
    log.severe('PlatformDispatcher - Catch all', error, stack);
    return true;
  };

  initializeTimeZones();

  await FileDownloader().trackTasksInGroup(
    downloadGroupLivePhoto,
    markDownloadedComplete: false,
  );

  await FileDownloader().trackTasks();
}

class MainWidget extends StatelessWidget {
  const MainWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      useFallbackTranslations: true,
      fallbackLocale: locales.values.first,
      assetLoader: const CodegenLoader(),
      child: const ImmichApp(),
    );
  }
}

class ImmichApp extends ConsumerStatefulWidget {
  const ImmichApp({super.key});

  @override
  ImmichAppState createState() => ImmichAppState();
}

class ImmichAppState extends ConsumerState<ImmichApp>
    with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        debugPrint("[APP STATE] resumed");
        ref.read(appStateProvider.notifier).handleAppResume();
        break;
      case AppLifecycleState.inactive:
        debugPrint("[APP STATE] inactive");
        ref.read(appStateProvider.notifier).handleAppInactivity();
        break;
      case AppLifecycleState.paused:
        debugPrint("[APP STATE] paused");
        ref.read(appStateProvider.notifier).handleAppPause();
        break;
      case AppLifecycleState.detached:
        debugPrint("[APP STATE] detached");
        ref.read(appStateProvider.notifier).handleAppDetached();
        break;
      case AppLifecycleState.hidden:
        debugPrint("[APP STATE] hidden");
        ref.read(appStateProvider.notifier).handleAppHidden();
        break;
    }
  }

  Future<void> initApp() async {
    WidgetsBinding.instance.addObserver(this);

    // Draw the app from edge to edge
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Sets the navigation bar color
    SystemUiOverlayStyle overlayStyle = const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
    );
    if (Platform.isAndroid) {
      // Android 8 does not support transparent app bars
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt <= 26) {
        overlayStyle = context.isDarkTheme
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light;
      }
    }
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
    await ref.read(localNotificationService).setup();
  }

  void _configureFileDownloaderNotifications() {
    FileDownloader().configureNotification(
      running: TaskNotification(
        'downloading_media'.tr(),
        '${'file_name'.tr()}: {filename}',
      ),
      complete: TaskNotification(
        'download_finished'.tr(),
        '${'file_name'.tr()}: {filename}',
      ),
      progressBar: true,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Intl.defaultLocale = context.locale.toLanguageTag();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureFileDownloaderNotifications();
    });
  }

  @override
  initState() {
    super.initState();
    initApp().then((_) => debugPrint("App Init Completed"));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // needs to be delayed so that EasyLocalization is working
      ref.read(backgroundServiceProvider).resumeServiceIfEnabled();
    });

    ref.read(shareIntentUploadProvider.notifier).init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final immichTheme = ref.watch(immichThemeProvider);
    return ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(context.locale),
      ],
      child: MaterialApp.router(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        debugShowCheckedModeBanner: true,
        themeMode: ref.watch(immichThemeModeProvider),
        darkTheme: getThemeData(
          colorScheme: immichTheme.dark,
          locale: context.locale,
        ),
        theme: getThemeData(
          colorScheme: immichTheme.light,
          locale: context.locale,
        ),
        routeInformationParser: router.defaultRouteParser(),
        routerDelegate: router.delegate(
          navigatorObservers: () => [AppNavigationObserver(ref: ref)],
        ),
      ),
    );
  }
}
