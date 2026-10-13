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

/// How a scanned code turns into the value that is searched for.
enum CodeReading {
  /// Recognize known label formats (LCSC QR, DigiKey/Mouser DataMatrix);
  /// otherwise use the whole code.
  auto('Auto-detect'),

  /// Search for the code exactly as scanned.
  whole('Whole code'),

  /// Take the value of a named field, e.g. `pm` in `{pm:ABC,qty:5}`.
  field('Field in code');

  const CodeReading(this.label);

  final String label;
}

/// Search and scan preferences; everything is optional and per device.
class SearchPrefs {
  const SearchPrefs({
    this.searchWhileTyping = true,
    this.searchOnScan = true,
    this.codeReading = CodeReading.auto,
    this.codeField = 'pm',
  });

  /// Update results on every keystroke; when off, search runs on Enter.
  final bool searchWhileTyping;

  /// Search (and open a single match) as soon as a code is scanned; when off,
  /// the value is only put in the search field.
  final bool searchOnScan;

  final CodeReading codeReading;

  /// The field name used with [CodeReading.field].
  final String codeField;

  SearchPrefs copyWith({bool? searchWhileTyping, bool? searchOnScan, CodeReading? codeReading, String? codeField}) =>
      SearchPrefs(
        searchWhileTyping: searchWhileTyping ?? this.searchWhileTyping,
        searchOnScan: searchOnScan ?? this.searchOnScan,
        codeReading: codeReading ?? this.codeReading,
        codeField: codeField ?? this.codeField,
      );
}

class SearchPrefsNotifier extends Notifier<SearchPrefs> {
  static const _key = 'searchPrefs';

  Box<Object> get _box => Hive.box<Object>(Boxes.settings);

  @override
  SearchPrefs build() {
    final m = (_box.get(_key) as Map?) ?? const {};
    const defaults = SearchPrefs();
    return SearchPrefs(
      searchWhileTyping: m['searchWhileTyping'] as bool? ?? defaults.searchWhileTyping,
      searchOnScan: m['searchOnScan'] as bool? ?? defaults.searchOnScan,
      codeReading: CodeReading.values.asNameMap()[m['codeReading']] ?? defaults.codeReading,
      codeField: m['codeField'] as String? ?? defaults.codeField,
    );
  }

  void update(SearchPrefs Function(SearchPrefs) change) {
    final next = change(state);
    _box.put(_key, {
      'searchWhileTyping': next.searchWhileTyping,
      'searchOnScan': next.searchOnScan,
      'codeReading': next.codeReading.name,
      'codeField': next.codeField,
    });
    state = next;
  }
}

final searchPrefsProvider = NotifierProvider<SearchPrefsNotifier, SearchPrefs>(SearchPrefsNotifier.new);
