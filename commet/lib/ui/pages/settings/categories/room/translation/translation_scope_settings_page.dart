import 'dart:async';

import 'package:commet/client/client.dart';
import 'package:commet/client/translation/matrix_translation_adapter.dart';
import 'package:commet/client/translation/translation.dart';
import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/ui/molecules/translation/translation_strings.dart';
import 'package:commet/ui/molecules/translation/translation_ui.dart';
import 'package:commet/ui/pages/settings/categories/app/boolean_toggle.dart';
import 'package:flutter/material.dart';
import 'package:tiamat/tiamat.dart' as tiamat;

/// Local (never published) automatic translation settings for a room or a
/// space. Exactly one of [room] / [space] is set.
class TranslationScopeSettingsPage extends StatefulWidget {
  const TranslationScopeSettingsPage.room(Room this.room, {super.key})
    : space = null;
  const TranslationScopeSettingsPage.space(Space this.space, {super.key})
    : room = null;

  final Room? room;
  final Space? space;

  @override
  State<TranslationScopeSettingsPage> createState() =>
      _TranslationScopeSettingsPageState();
}

class _TranslationScopeSettingsPageState
    extends State<TranslationScopeSettingsPage> {
  StreamSubscription? _sub;

  TranslationService get service => Translation.service!;
  Client get client => widget.room?.client ?? widget.space!.client;
  String get accountId => client.identifier;
  String get scopeId => widget.room?.identifier ?? widget.space!.identifier;
  bool get isRoom => widget.room != null;

  TranslationScopeSettings get current => isRoom
      ? service.settings.roomSettings(accountId, scopeId)
      : service.settings.spaceSettings(accountId, scopeId);

  @override
  void initState() {
    super.initState();
    _sub = service.onPolicyChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _set(TranslationScopeSettings settings) async {
    if (isRoom) {
      await service.settings.setRoomSettings(accountId, scopeId, settings);
    } else {
      await service.settings.setSpaceSettings(accountId, scopeId, settings);
    }
    service.notifyPolicyChanged();
  }

  @override
  Widget build(BuildContext context) {
    var settings = current;
    var global = service.settings.globalDefaults;

    return Column(
      children: [
        tiamat.Panel(
          header: TranslationStrings.labelTranslationAutoTitle,
          mode: tiamat.TileType.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              tiamat.Text.labelLow(
                isRoom
                    ? TranslationStrings.labelTranslationRoomDescription
                    : TranslationStrings.labelTranslationSpaceDescription,
              ),
              const SizedBox(height: 8),
              SegmentedButton<TranslationMode>(
                segments: [
                  ButtonSegment(
                    value: TranslationMode.inherit,
                    label: Text(TranslationStrings.labelTranslationModeInherit),
                  ),
                  ButtonSegment(
                    value: TranslationMode.enabled,
                    label: Text(TranslationStrings.labelTranslationModeEnabled),
                  ),
                  ButtonSegment(
                    value: TranslationMode.disabled,
                    label: Text(
                      TranslationStrings.labelTranslationModeDisabled,
                    ),
                  ),
                ],
                selected: {settings.mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    _set(settings.copyWith(mode: s.first)),
              ),
              const SizedBox(height: 12),
              tiamat.Text.labelEmphasised(
                TranslationStrings.labelTranslationTargetLanguage,
              ),
              const SizedBox(height: 4),
              TranslationLanguageDropdown(
                value: settings.targetLanguage,
                inheritLabel:
                    TranslationStrings.labelTranslationInheritLanguage(
                      TranslationUi.languageName(global.targetLanguage),
                    ),
                onChanged: (v) =>
                    _set(settings.copyWith(targetLanguage: () => v)),
              ),
              const SizedBox(height: 12),
              tiamat.Text.labelEmphasised(
                TranslationStrings.labelTranslationSourceLanguage,
              ),
              const SizedBox(height: 4),
              TranslationLanguageDropdown(
                value: settings.sourceLanguage,
                allowAuto: true,
                inheritLabel:
                    TranslationStrings.labelTranslationInheritLanguage(
                      TranslationUi.languageName(global.sourceLanguage),
                    ),
                onChanged: (v) =>
                    _set(settings.copyWith(sourceLanguage: () => v)),
              ),
              if (isRoom) ...[
                const SizedBox(height: 16),
                _EffectivePolicySummary(room: widget.room!),
              ],
            ],
          ),
        ),
        if (isRoom && MatrixTranslationAdapter.isProtectedRoom(widget.room!))
          tiamat.Panel(
            header: TranslationStrings.labelTranslationPrivateRoomTitle,
            mode: tiamat.TileType.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tiamat.Text.labelLow(
                  TranslationStrings.labelTranslationPrivateRoomBlocked,
                ),
                const SizedBox(height: 8),
                BooleanToggle(
                  key: ValueKey(settings.privacyConsent),
                  getValue: () => current.privacyConsent,
                  setValue: (v) async {
                    if (v) {
                      // Shows the full explanation before storing consent.
                      await TranslationUi.ensurePrivacyConsent(
                        context,
                        widget.room!,
                      );
                    } else {
                      await _set(current.copyWith(privacyConsent: false));
                    }
                    if (mounted) setState(() {});
                  },
                  title: TranslationStrings.labelTranslationPrivateRoomConsent,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EffectivePolicySummary extends StatelessWidget {
  const _EffectivePolicySummary({required this.room});
  final Room room;

  String _spaceNames(List<String> ids) {
    return ids
        .map((id) => room.client.getSpace(id)?.displayName ?? id)
        .join(", ");
  }

  @override
  Widget build(BuildContext context) {
    var policy = Translation.adapter!.policyFor(room);

    var summary = policy.autoTranslate
        ? TranslationStrings.labelTranslationEffectiveOn(
            TranslationUi.languageName(policy.sourceLanguage),
            TranslationUi.languageName(policy.targetLanguage),
          )
        : TranslationStrings.labelTranslationEffectiveOff;

    var origin = switch (policy.origin) {
      TranslationPolicyOrigin.room =>
        TranslationStrings.labelTranslationOriginRoom,
      TranslationPolicyOrigin.space =>
        TranslationStrings.labelTranslationOriginSpace(
          _spaceNames(policy.originSpaces),
        ),
      TranslationPolicyOrigin.conflictingSpaces =>
        TranslationStrings.labelTranslationOriginConflict(
          _spaceNames(policy.originSpaces),
        ),
      TranslationPolicyOrigin.global =>
        TranslationStrings.labelTranslationOriginGlobal,
      TranslationPolicyOrigin.serviceDisabled =>
        TranslationStrings.labelTranslationOriginServiceDisabled,
    };

    var scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            policy.autoTranslate ? Icons.translate : Icons.translate_outlined,
            size: 18,
            color: policy.autoTranslate
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tiamat.Text.label(summary),
                tiamat.Text.labelLow(origin),
                if (policy.privacyBlock ==
                    TranslationPrivacyBlock.protectedConversation)
                  tiamat.Text.labelLow(
                    TranslationStrings.labelTranslationPrivateRoomBlocked,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
