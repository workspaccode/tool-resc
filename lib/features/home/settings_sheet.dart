import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../app/settings.dart';
import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/adaptive_sheet.dart';
import '../../widgets/icon_tile.dart';

void showSettingsSheet(BuildContext context) {
  showAdaptiveSheet<void>(context, builder: (context, controller) => _SettingsSheet(scrollController: controller));
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final scanMethod = ref.watch(scanMethodProvider);
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
          if (isDesktop)
            const Section(
              header: 'Scanner',
              footer:
                  'Connect a USB or Bluetooth barcode scanner in keyboard (HID) mode, set to send Enter after '
                  'each scan. In Components, scan anywhere. You don’t need to click the search field first, '
                  'and scans read correctly with any keyboard layout, including Arabic.',
              children: [
                CupertinoListTile(
                  leading: IconTile(icon: CupertinoIcons.barcode, color: CupertinoColors.systemGreen),
                  title: Text('USB Scanner'),
                  additionalInfo: Text('Keyboard mode'),
                ),
              ],
            )
          else
            Section(
              header: 'Scanning',
              footer: '${scanMethod.description} You can also switch in the camera.',
              children: [
                for (final option in ScanMethod.values)
                  CupertinoListTile(
                    leading: IconTile(
                      icon: option == ScanMethod.text ? CupertinoIcons.textformat : CupertinoIcons.qrcode,
                      color: option == ScanMethod.text ? CupertinoColors.systemTeal : CupertinoColors.systemPurple,
                    ),
                    title: Text(option.label),
                    trailing: option == scanMethod ? Icon(CupertinoIcons.checkmark_alt, color: blue) : null,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      ref.read(scanMethodProvider.notifier).set(option);
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
