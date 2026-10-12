import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components_db.dart';

class ComponentDetailScreen extends StatelessWidget {
  const ComponentDetailScreen({super.key, required this.component});

  final Component component;

  @override
  Widget build(BuildContext context) {
    final entries = component.values.entries.where((e) => e.value.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(title: Text(component.mpn, textDirection: TextDirection.ltr)),
      body: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final e = entries[i];
          return ListTile(
            title: Text(e.key, style: Theme.of(context).textTheme.labelMedium),
            subtitle: SelectableText(e.value, style: Theme.of(context).textTheme.bodyLarge),
            trailing: IconButton(
              tooltip: 'نسخ',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: e.value));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text('تم نسخ ${e.key}')));
              },
            ),
          );
        },
      ),
    );
  }
}
