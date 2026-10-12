import 'package:flutter/cupertino.dart';

import '../app/theme.dart';

/// Inset grouped list section with iOS Settings-style header and footer:
/// small uppercase gray header, small gray footer.
class Section extends StatelessWidget {
  const Section({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final style = AppText.footnote.copyWith(
      color: context.resolve(CupertinoColors.secondaryLabel),
      fontWeight: FontWeight.w400,
    );
    return CupertinoListSection.insetGrouped(
      header: header == null ? null : Text(header!.toUpperCase(), style: style),
      footer: footer == null ? null : Text(footer!, style: style),
      children: children,
    );
  }
}
