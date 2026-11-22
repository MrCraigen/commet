import 'package:commet/client/translation/translation_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _global = GlobalTranslationDefaults(
  serviceEnabled: true,
  autoTranslateByDefault: false,
  targetLanguage: "sv",
  sourceLanguage: "auto",
);

const _on = TranslationScopeSettings(mode: TranslationMode.enabled);
const _off = TranslationScopeSettings(mode: TranslationMode.disabled);

EffectiveTranslationPolicy _resolve({
  TranslationScopeSettings room = TranslationScopeSettings.empty,
  Map<String, TranslationScopeSettings> spaces = const {},
  Map<String, List<String>> parents = const {},
  GlobalTranslationDefaults global = _global,
  bool isProtected = false,
}) => TranslationPolicyResolver.resolve(
  roomId: "!room",
  room: room,
  spaces: (id) => spaces[id] ?? TranslationScopeSettings.empty,
  hierarchy: MapTranslationHierarchy(parents),
  global: global,
  isProtected: isProtected,
);

void main() {
  test("global fallback is disabled by default", () {
    var p = _resolve();
    expect(p.autoTranslate, isFalse);
    expect(p.origin, TranslationPolicyOrigin.global);
    expect(p.targetLanguage, "sv");
  });

  test("service disabled overrides everything", () {
    var p = _resolve(
      room: _on,
      global: const GlobalTranslationDefaults(
        serviceEnabled: false,
        autoTranslateByDefault: true,
        targetLanguage: "sv",
        sourceLanguage: "auto",
      ),
    );
    expect(p.autoTranslate, isFalse);
    expect(p.origin, TranslationPolicyOrigin.serviceDisabled);
    expect(p.manualAllowed, isFalse);
  });

  test("space setting is inherited by its rooms", () {
    var p = _resolve(
      spaces: {
        "!lod": const TranslationScopeSettings(
          mode: TranslationMode.enabled,
          sourceLanguage: "es",
          targetLanguage: "sv",
        ),
      },
      parents: {
        "!room": ["!lod"],
      },
    );
    expect(p.autoTranslate, isTrue);
    expect(p.origin, TranslationPolicyOrigin.space);
    expect(p.originSpaces, ["!lod"]);
    expect(p.sourceLanguage, "es");
  });

  test("room settings override the space", () {
    var p = _resolve(
      room: _off,
      spaces: {"!lod": _on},
      parents: {
        "!room": ["!lod"],
      },
    );
    expect(p.autoTranslate, isFalse);
    expect(p.origin, TranslationPolicyOrigin.room);

    var langOverride = _resolve(
      room: const TranslationScopeSettings(targetLanguage: "en"),
      spaces: {
        "!lod": const TranslationScopeSettings(
          mode: TranslationMode.enabled,
          targetLanguage: "sv",
        ),
      },
      parents: {
        "!room": ["!lod"],
      },
    );
    expect(langOverride.autoTranslate, isTrue);
    expect(langOverride.targetLanguage, "en");
  });

  test("nested spaces: nearest explicit space wins along a path", () {
    var p = _resolve(
      spaces: {"!outer": _on, "!inner": TranslationScopeSettings.empty},
      parents: {
        "!room": ["!inner"],
        "!inner": ["!outer"],
      },
    );
    expect(p.autoTranslate, isTrue);
    expect(p.originSpaces, ["!outer"]);

    var closer = _resolve(
      spaces: {"!outer": _on, "!inner": _off},
      parents: {
        "!room": ["!inner"],
        "!inner": ["!outer"],
      },
    );
    expect(closer.autoTranslate, isFalse);
    expect(closer.originSpaces, ["!inner"]);
  });

  test("conflicting parent spaces resolve to disabled", () {
    var p = _resolve(
      spaces: {"!a": _on, "!b": _off},
      parents: {
        "!room": ["!b", "!a"],
      },
    );
    expect(p.autoTranslate, isFalse);
    expect(p.origin, TranslationPolicyOrigin.conflictingSpaces);
    expect(p.originSpaces, ["!a", "!b"]);

    var langConflict = _resolve(
      spaces: {
        "!a": const TranslationScopeSettings(
          mode: TranslationMode.enabled,
          targetLanguage: "sv",
        ),
        "!b": const TranslationScopeSettings(
          mode: TranslationMode.enabled,
          targetLanguage: "en",
        ),
      },
      parents: {
        "!room": ["!a", "!b"],
      },
    );
    expect(langConflict.autoTranslate, isFalse);
    expect(langConflict.origin, TranslationPolicyOrigin.conflictingSpaces);
  });

  test("agreeing parent spaces are fine, and order is deterministic", () {
    var p1 = _resolve(
      spaces: {"!a": _on, "!b": _on},
      parents: {
        "!room": ["!b", "!a"],
      },
    );
    var p2 = _resolve(
      spaces: {"!a": _on, "!b": _on},
      parents: {
        "!room": ["!a", "!b"],
      },
    );
    expect(p1.autoTranslate, isTrue);
    expect(p1.originSpaces, p2.originSpaces);
  });

  test("cyclic space relationships terminate", () {
    var p = _resolve(
      spaces: {},
      parents: {
        "!room": ["!a"],
        "!a": ["!b"],
        "!b": ["!a", "!room"],
      },
    );
    expect(p.origin, TranslationPolicyOrigin.global);

    var withSetting = _resolve(
      spaces: {"!b": _on},
      parents: {
        "!room": ["!a"],
        "!a": ["!b"],
        "!b": ["!a"],
      },
    );
    expect(withSetting.autoTranslate, isTrue);
  });

  test("protected conversations are not translated through inheritance", () {
    var viaSpace = _resolve(
      spaces: {"!lod": _on},
      parents: {
        "!room": ["!lod"],
      },
      isProtected: true,
    );
    expect(viaSpace.autoTranslate, isFalse);
    expect(
      viaSpace.privacyBlock,
      TranslationPrivacyBlock.protectedConversation,
    );
    expect(viaSpace.manualAllowed, isFalse);

    var viaGlobal = _resolve(
      isProtected: true,
      global: const GlobalTranslationDefaults(
        serviceEnabled: true,
        autoTranslateByDefault: true,
        targetLanguage: "sv",
        sourceLanguage: "auto",
      ),
    );
    expect(viaGlobal.autoTranslate, isFalse);

    var explicitNoConsent = _resolve(room: _on, isProtected: true);
    expect(explicitNoConsent.autoTranslate, isFalse);

    var consentOnly = _resolve(
      room: const TranslationScopeSettings(privacyConsent: true),
      spaces: {"!lod": _on},
      parents: {
        "!room": ["!lod"],
      },
      isProtected: true,
    );
    expect(consentOnly.autoTranslate, isFalse);
    expect(consentOnly.manualAllowed, isTrue);

    var allowed = _resolve(
      room: const TranslationScopeSettings(
        mode: TranslationMode.enabled,
        privacyConsent: true,
      ),
      isProtected: true,
    );
    expect(allowed.autoTranslate, isTrue);
    expect(allowed.manualAllowed, isTrue);
  });

  test("settings json round trip", () {
    const s = TranslationScopeSettings(
      mode: TranslationMode.enabled,
      targetLanguage: "sv",
      sourceLanguage: "es",
      privacyConsent: true,
    );
    var r = TranslationScopeSettings.fromJson(s.toJson());
    expect(r.samePolicyAs(s), isTrue);
    expect(r.privacyConsent, isTrue);
    expect(
      TranslationScopeSettings.fromJson({"mode": "weird"}).mode,
      TranslationMode.inherit,
    );
  });
}
