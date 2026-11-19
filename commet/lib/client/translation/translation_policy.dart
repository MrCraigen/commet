import 'package:commet/client/translation/translation_provider.dart';

/// Tri-state automatic translation mode for rooms and spaces.
enum TranslationMode {
  inherit,
  enabled,
  disabled;

  static TranslationMode parse(Object? value) => switch (value) {
    "enabled" => TranslationMode.enabled,
    "disabled" => TranslationMode.disabled,
    _ => TranslationMode.inherit,
  };
}

/// Locally stored, per-account settings for a room or a space. Never
/// published to Matrix (no state events, no account data).
class TranslationScopeSettings {
  final TranslationMode mode;

  /// Target language override, null to inherit.
  final String? targetLanguage;

  /// Source language override, null to inherit. [translationAutoSource]
  /// explicitly requests automatic detection.
  final String? sourceLanguage;

  /// Explicit consent to send content of this (encrypted / private)
  /// conversation to the translation server. Only meaningful for rooms.
  final bool privacyConsent;

  const TranslationScopeSettings({
    this.mode = TranslationMode.inherit,
    this.targetLanguage,
    this.sourceLanguage,
    this.privacyConsent = false,
  });

  static const TranslationScopeSettings empty = TranslationScopeSettings();

  bool get isEmpty =>
      mode == TranslationMode.inherit &&
      targetLanguage == null &&
      sourceLanguage == null &&
      !privacyConsent;

  TranslationScopeSettings copyWith({
    TranslationMode? mode,
    String? Function()? targetLanguage,
    String? Function()? sourceLanguage,
    bool? privacyConsent,
  }) => TranslationScopeSettings(
    mode: mode ?? this.mode,
    targetLanguage: targetLanguage != null
        ? targetLanguage()
        : this.targetLanguage,
    sourceLanguage: sourceLanguage != null
        ? sourceLanguage()
        : this.sourceLanguage,
    privacyConsent: privacyConsent ?? this.privacyConsent,
  );

  Map<String, dynamic> toJson() => {
    "mode": mode.name,
    if (targetLanguage != null) "target": targetLanguage,
    if (sourceLanguage != null) "source": sourceLanguage,
    if (privacyConsent) "consent": true,
  };

  factory TranslationScopeSettings.fromJson(Map<String, dynamic> json) =>
      TranslationScopeSettings(
        mode: TranslationMode.parse(json["mode"]),
        targetLanguage: json["target"] is String ? json["target"] : null,
        sourceLanguage: json["source"] is String ? json["source"] : null,
        privacyConsent: json["consent"] == true,
      );

  /// Equality of the parts that matter for inheritance (consent is per room).
  bool samePolicyAs(TranslationScopeSettings other) =>
      mode == other.mode &&
      targetLanguage == other.targetLanguage &&
      sourceLanguage == other.sourceLanguage;
}

/// Global defaults.
class GlobalTranslationDefaults {
  final bool serviceEnabled;
  final bool autoTranslateByDefault;
  final String targetLanguage;
  final String sourceLanguage;

  const GlobalTranslationDefaults({
    required this.serviceEnabled,
    required this.autoTranslateByDefault,
    required this.targetLanguage,
    required this.sourceLanguage,
  });
}

enum TranslationPolicyOrigin {
  /// The service is switched off or not configured.
  serviceDisabled,
  room,
  space,

  /// Several parent spaces define different policies. Resolved to disabled.
  conflictingSpaces,
  global,
}

/// Why automatic translation is blocked even though the policy says enabled.
enum TranslationPrivacyBlock {
  none,

  /// Encrypted or private conversation without explicit room level opt-in.
  protectedConversation,
}

class EffectiveTranslationPolicy {
  final bool autoTranslate;
  final String targetLanguage;
  final String sourceLanguage;
  final TranslationPolicyOrigin origin;

  /// Identifiers of the spaces the policy was taken from (or which
  /// conflicted), sorted for deterministic output.
  final List<String> originSpaces;

  final bool isProtectedConversation;
  final bool hasPrivacyConsent;

  /// The policy would enable automatic translation, but privacy rules block it.
  final TranslationPrivacyBlock privacyBlock;

  const EffectiveTranslationPolicy({
    required this.autoTranslate,
    required this.targetLanguage,
    required this.sourceLanguage,
    required this.origin,
    this.originSpaces = const [],
    this.isProtectedConversation = false,
    this.hasPrivacyConsent = false,
    this.privacyBlock = TranslationPrivacyBlock.none,
  });

  /// Manual translation requires the service to be enabled, and for
  /// protected conversations, explicit consent.
  bool get manualAllowed =>
      origin != TranslationPolicyOrigin.serviceDisabled &&
      (!isProtectedConversation || hasPrivacyConsent);
}

/// Abstract view of the space hierarchy, so the resolver can be tested
/// without a Matrix client. Spaces may have multiple parents and the graph
/// may contain cycles.
abstract class TranslationHierarchy {
  /// Identifiers of spaces which directly contain [childId] (room or space).
  Iterable<String> parentsOf(String childId);
}

class MapTranslationHierarchy implements TranslationHierarchy {
  final Map<String, List<String>> parents;
  MapTranslationHierarchy(this.parents);

  @override
  Iterable<String> parentsOf(String childId) => parents[childId] ?? const [];
}

class TranslationPolicyResolver {
  /// Hard limit on traversed spaces, guards against pathological graphs.
  static const int maxVisitedSpaces = 256;

  /// Resolve the effective automatic translation policy for a room.
  ///
  /// Precedence:
  /// 1. Explicit room settings (mode not inherit).
  /// 2. Parent spaces: along every upward path the *nearest* space with an
  ///    explicit mode is a candidate. If all candidates agree they apply,
  ///    otherwise the result is a safe "disabled".
  /// 3. Global defaults.
  ///
  /// Room level language overrides always apply on top of the inherited
  /// policy. Protected conversations (encrypted / direct / private) are never
  /// translated automatically unless the room itself is explicitly enabled
  /// *and* has privacy consent - inheritance can not bypass this.
  static EffectiveTranslationPolicy resolve({
    required String roomId,
    required TranslationScopeSettings room,
    required TranslationSettingsLookup spaces,
    required TranslationHierarchy hierarchy,
    required GlobalTranslationDefaults global,
    bool isProtected = false,
  }) {
    String target(String? inherited) =>
        room.targetLanguage ?? inherited ?? global.targetLanguage;
    String source(String? inherited) =>
        room.sourceLanguage ?? inherited ?? global.sourceLanguage;

    if (!global.serviceEnabled) {
      return EffectiveTranslationPolicy(
        autoTranslate: false,
        targetLanguage: target(null),
        sourceLanguage: source(null),
        origin: TranslationPolicyOrigin.serviceDisabled,
        isProtectedConversation: isProtected,
        hasPrivacyConsent: room.privacyConsent,
      );
    }

    bool wanted;
    TranslationPolicyOrigin origin;
    List<String> originSpaces = const [];
    String? inheritedTarget;
    String? inheritedSource;

    if (room.mode != TranslationMode.inherit) {
      wanted = room.mode == TranslationMode.enabled;
      origin = TranslationPolicyOrigin.room;
    } else {
      var candidates = _collectSpaceCandidates(roomId, spaces, hierarchy);
      if (candidates.isEmpty) {
        wanted = global.autoTranslateByDefault;
        origin = TranslationPolicyOrigin.global;
      } else {
        var ids = candidates.keys.toList()..sort();
        var first = candidates[ids.first]!;
        var agree = candidates.values.every((c) => c.samePolicyAs(first));
        originSpaces = ids;
        if (agree) {
          wanted = first.mode == TranslationMode.enabled;
          origin = TranslationPolicyOrigin.space;
          inheritedTarget = first.targetLanguage;
          inheritedSource = first.sourceLanguage;
        } else {
          wanted = false;
          origin = TranslationPolicyOrigin.conflictingSpaces;
        }
      }
    }

    var privacyBlock = TranslationPrivacyBlock.none;
    if (wanted && isProtected) {
      var explicitlyAllowed =
          room.mode == TranslationMode.enabled && room.privacyConsent;
      if (!explicitlyAllowed) {
        wanted = false;
        privacyBlock = TranslationPrivacyBlock.protectedConversation;
      }
    }

    return EffectiveTranslationPolicy(
      autoTranslate: wanted,
      targetLanguage: target(inheritedTarget),
      sourceLanguage: source(inheritedSource),
      origin: origin,
      originSpaces: originSpaces,
      isProtectedConversation: isProtected,
      hasPrivacyConsent: room.privacyConsent,
      privacyBlock: privacyBlock,
    );
  }

  /// Walks parent spaces upward. A space with an explicit mode terminates its
  /// path; spaces set to inherit are passed through to their own parents.
  /// Each space is visited at most once, which also breaks cycles.
  static Map<String, TranslationScopeSettings> _collectSpaceCandidates(
    String roomId,
    TranslationSettingsLookup spaces,
    TranslationHierarchy hierarchy,
  ) {
    var result = <String, TranslationScopeSettings>{};
    var visited = <String>{roomId};
    var frontier = hierarchy.parentsOf(roomId).toList();

    while (frontier.isNotEmpty && visited.length < maxVisitedSpaces) {
      var next = <String>[];
      for (var spaceId in frontier) {
        if (!visited.add(spaceId)) continue;
        var settings = spaces(spaceId);
        if (settings.mode != TranslationMode.inherit) {
          result[spaceId] = settings;
        } else {
          next.addAll(hierarchy.parentsOf(spaceId));
        }
      }
      frontier = next;
    }

    return result;
  }
}

typedef TranslationSettingsLookup = TranslationScopeSettings Function(
  String identifier,
);

/// Display helper: whether a language code means automatic detection.
bool isAutoSource(String? code) =>
    code == null || code == translationAutoSource;
