import 'package:flutter/material.dart';

import 'features/components/components_screen.dart';

class Tool {
  const Tool({required this.title, required this.description, required this.icon, required this.builder});

  final String title;
  final String description;
  final IconData icon;
  final WidgetBuilder builder;
}

/// Available tools. New features are added here.
final tools = <Tool>[
  Tool(
    title: 'المكونات',
    description: 'البحث عن المكونات برقم MPN أو بمسح الملصق',
    icon: Icons.memory,
    builder: (_) => const ComponentsScreen(),
  ),
];

/// Lets the user choose the current tool.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('اختر الأداة')),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.95,
        ),
        itemCount: tools.length,
        itemBuilder: (context, i) => _ToolCard(tool: tools[i]),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool});

  final Tool tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: tool.builder)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(tool.icon, size: 32, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(height: 12),
              Text(tool.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                tool.description,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
