import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import 'storage.dart';

enum Appearance {
  system('Automatic'),
  light('Light'),
  dark('Dark');

  const Appearance(this.label);

  final String label;

  Brightness? get brightness => switch (this) {
    Appearance.system => null,
    Appearance.light => Brightness.light,
    Appearance.dark => Brightness.dark,
  };
}

class AppearanceNotifier extends Notifier<Appearance> {
  static const _key = 'appearance';

  Box<Object> get _box => Hive.box<Object>(Boxes.settings);

  @override
  Appearance build() => Appearance.values.asNameMap()[_box.get(_key)] ?? Appearance.system;

  void set(Appearance value) {
    _box.put(_key, value.name);
    state = value;
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);
