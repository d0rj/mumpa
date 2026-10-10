import 'package:flutter/material.dart';

import '../logic/app_controller.dart';

/// An in-memory section filter, independent of the global catalogue query.
class LocalSearchField extends StatefulWidget {
  const LocalSearchField({
    super.key,
    required this.app,
    required this.scope,
    required this.hint,
  });
  final AppController app;
  final String scope, hint;

  @override
  State<LocalSearchField> createState() => _LocalSearchFieldState();
}

class _LocalSearchFieldState extends State<LocalSearchField> {
  late final _query = TextEditingController(
    text: widget.app.localQuery(widget.scope),
  );
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant LocalSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.app.localQuery(widget.scope);
    if (_query.text == text) return;
    _query.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: TextField(
      key: ValueKey('local-search-${widget.scope}'),
      controller: _query,
      focusNode: _focus,
      textInputAction: TextInputAction.search,
      onChanged: (value) => widget.app.setLocalQuery(widget.scope, value),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: widget.hint,
        suffixIcon: _query.text.isEmpty
            ? null
            : IconButton(
                key: ValueKey('local-search-${widget.scope}-clear'),
                tooltip: 'Очистить поиск в разделе',
                onPressed: () {
                  widget.app.setLocalQuery(widget.scope, '');
                  _focus.requestFocus();
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    ),
  );
}
