import 'package:commet/client/client.dart';
import 'package:commet/client/timeline_events/timeline_event.dart';
import 'package:commet/client/timeline_events/timeline_event_message.dart';
import 'package:commet/client/translation/matrix_translation_adapter.dart';
import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/ui/molecules/timeline_events/timeline_event_menu.dart';
import 'package:commet/ui/molecules/translation/translation_strings.dart';
import 'package:commet/ui/navigation/adaptive_dialog.dart';
import 'package:flutter/material.dart';
import 'package:tiamat/tiamat.dart' as tiamat;

class TranslationUi {
  static String errorText(TranslationErrorKind? kind) => switch (kind) {
    TranslationErrorKind.unavailable =>
      TranslationStrings.labelTranslationErrorUnavailable,
    TranslationErrorKind.tls => TranslationStrings.labelTranslationErrorTls,
    TranslationErrorKind.timeout =>
      TranslationStrings.labelTranslationErrorTimeout,
    TranslationErrorKind.authentication =>
      TranslationStrings.labelTranslationErrorAuthentication,
    TranslationErrorKind.queueFull =>
      TranslationStrings.labelTranslationErrorQueueFull,
    TranslationErrorKind.invalidRequest =>
      TranslationStrings.labelTranslationErrorInvalidRequest,
    TranslationErrorKind.unsupportedLanguage =>
      TranslationStrings.labelTranslationErrorUnsupportedLanguage,
    TranslationErrorKind.tooLong =>
      TranslationStrings.labelTranslationErrorTooLong,
    TranslationErrorKind.backendFailure =>
      TranslationStrings.labelTranslationErrorBackend,
    TranslationErrorKind.invalidResponse =>
      TranslationStrings.labelTranslationErrorInvalidResponse,
    TranslationErrorKind.notConfigured =>
      TranslationStrings.labelTranslationErrorNotConfigured,
    _ => TranslationStrings.labelTranslationErrorUnknown,
  };

  static String skipText(TranslationSkipReason? reason) {
    var max =
        Translation.service?.provider?.maxInputCodePoints ??
        500; // backend default
    return switch (reason) {
      TranslationSkipReason.noNaturalLanguage =>
        TranslationStrings.labelTranslationSkipNoText,
      TranslationSkipReason.unsupportedFormatting =>
        TranslationStrings.labelTranslationSkipFormatting,
      TranslationSkipReason.spoiler =>
        TranslationStrings.labelTranslationSkipSpoiler,
      TranslationSkipReason.media =>
        TranslationStrings.labelTranslationSkipMedia,
      TranslationSkipReason.tooLong =>
        TranslationStrings.labelTranslationSkipTooLong(max),
      _ => TranslationStrings.labelTranslationSkipMessageType,
    };
  }

  static String languageName(String? code) {
    if (isAutoSource(code))
      return TranslationStrings.labelTranslationAutoDetect;
    return Translation.service?.languageName(code) ?? code!;
  }

  /// Sorted list of language codes for pickers; includes [extra] codes so a
  /// stored selection is still displayed if the server list changed.
  static List<String> languageCodes({Iterable<String?> extra = const []}) {
    var languages = Translation.service?.languages ?? const {};
    var codes = {...languages.keys};
    for (var e in extra) {
      if (e != null && !isAutoSource(e)) codes.add(e);
    }
    var list = codes.toList()
      ..sort((a, b) => languageName(a).compareTo(languageName(b)));
    return list;
  }

  /// Shows the privacy consent dialog for protected rooms if needed.
  /// Returns true if translation may proceed.
  static Future<bool> ensurePrivacyConsent(
    BuildContext context,
    Room room,
  ) async {
    var service = Translation.service;
    var adapter = Translation.adapter;
    if (service == null || adapter == null) return false;

    if (!MatrixTranslationAdapter.isProtectedRoom(room)) return true;

    var accountId = room.client.identifier;
    var settings = service.settings.roomSettings(accountId, room.identifier);
    if (settings.privacyConsent) return true;

    var server = service.serverUri?.host ?? service.settings.serverUrl;
    var result = await AdaptiveDialog.confirmation(
      context,
      title: TranslationStrings.labelTranslationConsentTitle,
      prompt: TranslationStrings.labelTranslationConsentBody(server),
      confirmationText: TranslationStrings.promptTranslationConsentAllow,
      cancelText: MaterialLocalizations.of(context).cancelButtonLabel,
    );

    if (result != true) return false;

    await service.settings.setRoomSettings(
      accountId,
      room.identifier,
      settings.copyWith(privacyConsent: true),
    );
    service.notifyPolicyChanged();
    return true;
  }

  /// Quick room level toggle: flips the room between explicit "On" and
  /// explicit "Off" relative to the currently effective policy.
  static Future<void> toggleRoomAutoTranslation(
    BuildContext context,
    Room room,
  ) async {
    var service = Translation.service;
    var adapter = Translation.adapter;
    if (service == null || adapter == null) return;
    if (!service.isEnabled) {
      await showInfo(context, TranslationStrings.labelTranslationDisabledHint);
      return;
    }

    var accountId = room.client.identifier;
    var enable = !adapter.policyFor(room).autoTranslate;

    if (enable && !await ensurePrivacyConsent(context, room)) return;

    var settings = service.settings.roomSettings(accountId, room.identifier);
    await service.settings.setRoomSettings(
      accountId,
      room.identifier,
      settings.copyWith(
        mode: enable ? TranslationMode.enabled : TranslationMode.disabled,
      ),
    );
    service.notifyPolicyChanged();
  }

  static Future<void> showInfo(BuildContext context, String message) {
    return AdaptiveDialog.show(
      context,
      title: TranslationStrings.labelTranslationSettings,
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: tiamat.Text.body(message),
        ),
      ),
    );
  }

  /// Translate [event] manually, handling consent and explaining failures.
  static Future<void> translateManually(
    BuildContext context, {
    required Room room,
    required MessageRef ref,
    String? targetLanguage,
    String? sourceLanguage,
  }) async {
    var service = Translation.service;
    if (service == null || !service.isEnabled) {
      await showInfo(context, TranslationStrings.labelTranslationDisabledHint);
      return;
    }

    if (!await ensurePrivacyConsent(context, room)) return;

    // Consent may have changed the policy: refresh before translating.
    var adapter = Translation.adapter!;
    service.refresh(ref, adapter.contextFor(room));

    var result = service.translate(
      ref,
      targetLanguage: targetLanguage,
      sourceLanguage: sourceLanguage,
    );

    if (!context.mounted) return;

    switch (result) {
      case ManualTranslationResult.unsupported:
        await showInfo(context, skipText(service.stateOf(ref).skipReason));
      case ManualTranslationResult.serviceDisabled:
        await showInfo(
          context,
          TranslationStrings.labelTranslationDisabledHint,
        );
      case ManualTranslationResult.needsPrivacyConsent:
      case ManualTranslationResult.unknownMessage:
      case ManualTranslationResult.started:
      case ManualTranslationResult.alreadyAvailable:
        break;
    }
  }

  static Future<void> showTranslateToDialog(
    BuildContext context, {
    required Room room,
    required MessageRef ref,
  }) async {
    var service = Translation.service;
    if (service == null || !service.isEnabled) {
      await showInfo(context, TranslationStrings.labelTranslationDisabledHint);
      return;
    }

    var policy = Translation.adapter!.contextFor(room).policy;
    var override = service.overrideFor(ref);

    var picked = await AdaptiveDialog.show<(String, String)>(
      context,
      title: TranslationStrings.labelTranslateMessageTitle,
      builder: (context) => _TranslateToDialog(
        initialTarget: override?.target ?? policy.targetLanguage,
        initialSource: override?.source ?? policy.sourceLanguage,
      ),
    );

    if (picked == null || !context.mounted) return;

    await translateManually(
      context,
      room: room,
      ref: ref,
      targetLanguage: picked.$1,
      sourceLanguage: picked.$2,
    );
  }

  /// Context menu entries for a message.
  static List<TimelineEventMenuEntry> menuEntries({
    required Timeline timeline,
    required TimelineEvent event,
    Function()? onActionFinished,
  }) {
    var service = Translation.service;
    if (service == null || !service.isEnabled) return const [];
    if (event is! TimelineEventMessage) return const [];
    if (event.status != TimelineEventStatus.synced) return const [];

    var room = timeline.room;
    var ref = MatrixTranslationAdapter.refFor(room, event);
    if (!service.isKnown(ref)) return const [];

    var state = service.currentState(ref);

    // Run follow-up UI on the navigator's context, the menu itself may be
    // closed by onActionFinished.
    void run(
      BuildContext context,
      Future<void> Function(BuildContext context) action,
    ) {
      var navigatorContext = Navigator.of(context).context;
      onActionFinished?.call();
      action(navigatorContext);
    }

    var entries = <TimelineEventMenuEntry>[];

    if (state.hasTranslation) {
      entries.add(
        TimelineEventMenuEntry(
          name: state.showOriginal
              ? TranslationStrings.promptTranslationShowTranslation
              : TranslationStrings.promptTranslationShowOriginal,
          icon: Icons.translate,
          action: (context) {
            service.setShowOriginal(ref, !state.showOriginal);
            onActionFinished?.call();
          },
        ),
      );
    } else if (state.status == MessageTranslationStatus.failed) {
      entries.add(
        TimelineEventMenuEntry(
          name: TranslationStrings.promptRetryTranslation,
          icon: Icons.translate,
          action: (context) =>
              run(context, (c) => translateManually(c, room: room, ref: ref)),
        ),
      );
    } else if (!state.isBusy &&
        state.status != MessageTranslationStatus.sameLanguage) {
      entries.add(
        TimelineEventMenuEntry(
          name: TranslationStrings.promptTranslate,
          icon: Icons.translate,
          action: (context) =>
              run(context, (c) => translateManually(c, room: room, ref: ref)),
        ),
      );
    }

    if (state.status != MessageTranslationStatus.unsupported) {
      entries.add(
        TimelineEventMenuEntry(
          name: TranslationStrings.promptTranslateTo,
          icon: Icons.g_translate,
          action: (context) => run(
            context,
            (c) => showTranslateToDialog(c, room: room, ref: ref),
          ),
        ),
      );
    }

    return entries;
  }
}

/// Dropdown for picking a language. `null` represents "inherit" when
/// [inheritLabel] is given, [translationAutoSource] represents automatic
/// detection when [allowAuto] is set.
class TranslationLanguageDropdown extends StatelessWidget {
  const TranslationLanguageDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAuto = false,
    this.inheritLabel,
  });

  final String? value;
  final void Function(String? value) onChanged;
  final bool allowAuto;
  final String? inheritLabel;

  static const String _inheritSentinel = "\u0000inherit";

  @override
  Widget build(BuildContext context) {
    var items = <String>[
      if (inheritLabel != null) _inheritSentinel,
      if (allowAuto) translationAutoSource,
      ...TranslationUi.languageCodes(extra: [value]),
    ];

    var current = value ?? (inheritLabel != null ? _inheritSentinel : null);
    if (current != null && !items.contains(current)) items.add(current);

    return tiamat.DropdownSelector<String>(
      items: items,
      value: current ?? items.first,
      itemHeight: 44,
      itemBuilder: (item) => tiamat.Text.label(
        item == _inheritSentinel
            ? inheritLabel!
            : TranslationUi.languageName(item),
      ),
      onItemSelected: (item) {
        if (item == null) return;
        onChanged(item == _inheritSentinel ? null : item);
      },
    );
  }
}

class _TranslateToDialog extends StatefulWidget {
  const _TranslateToDialog({
    required this.initialTarget,
    required this.initialSource,
  });

  final String initialTarget;
  final String initialSource;

  @override
  State<_TranslateToDialog> createState() => _TranslateToDialogState();
}

class _TranslateToDialogState extends State<_TranslateToDialog> {
  late String target = widget.initialTarget;
  late String source = widget.initialSource;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, minWidth: 300),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tiamat.Text.labelEmphasised(
              TranslationStrings.labelTranslationTargetLanguage,
            ),
            const SizedBox(height: 4),
            TranslationLanguageDropdown(
              value: target,
              onChanged: (v) => setState(() => target = v ?? target),
            ),
            const SizedBox(height: 12),
            tiamat.Text.labelEmphasised(
              TranslationStrings.labelTranslationSourceLanguage,
            ),
            const SizedBox(height: 4),
            TranslationLanguageDropdown(
              value: source,
              allowAuto: true,
              onChanged: (v) =>
                  setState(() => source = v ?? translationAutoSource),
            ),
            const SizedBox(height: 16),
            tiamat.Button(
              text: TranslationStrings.promptTranslate,
              onTap: () => Navigator.of(context).pop((target, source)),
            ),
          ],
        ),
      ),
    );
  }
}
