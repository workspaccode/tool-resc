import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/settings.dart';
import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/icon_tile.dart';

void showSettingsSheet(BuildContext context) {
  showCupertinoSheet<void>(
    context: context,
    scrollableBuilder: (context, controller) => _SettingsSheet(scrollController: controller),
  );
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final blue = context.resolve(CupertinoColors.systemBlue);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        middle: const Text('Settings'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
      child: ListView(
        controller: scrollController,
        children: [
          Section(
            header: 'APPEARANCE',
            children: [
              for (final option in Appearance.values)
                CupertinoListTile(
                  leading: IconTile(
                    icon: switch (option) {
                      Appearance.system => CupertinoIcons.circle_lefthalf_fill,
                      Appearance.light => CupertinoIcons.sun_max_fill,
                      Appearance.dark => CupertinoIcons.moon_fill,
                    },
                    color: switch (option) {
                      Appearance.system => CupertinoColors.systemGrey,
                      Appearance.light => CupertinoColors.systemOrange,
                      Appearance.dark => CupertinoColors.systemIndigo,
                    },
                  ),
                  title: Text(option.label),
                  trailing: option == appearance ? Icon(CupertinoIcons.checkmark_alt, color: blue) : null,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(appearanceProvider.notifier).set(option);
                  },
                ),
            ],
          ),
          Section(
            header: 'ABOUT',
            footer: 'All data is stored only on this device and is not included in backups.',
            children: const [CupertinoListTile(title: Text('Version'), additionalInfo: Text('1.0.0'))],
          ),
        ],
      ),
    );
  }
}
