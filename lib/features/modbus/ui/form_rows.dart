import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';

/// Label on the left, editable text on the right, like iOS Settings.
class TextRow extends StatefulWidget {
  const TextRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.placeholder,
    this.numeric = false,
    this.signed = false,
    this.enabled = true,
    this.monospace = false,
    this.width = 170,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? placeholder;
  final bool numeric;
  final bool signed;
  final bool enabled;
  final bool monospace;
  final double width;

  @override
  State<TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<TextRow> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(TextRow old) {
    super.didUpdateWidget(old);
    // Follow outside changes, but never while the user is typing.
    if (!_focus.hasFocus && widget.value != _controller.text) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: Text(widget.label),
      trailing: SizedBox(
        width: widget.width,
        child: CupertinoTextField.borderless(
          controller: _controller,
          focusNode: _focus,
          enabled: widget.enabled,
          placeholder: widget.placeholder,
          textAlign: TextAlign.end,
          padding: EdgeInsets.zero,
          style: TextStyle(
            color: context.resolve(widget.enabled ? CupertinoColors.label : CupertinoColors.tertiaryLabel),
            fontFeatures: const [FontFeature.tabularFigures()],
            fontFamily: widget.monospace ? 'monospace' : null,
          ),
          keyboardType: widget.numeric ? TextInputType.numberWithOptions(signed: widget.signed) : TextInputType.url,
          inputFormatters: widget.numeric
              ? [FilteringTextInputFormatter.allow(RegExp(widget.signed ? r'^-?\d*' : r'\d*'))]
              : null,
          autocorrect: false,
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}

/// A row that opens a choice list (action sheet).
class PickerRow<T> extends StatelessWidget {
  const PickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: Text(label),
      additionalInfo: Text(labelOf(value)),
      trailing: const CupertinoListTileChevron(),
      onTap: enabled ? () => _pick(context) : null,
    );
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await pickOption<T>(context, title: label, options: options, labelOf: labelOf, current: value);
    if (picked != null) onChanged(picked);
  }
}

/// An action sheet of [options]; null if cancelled.
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required String Function(T) labelOf,
  T? current,
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
      title: Text(title),
      actions: [
        for (final o in options)
          CupertinoActionSheetAction(
            isDefaultAction: o == current,
            onPressed: () => Navigator.pop(sheet, o),
            child: Text(labelOf(o)),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
    ),
  );
}

void showAlert(BuildContext context, String title, String message) {
  showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
      ],
    ),
  );
}

/// Navigation bar for the editor sheets: Cancel · title · action.
CupertinoNavigationBar sheetBar(
  BuildContext context, {
  required String title,
  String action = 'Done',
  VoidCallback? onAction,
  bool busy = false,
}) => CupertinoNavigationBar(
  automaticallyImplyLeading: false,
  leading: CupertinoButton(
    padding: EdgeInsets.zero,
    onPressed: () => Navigator.of(context).pop(),
    child: const Text('Cancel'),
  ),
  middle: Text(title),
  trailing: busy
      ? const CupertinoActivityIndicator()
      : CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onAction,
          child: Text(action, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
);

const monoStyle = TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()]);
