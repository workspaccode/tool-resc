import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/settings.dart';
import 'app/storage.dart';
import 'app/theme.dart';
import 'features/home/home_screen.dart';
import 'features/sync/device_identity.dart';
import 'features/sync/sync_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(systemNavigationBarColor: Color(0x00000000), systemNavigationBarContrastEnforced: false),
  );
  await initStorage();
  await ensureDeviceIdentity();
  runApp(const ProviderScope(child: ToolRescApp()));
}

class ToolRescApp extends ConsumerWidget {
  const ToolRescApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    // Keeps optional server sync alive, so queued items send after launch.
    ref.listen(syncProvider, (_, _) {});
    return CupertinoApp(
      title: 'ToolsResc',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(appearance.brightness),
      // Material localizations back the text selection toolbar on Android.
      localizationsDelegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultCupertinoLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      home: const HomeScreen(),
    );
  }
}
