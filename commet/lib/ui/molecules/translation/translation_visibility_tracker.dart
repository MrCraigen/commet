import 'dart:async';

import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Determines which translatable messages are actually visible inside one
/// scrollable timeline, and reports them to the [TranslationService].
///
/// Only message bodies in rooms with automatic translation register here.
/// The computation runs once scrolling settles (debounced), so fast scrolling
/// through history never builds up a backlog of translation requests:
/// every report replaces the previous one and the scheduler drops queued
/// work for messages that scrolled away.
class TranslationVisibilityTracker {
  static final Expando<TranslationVisibilityTracker> _trackers = Expando();

  /// How long scrolling has to be idle before visibility is evaluated.
  static Duration settleDelay = const Duration(milliseconds: 350);

  final TranslationService service;
  final ScrollPosition position;
  final ScrollableState scrollable;
  final Map<MessageRef, BuildContext> _registered = {};
  Timer? _debounce;
  bool _listening = false;

  TranslationVisibilityTracker._(this.service, this.scrollable)
    : position = scrollable.position;

  static TranslationVisibilityTracker? of(
    BuildContext context,
    TranslationService service,
  ) {
    var scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return null;
    var position = scrollable.position;
    var tracker = _trackers[position];
    if (tracker == null || tracker.service != service) {
      tracker = TranslationVisibilityTracker._(service, scrollable);
      _trackers[position] = tracker;
    }
    return tracker;
  }

  void register(MessageRef ref, BuildContext context) {
    _registered[ref] = context;
    if (!_listening) {
      position.addListener(_onScroll);
      _listening = true;
    }
    _schedule();
  }

  void unregister(MessageRef ref, BuildContext context) {
    if (_registered[ref] != context) return;
    _registered.remove(ref);
    if (_registered.isEmpty) {
      _detach();
    } else {
      _schedule();
    }
  }

  void _detach() {
    _debounce?.cancel();
    _debounce = null;
    if (_listening) {
      position.removeListener(_onScroll);
      _listening = false;
    }
    service.removeVisibilityOwner(this);
  }

  void _onScroll() => _schedule();

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(settleDelay, _evaluate);
  }

  /// Force an immediate evaluation (tests / policy changes).
  void evaluateNow() {
    _debounce?.cancel();
    _evaluate();
  }

  void _evaluate() {
    _debounce = null;
    if (_registered.isEmpty) return;

    var viewportObject = scrollable.context.findRenderObject();
    if (viewportObject is! RenderBox ||
        !viewportObject.attached ||
        !viewportObject.hasSize ||
        _isOffstage(viewportObject)) {
      service.setVisible(this, const []);
      return;
    }

    var viewport =
        viewportObject.localToGlobal(Offset.zero) & viewportObject.size;
    var center = viewport.center.dy;

    var visible = <(MessageRef, double)>[];
    for (var entry in _registered.entries) {
      var context = entry.value;
      if (!context.mounted) continue;
      var object = context.findRenderObject();
      if (object is! RenderBox || !object.attached || !object.hasSize) {
        continue;
      }
      var rect = object.localToGlobal(Offset.zero) & object.size;
      var overlap = rect.intersect(viewport);
      if (overlap.height <= 0 || overlap.width <= 0) continue;
      visible.add((entry.key, (rect.center.dy - center).abs()));
    }

    // Closest to the middle of the viewport first: the user's reading
    // position.
    visible.sort((a, b) => a.$2.compareTo(b.$2));
    service.setVisible(this, visible.map((e) => e.$1).toList());
  }

  static bool _isOffstage(RenderObject object) {
    RenderObject? current = object;
    while (current != null) {
      if (current is RenderOffstage && current.offstage) return true;
      current = current.parent;
    }
    return false;
  }
}
