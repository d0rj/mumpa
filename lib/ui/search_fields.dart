import 'package:flutter/material.dart';

import '../logic/app_controller.dart';

/// A dismissed search must not become the focus scope's remembered fallback
/// after a menu, dialog or player sheet closes. Explicit input re-arms it.
class SearchFocusNode extends FocusNode {
  SearchFocusNode({super.debugLabel}) : super(skipTraversal: true) {
    addListener(_focusChanged);
  }
  bool _armed = true;

  // TextField refreshes this property when its widget is rebuilt. That must
  // not undo a dismissal and make the scope restore this search again.
  @override
  set canRequestFocus(bool value) => super.canRequestFocus = value && _armed;

  void _focusChanged() {
    if (!hasFocus) {
      _armed = false;
      super.canRequestFocus = false;
    }
  }

  void activate() {
    _armed = true;
    canRequestFocus = true;
    requestFocus();
  }

  void dismiss() {
    _armed = false;
    unfocus();
    canRequestFocus = false;
  }

  @override
  void dispose() {
    removeListener(_focusChanged);
    super.dispose();
  }
}

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
  final _focus = SearchFocusNode(debugLabel: 'local-search');

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
      onTap: _focus.activate,
      onTapAlwaysCalled: true,
      onTapOutside: (_) => _focus.dismiss(),
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _focus.dismiss(),
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
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    ),
  );
}
