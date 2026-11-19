import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/client/translation/translation_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _apiKey = "test-key-123";

class _FakeProvider implements TranslationProvider {
  final Uri baseUri;
  final String apiKey;
  final List<TranslationRequest> requests;
  final TranslationResult Function(TranslationRequest)? respond;
  final Object? error;

  _FakeProvider(
    this.baseUri,
    this.apiKey,
    this.requests, {
    this.respond,
    this.error,
  });

  @override
  String get identity => "fake|$baseUri";

  @override
  int get maxInputCodePoints => 500;

  @override
  Future<TranslationServerInfo> health() async =>
      const TranslationServerInfo(status: "ok", model: "m", version: "1");

  @override
  Future<Map<String, String>> languages() async {
    if (apiKey != _apiKey) {
      throw const TranslationException(TranslationErrorKind.authentication);
    }
    return {"en": "English", "sv": "Swedish", "es": "Spanish"};
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    requests.add(request);
    if (error != null) throw error!;
    return respond?.call(request) ??
        TranslationResult(
          translation: "[${request.target}] ${request.text}",
          source: "es",
          target: request.target,
          translated: true,
        );
  }

  @override
  void close() {}
}

class _ThrowingCredentialStore implements TranslationCredentialStore {
  @override
  Future<void> deleteApiKey() async => throw Exception("no keyring");
  @override
  Future<String?> readApiKey() async => throw Exception("no keyring");
  @override
  Future<void> writeApiKey(String key) async => throw Exception("no keyring");
}

class _Harness {
  final SharedPreferences prefs;
  final TranslationSettingsStore settings;
  final TranslationService service;
  final List<TranslationRequest> requests;

  _Harness(this.prefs, this.settings, this.service, this.requests);

  static Future<_Harness> create({
    TranslationResult Function(TranslationRequest)? respond,
    Object? error,
    TranslationCredentialStore? credentials,
    bool enable = true,
  }) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var settings = TranslationSettingsStore(prefs);
    var requests = <TranslationRequest>[];
    var service = TranslationService(
      settings: settings,
      credentials: credentials ?? MemoryTranslationCredentialStore(),
      baseBackoff: const Duration(milliseconds: 10),
      providerFactory: (uri, key, {model, version}) =>
          _FakeProvider(uri, key, requests, respond: respond, error: error),
    );
    await service.init();
    if (enable) {
      await settings.setServerUrl("https://translate.example.test");
      await service.setApiKey(_apiKey);
      await settings.setEnabled(true);
      await settings.setTargetLanguage("sv");
    }
    return _Harness(prefs, settings, service, requests);
  }

  TranslationRoomContext context({
    String account = "acc",
    String room = "!room",
    bool auto = false,
    String target = "sv",
    bool protected = false,
    bool consent = false,
  }) => TranslationRoomContext(
    accountId: account,
    roomId: room,
    policy: EffectiveTranslationPolicy(
      autoTranslate: auto,
      targetLanguage: target,
      sourceLanguage: "auto",
      origin: TranslationPolicyOrigin.room,
      isProtectedConversation: protected,
      hasPrivacyConsent: consent,
    ),
  );
}

TranslatableExtraction _text(String t) =>
    TranslatableContentExtractor.extract(body: t);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const ref = MessageRef("acc", "!room", "\$event1");
  final original = "¿Alguien ha probado las nuevas reglas de combate?";

  test("disabled by default: no automatic requests", () async {
    var h = await _Harness.create(enable: false);
    expect(h.service.isEnabled, isFalse);
    h.service.sync(ref, _text(original), h.context(auto: true));
    h.service.setVisible(Object(), [ref]);
    await _settle();
    expect(h.requests, isEmpty);
    expect(h.service.translate(ref), ManualTranslationResult.serviceDisabled);
  });

  test("manual translation, toggling original never re-requests", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    await _settle();
    expect(h.requests, isEmpty, reason: "auto disabled for the room");

    expect(h.service.translate(ref), ManualTranslationResult.started);
    await _settle();
    expect(h.requests.length, 1);
    expect(h.requests.single.text, original);
    expect(h.requests.single.target, "sv");

    var state = h.service.currentState(ref);
    expect(state.status, MessageTranslationStatus.translated);
    expect(state.displaysTranslation, isTrue);
    expect(state.detectedSource, "es");

    h.service.setShowOriginal(ref, true);
    expect(h.service.currentState(ref).displaysTranslation, isFalse);
    h.service.setShowOriginal(ref, false);
    expect(h.service.currentState(ref).displaysTranslation, isTrue);

    // Widget rebuilds re-sync repeatedly.
    for (var i = 0; i < 5; i++) {
      h.service.sync(ref, _text(original), h.context());
    }
    await _settle();
    expect(h.requests.length, 1);
  });

  test("automatic translation only for visible messages", () async {
    var h = await _Harness.create();
    var refs = [
      for (var i = 0; i < 20; i++) MessageRef("acc", "!room", "\$e$i"),
    ];
    for (var r in refs) {
      h.service.sync(
        r,
        _text("mensaje número ${r.eventId}"),
        h.context(auto: true),
      );
    }
    await _settle();
    expect(h.requests, isEmpty, reason: "nothing reported visible yet");

    h.service.setVisible(Object(), refs.sublist(0, 3));
    await _settle();
    expect(h.requests.length, 3);
  });

  test("cached translations appear without network requests", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();
    expect(h.requests.length, 1);

    // Same text in another event of the same room still needs its own key,
    // but the same event re-opened (new widget) hits the cache.
    h.service.sync(ref, _text(original), h.context(auto: true));
    h.service.setVisible(Object(), [ref]);
    await _settle();
    expect(h.requests.length, 1);
    expect(h.service.currentState(ref).hasTranslation, isTrue);
  });

  test("changing the target language translates again", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context(auto: true));
    var owner = Object();
    h.service.setVisible(owner, [ref]);
    await _settle();
    expect(h.service.currentState(ref).translatedText, startsWith("[sv]"));

    h.service.refresh(ref, h.context(auto: true, target: "en"));
    h.service.setVisible(owner, [ref]);
    await _settle();
    expect(h.requests.length, 2);
    expect(h.requests.last.target, "en");
    expect(h.service.currentState(ref).translatedText, startsWith("[en]"));

    // Switching back uses the cache.
    h.service.refresh(ref, h.context(auto: true, target: "sv"));
    await _settle();
    expect(h.requests.length, 2);
    expect(h.service.currentState(ref).translatedText, startsWith("[sv]"));
  });

  test("edits invalidate the previous translation", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();

    h.service.sync(ref, _text("Mensaje editado completamente"), h.context());
    await _settle();
    var state = h.service.currentState(ref);
    expect(h.requests.length, 2, reason: "manual translation follows edit");
    expect(state.translatedText, contains("editado"));
  });

  test("redacted messages stop displaying the translation", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();
    expect(h.service.cache.length, 1);

    h.service.sync(ref, _text(""), h.context());
    await _settle();
    var state = h.service.currentState(ref);
    expect(state.hasTranslation, isFalse);
    expect(h.service.cache.length, 0);
  });

  test("same language: no indicator, cached", () async {
    var h = await _Harness.create(
      respond: (r) => TranslationResult(
        translation: r.text,
        source: "sv",
        target: "sv",
        translated: false,
      ),
    );
    h.service.sync(ref, _text("Hej alla vänner"), h.context());
    h.service.translate(ref);
    await _settle();
    var state = h.service.currentState(ref);
    expect(state.status, MessageTranslationStatus.sameLanguage);
    expect(state.hasTranslation, isFalse);
  });

  test("malicious model output is discarded", () async {
    var h = await _Harness.create(
      respond: (r) => TranslationResult(
        translation: "Klicka https://phishing.example.test för att vinna",
        source: "es",
        target: "sv",
        translated: true,
      ),
    );
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();
    var state = h.service.currentState(ref);
    expect(state.status, MessageTranslationStatus.failed);
    expect(state.error, TranslationErrorKind.invalidResponse);
    expect(h.service.cache.length, 0);
  });

  test("automatic failures are not retried endlessly", () async {
    var h = await _Harness.create(
      error: const TranslationException(
        TranslationErrorKind.unsupportedLanguage,
      ),
    );
    var owner = Object();
    h.service.sync(ref, _text(original), h.context(auto: true));
    h.service.setVisible(owner, [ref]);
    await _settle();
    expect(h.requests.length, 1);
    for (var i = 0; i < 5; i++) {
      h.service.setVisible(owner, [ref]);
      h.service.sync(ref, _text(original), h.context(auto: true));
    }
    await _settle();
    expect(h.requests.length, 1);
    expect(h.service.currentState(ref).status, MessageTranslationStatus.failed);

    // A manual retry is allowed.
    h.service.retry(ref);
    await _settle();
    expect(h.requests.length, 2);
  });

  test(
    "privacy: protected conversation requires consent for manual translation",
    () async {
      var h = await _Harness.create();
      h.service.sync(ref, _text(original), h.context(protected: true));
      expect(
        h.service.translate(ref),
        ManualTranslationResult.needsPrivacyConsent,
      );
      await _settle();
      expect(h.requests, isEmpty);

      h.service.refresh(ref, h.context(protected: true, consent: true));
      expect(h.service.translate(ref), ManualTranslationResult.started);
      await _settle();
      expect(h.requests.length, 1);
    },
  );

  test("multiple accounts are isolated; logout clears an account", () async {
    var h = await _Harness.create();
    const refA = MessageRef("accA", "!room", "\$e");
    const refB = MessageRef("accB", "!room", "\$e");
    h.service.sync(refA, _text(original), h.context(account: "accA"));
    h.service.sync(refB, _text(original), h.context(account: "accB"));
    h.service.translate(refA);
    await _settle();
    expect(h.service.currentState(refA).hasTranslation, isTrue);
    expect(h.service.currentState(refB).hasTranslation, isFalse);

    await h.settings.setRoomSettings(
      "accA",
      "!room",
      const TranslationScopeSettings(mode: TranslationMode.enabled),
    );
    await h.service.onAccountRemoved("accA");
    expect(h.service.cache.length, 0);
    expect(h.service.isKnown(refA), isFalse);
    expect(
      h.settings.roomSettings("accA", "!room").mode,
      TranslationMode.inherit,
    );
  });

  test("API key never stored in preferences or cache", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();
    for (var key in h.prefs.getKeys()) {
      expect("${h.prefs.get(key)}", isNot(contains(_apiKey)), reason: key);
    }
    expect(h.service.provider!.identity, isNot(contains(_apiKey)));
    expect(h.service.apiKeyStorage, ApiKeyStorage.secure);
  });

  test("keyring unavailable: key is kept for the session only", () async {
    var h = await _Harness.create(credentials: _ThrowingCredentialStore());
    expect(h.service.apiKeyStorage, ApiKeyStorage.sessionOnly);
    expect(h.service.isEnabled, isTrue);
    for (var key in h.prefs.getKeys()) {
      expect("${h.prefs.get(key)}", isNot(contains(_apiKey)));
    }
  });

  test("connection test verifies health and API key", () async {
    var h = await _Harness.create();
    var ok = await h.service.testConnection();
    expect(ok.success, isTrue);
    expect(ok.model, "m");
    expect(h.settings.cachedLanguages.keys, containsAll(["en", "sv", "es"]));

    var bad = await h.service.testConnection(apiKey: "wrong");
    expect(bad.success, isFalse);
    expect(bad.failedStep, ConnectionTestStep.authentication);

    var badUrl = await h.service.testConnection(serverUrl: "http://insecure");
    expect(badUrl.failedStep, ConnectionTestStep.url);
  });

  test("clearing the cache forgets translations", () async {
    var h = await _Harness.create();
    h.service.sync(ref, _text(original), h.context());
    h.service.translate(ref);
    await _settle();
    expect(h.service.cache.length, 1);
    h.service.clearCache();
    expect(h.service.cache.length, 0);
  });

  test("original content is never mutated", () async {
    var h = await _Harness.create();
    var extraction = _text(original);
    h.service.sync(ref, extraction, h.context());
    h.service.translate(ref);
    await _settle();
    expect(extraction.content!.text, original);
  });

  test(
    "all visible messages get translated without further scrolling",
    () async {
      var h = await _Harness.create();
      var refs = [
        for (var i = 0; i < 15; i++) MessageRef("acc", "!room", "\$v$i"),
      ];
      for (var r in refs) {
        h.service.sync(
          r,
          _text("mensaje visible ${r.eventId}"),
          h.context(auto: true),
        );
      }
      // Reported visible exactly once, like a user who just sits and reads.
      h.service.setVisible(Object(), refs);
      await _settle();
      await _settle();
      expect(h.requests.length, 15);
      for (var r in refs) {
        expect(
          h.service.currentState(r).hasTranslation,
          isTrue,
          reason: r.eventId,
        );
      }
    },
  );
}
