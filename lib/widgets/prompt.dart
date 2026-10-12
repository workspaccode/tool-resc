import 'package:flutter/cupertino.dart';

/// An alert with a text field (e.g. "Rename List"). Completes with the
/// entered text, or null if cancelled.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String initialValue,
  required String confirmLabel,
  String? message,
}) {
  final controller = TextEditingController(text: initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initialValue.length);
  return showCupertinoDialog<String>(
    context: context,
    builder: (dialog) {
      void submit() => Navigator.pop(dialog, controller.text.trim().isEmpty ? null : controller.text.trim());
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          children: [
            if (message != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(message)),
            CupertinoTextField(controller: controller, autofocus: true, onSubmitted: (_) => submit()),
          ],
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: submit, child: Text(confirmLabel)),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}
