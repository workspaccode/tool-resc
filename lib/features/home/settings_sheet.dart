import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../app/settings.dart';
import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/adaptive_sheet.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/prompt.dart';

void showSettingsSheet(BuildContext context) {
  showAdaptiveSheet<void>(context, builder: (context, controller) => _SettingsSheet(scrollController: controller));
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final prefs = ref.watch(searchPrefsProvider);
    final prefsNotifier = ref.read(searchPrefsProvider.notifier);
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
            const Section(
              header: 'Scanner',
              footer: 'Tap Scan Label in Components and point the camera at the QR code on the label.',
              children: [
                CupertinoListTile(
                  leading: IconTile(icon: CupertinoIcons.qrcode, color: CupertinoColors.systemPurple),
                  title: Text('Camera'),
                  additionalInfo: Text('QR code'),
                ),
              ],
            ),
          Section(
            header: 'Search',
            footer: prefs.searchOnScan
                ? 'A scan is searched right away, and a single match opens.'
                : 'A scan only fills the search field. Press Enter to search.',
            children: [
              _SwitchRow(
                icon: CupertinoIcons.keyboard,
                color: CupertinoColors.systemBlue,
                title: 'Search While Typing',
                value: prefs.searchWhileTyping,
                onChanged: (v) => prefsNotifier.update((p) => p.copyWith(searchWhileTyping: v)),
              ),
              _SwitchRow(
                icon: CupertinoIcons.qrcode_viewfinder,
                color: CupertinoColors.systemGreen,
                title: 'Search After Scan',
                value: prefs.searchOnScan,
                onChanged: (v) => prefsNotifier.update((p) => p.copyWith(searchOnScan: v)),
              ),
            ],
          ),
          Section(
            header: 'Read scanned code',
            footer: switch (prefs.codeReading) {
              CodeReading.auto =>
                'Recognizes LCSC QR codes and DigiKey/Mouser DataMatrix labels. Any other code is searched as it is.',
              CodeReading.whole => 'The whole scanned code is searched as it is.',
              CodeReading.field =>
                'Searches the value of “${prefs.codeField}” in codes like {${prefs.codeField}:ABC123,qty:5} or '
                    '${prefs.codeField}=ABC123;LOT=7. If a code doesn’t have it, the whole code is used. '
                    'Tap the row to change the field name.',
            },
            children: [
              for (final option in CodeReading.values)
                CupertinoListTile(
                  title: Text(option.label),
                  additionalInfo: option == CodeReading.field ? Text(prefs.codeField) : null,
                  trailing: option == prefs.codeReading ? Icon(CupertinoIcons.checkmark_alt, color: blue) : null,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    if (option == CodeReading.field) {
                      final name = await showTextPrompt(
                        context,
                        title: 'Field in Code',
                        message: 'The name before the value in your codes, e.g. pm in {pm:ABC123,qty:5}.',
                        initialValue: prefs.codeField,
                        confirmLabel: 'Use',
                      );
                      if (name == null) return;
                      prefsNotifier.update((p) => p.copyWith(codeReading: option, codeField: name));
                    } else {
                      prefsNotifier.update((p) => p.copyWith(codeReading: option));
                    }
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

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: IconTile(icon: icon, color: color),
      title: Text(title),
      trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}
