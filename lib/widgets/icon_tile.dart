import 'package:flutter/cupertino.dart';

import '../app/theme.dart';

/// Rounded-square colored icon, as in iOS Settings rows.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color, this.size = 30});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(size * 0.23)),
        color: context.resolve(color),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, size: size * 0.62, color: CupertinoColors.white),
      ),
    );
  }
}
