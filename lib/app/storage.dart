import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Hive box names.
abstract final class Boxes {
  static const settings = 'settings';

  /// Component field definitions (imported Excel headers).
  static const componentsMeta = 'components_meta';

  /// Components keyed by normalized MPN; values are `Map<String, String>`
  /// of field label -> cell value. Lazy so only keys stay in memory.
  static const components = 'components';
}

Future<void> initStorage() async {
  await Hive.initFlutter();
  await Future.wait([
    Hive.openBox<Object>(Boxes.settings),
    Hive.openBox<Object>(Boxes.componentsMeta),
    Hive.openLazyBox<Map>(Boxes.components),
  ]);
}
