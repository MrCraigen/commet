import 'dart:async';

import 'package:commet/client/client.dart';
import 'package:commet/client/matrix/timeline_events/matrix_timeline_event_message.dart';
import 'package:commet/client/translation/matrix_translation_adapter.dart';
import 'package:commet/client/translation/translation.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/client/timeline_events/timeline_event.dart';
import 'package:commet/ui/molecules/translation/translation_strings.dart';
import 'package:commet/ui/molecules/translation/translation_ui.dart';
import 'package:commet/ui/molecules/translation/translation_visibility_tracker.dart';
import 'package:flutter/material.dart';

/// Wraps the rendered body of a message and, when a translation is
/// available, displays it in place of the original. The underlying Matrix
/// event is never modified; the original widget is kept and shown again on
/// "Show original".
///
/// The translation itself is rendered strictly as plain text (model output
/// is untrusted), with only links that already existed in the original made
/// clickable.
class TranslatedMessageBody extends StatefulWidget {
  const TranslatedMessageBody({
    super.key,
    required this.original,
    required this.room,
    required this.event,
    required this.timeline,
    required this.contentId,
  });

  final Widget original;
  final Room room;
  final TimelineEvent event;

  /// The timeline the event is displayed in (used to resolve edits).
  final Timeline? timeline;

  /// Changes whenever the displayed content of the event changes (edits).
  final String? contentId;

  /// Returns [original] wrapped for translation if the feature is active,
  /// otherwise [original] unchanged, so Commet behaves exactly as before
  /// when translation is disabled.
  static Widget? wrap({
    required Widget? original,
    required Room? room,
    required TimelineEvent event,
    required Timeline? timeline,
    required String? contentId,
  }) {
    if (original == null || room == null) return original;
    if (Translation.service == null) return original;
    if (event is! MatrixTimelineEventMessage) return original;
    return TranslatedMessageBody(
      key: ValueKey("translation-${event.eventId}"),
      original: original,
      room: room,
      event: event,
      timeline: timeline,
      contentId: contentId,
    );
  }

  @override
  State<TranslatedMessageBody> createState() => _TranslatedMessageBodyState();
}

class _TranslatedMessageBodyState extends State<TranslatedMessageBody> {
  late MessageRef ref;
  StreamSubscription? _policySub;
  TranslationVisibilityTracker? _tracker;
  bool _autoTranslate = false;

  TranslationService? get service => Translation.service;

  @override
  void initState() {
    super.initState();
    ref = MatrixTranslationAdapter.refFor(widget.room, widget.event);
    _policySub = service?.onPolicyChanged.listen((_) => _onPolicyChanged());
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTracker();
  }

  @override
  void didUpdateWidget(covariant TranslatedMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    var newRef = MatrixTranslationAdapter.refFor(widget.room, widget.event);
    if (newRef != ref) {
      _tracker?.unregister(ref, context);
      ref = newRef;
      _sync();
      _updateTracker();
    } else if (oldWidget.contentId != widget.contentId ||
        !identical(oldWidget.event, widget.event)) {
      _sync();
    }
  }

  @override
  void dispose() {
    _policySub?.cancel();
    _tracker?.unregister(ref, context);
    super.dispose();
  }

  void _onPolicyChanged() {
    if (!mounted) return;
    var service = this.service;
    var adapter = Translation.adapter;
    if (service == null || adapter == null) return;
    service.refresh(ref, adapter.contextFor(widget.room));
    _sync();
    _updateTracker();
    _tracker?.evaluateNow();
  }

  void _sync() {
    var service = this.service;
    var adapter = Translation.adapter;
    if (service == null || adapter == null) return;

    var context = adapter.contextFor(widget.room);
    _autoTranslate = service.isEnabled && context.policy.autoTranslate;

    var extraction = MatrixTranslationAdapter.extract(
      widget.event,
      timeline: widget.timeline,
      maxCodePoints: service.provider?.maxInputCodePoints ?? 500,
    );
    service.sync(ref, extraction, context);
  }

  void _updateTracker() {
    var service = this.service;
    if (service == null) return;

    if (_autoTranslate) {
      var tracker = TranslationVisibilityTracker.of(context, service);
      if (tracker != _tracker) {
        _tracker?.unregister(ref, context);
        _tracker = tracker;
      }
      _tracker?.register(ref, context);
    } else {
      _tracker?.unregister(ref, context);
      _tracker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    var service = this.service;
    if (service == null) return widget.original;

    return ValueListenableBuilder<MessageTranslationState>(
      valueListenable: service.watch(ref),
      builder: (context, state, _) => _buildForState(context, state),
    );
  }

  Widget _buildForState(BuildContext context, MessageTranslationState state) {
    if (!(service?.isEnabled ?? false)) return widget.original;

    Widget? footer;
    Widget body = widget.original;

    if (state.hasTranslation) {
      if (state.showOriginal) {
        footer = _TranslationFooter(
          icon: Icons.translate,
          label: null,
          action: TranslationStrings.promptTranslationShowTranslation,
          onAction: () => service!.setShowOriginal(ref, false),
        );
      } else {
        body = PlaintextMessageBody(
          content: state.translatedText!,
          clientIdentifier: widget.room.client.identifier,
        );
        footer = _TranslationFooter(
          icon: Icons.translate,
          label: state.detectedSource != null
              ? TranslationStrings.labelTranslatedFrom(
                  TranslationUi.languageName(state.detectedSource),
                )
              : TranslationStrings.labelTranslated,
          action: TranslationStrings.promptTranslationShowOriginal,
          onAction: () => service!.setShowOriginal(ref, true),
        );
      }
    } else if (state.manual) {
      // Feedback is only shown for explicit user requests; automatic
      // translation stays silent to avoid clutter and layout shifts.
      switch (state.status) {
        case MessageTranslationStatus.queued:
          footer = _TranslationFooter(
            icon: Icons.translate,
            label: TranslationStrings.labelTranslationQueued,
            busy: true,
          );
        case MessageTranslationStatus.inProgress:
          footer = _TranslationFooter(
            icon: Icons.translate,
            label: TranslationStrings.labelTranslationInProgress,
            busy: true,
          );
        case MessageTranslationStatus.failed:
          footer = _TranslationFooter(
            icon: Icons.error_outline,
            label: TranslationUi.errorText(state.error),
            isError: true,
            action: TranslationStrings.promptTranslationRetry,
            onAction: () => TranslationUi.translateManually(
              context,
              room: widget.room,
              ref: ref,
            ),
          );
        case MessageTranslationStatus.sameLanguage:
          footer = _TranslationFooter(
            icon: Icons.translate,
            label: TranslationStrings.labelTranslationAlreadyInLanguage(
              TranslationUi.languageName(state.targetLanguage),
            ),
          );
        default:
          break;
      }
    }

    if (footer == null) return body;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [body, footer],
    );
  }
}

class _TranslationFooter extends StatelessWidget {
  const _TranslationFooter({
    required this.icon,
    required this.label,
    this.action,
    this.onAction,
    this.busy = false,
    this.isError = false,
  });

  final IconData icon;
  final String? label;
  final String? action;
  final VoidCallback? onAction;
  final bool busy;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var color = isError ? scheme.error : scheme.onSurfaceVariant;
    var style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: color, fontSize: 12);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          if (busy)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          else
            Icon(icon, size: 13, color: color),
          if (label != null) Text(label!, style: style),
          if (label != null && action != null) Text("·", style: style),
          if (action != null)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(4),
              child: Text(
                action!,
                style: style?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
