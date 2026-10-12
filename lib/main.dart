import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'home_screen.dart';

void main() {
  runApp(const ToolRescApp());
}

class ToolRescApp extends StatelessWidget {
  const ToolRescApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'tool-resc',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      home: const HomeScreen(),
    );
  }
}
