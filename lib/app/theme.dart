import 'package:flutter/cupertino.dart';

/// iOS Human Interface Guidelines text styles. They inherit the font family
/// from the Cupertino theme (SF Pro on Apple devices).
abstract final class AppText {
  static const largeTitle = TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: 0.37);
  static const title1 = TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 0.36);
  static const title2 = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.35);
  static const title3 = TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 0.38);
  static const headline = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.43);
  static const body = TextStyle(fontSize: 17, letterSpacing: -0.43);
  static const callout = TextStyle(fontSize: 16, letterSpacing: -0.31);
  static const subheadline = TextStyle(fontSize: 15, letterSpacing: -0.23);
  static const footnote = TextStyle(fontSize: 13, letterSpacing: -0.08);
  static const caption = TextStyle(fontSize: 12);

  /// Part numbers: tabular digits so similar MPNs line up.
  static const mpn = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]);
}

CupertinoThemeData buildTheme(Brightness? brightness) => CupertinoThemeData(
  brightness: brightness,
  primaryColor: CupertinoColors.systemBlue,
  scaffoldBackgroundColor: CupertinoColors.systemGroupedBackground,
);

extension DynamicColorX on BuildContext {
  /// Resolves an Apple system color for the current light/dark mode.
  /// Needed wherever a color isn't passed to a Cupertino widget directly.
  Color resolve(Color color) => CupertinoDynamicColor.resolve(color, this);

  bool get isDark => CupertinoTheme.brightnessOf(this) == Brightness.dark;
}
