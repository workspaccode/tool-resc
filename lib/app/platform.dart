import 'package:flutter/foundation.dart';

/// macOS, Windows or Linux: no camera scanning; a USB scanner is used instead.
bool get isDesktop => switch (defaultTargetPlatform) {
  TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
  _ => false,
};

/// Width from which screens use a sidebar / split layout.
const double kWideLayout = 840;

/// macOS uses ⌘ for shortcuts; other platforms use Ctrl.
bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;
