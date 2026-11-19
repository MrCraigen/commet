import 'dart:async';
import 'dart:collection';

import 'package:commet/client/translation/http_translation_provider.dart';
import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:commet/client/translation/translation_scheduler.dart';
import 'package:commet/client/translation/translation_settings.dart';
import 'package:flutter/foundation.dart';

enum MessageTranslationStatus {
  /// Nothing requested (yet).
  idle,

  /// Waiting in the scheduler queue.
  queued,

  /// Request sent, waiting for the server.
  inProgress,

  translated,

  /// The message is already in the target language.
  sameLanguage,

  failed,

  /// The message can not be translated (see [MessageTranslationState.skipReason]).
  unsupported,
}

@immutable
class MessageTranslationState {
  final MessageTranslationStatus status;
  final String? translatedText;
  final String? detectedSource;
  final String? targetLanguage;
  final TranslationErrorKind? error;
  final TranslationSkipReason? skipReason;

  /// The user asked to see the original text instead of the translation.
  final bool showOriginal;

  /// The user explicitly requested this translation (as opposed to the room
  /// translating automatically). Controls how prominently progress and
  /// failures are shown.
  final bool manual;

  const MessageTranslationState({
    this.status = MessageTranslationStatus.idle,
    this.translatedText,
    this.detectedSource,
    this.targetLanguage,
    this.error,
    this.skipReason,
    this.showOriginal = false,
    this.manual = false,
  });

  static const MessageTranslationState initial = MessageTranslationState();

  bool get hasTranslation =>
      status == MessageTranslationStatus.translated && translatedText != null;

  /// Whether the translated text should currently replace the original.
  bool get displaysTranslation => hasTranslation && !showOriginal;

  bool get isBusy =>
      status == MessageTranslationStatus.queued ||
      status == MessageTranslationStatus.inProgress;

  @override
  bool operator ==(Object other) =>
      other is MessageTranslationState &&
      other.status == status &&
      other.translatedText == translatedText &&
      other.detectedSource == detectedSource &&
      other.targetLanguage == targetLanguage &&
      other.error == error &&
      other.skipReason == skipReason &&
      other.showOriginal == showOriginal &&
      other.manual == manual;

  @override
  int get hashCode => Object.hash(
    status,
    translatedText,
    detectedSource,
    targetLanguage,
    error,
    skipReason,
    showOriginal,
    manual,
  );

  MessageTranslationState copyWith({
    MessageTranslationStatus? status,
    String? Function()? translatedText,
    String? Function()? detectedSource,
    String? Function()? targetLanguage,
    TranslationErrorKind? Function()? error,
    TranslationSkipReason? Function()? skipReason,
    bool? showOriginal,
    bool? manual,
  }) => MessageTranslationState(
    status: status ?? this.status,
    translatedText: translatedText != null
        ? translatedText()
        : this.translatedText,
    detectedSource: detectedSource != null
        ? detectedSource()
        : this.detectedSource,
    targetLanguage: targetLanguage != null
        ? targetLanguage()
        : this.targetLanguage,
    error: error != null ? error() : this.error,
    skipReason: skipReason != null ? skipReason() : this.skipReason,
    showOriginal: showOriginal ?? this.showOriginal,
    manual: manual ?? this.manual,
  );
}

/// Policy information needed to translate messages of a room.
class TranslationRoomContext {
  final String accountId;
  final String roomId;
  final EffectiveTranslationPolicy policy;

  const TranslationRoomContext({
    required this.accountId,
    required this.roomId,
    required this.policy,
  });
}

/// Outcome of a manual translation request, for user facing feedback.
enum ManualTranslationResult {
  started,
  alreadyAvailable,
  unsupported,
  needsPrivacyConsent,
  serviceDisabled,
  unknownMessage,
}

enum ConnectionTestStep { url, reachability, health, authentication, languages }

class ConnectionTestResult {
  final bool success;
  final ConnectionTestStep? failedStep;
  final TranslationErrorKind? error;
  final String? model;
  final String? version;
  final Map<String, String> languages;

  const ConnectionTestResult({
    required this.success,
    this.failedStep,
    this.error,
    this.model,
    this.version,
    this.languages = const {},
  });
}

enum ApiKeyStorage { none, secure, sessionOnly }

typedef TranslationProviderFactory = TranslationProvider Function(
  Uri baseUri,
  String apiKey, {
  String? model,
  String? version,
});

class _Entry {
  final MessageRef ref;
  final _StateNotifier notifier;
  TranslationRoomContext? context;
  TranslatableExtraction? extraction;
  TranslationKey? key;

  _Entry(this.ref) : notifier = _StateNotifier();

  TranslatableContent? get content => extraction?.content;
}

class _StateNotifier extends ValueNotifier<MessageTranslationState> {
  _StateNotifier() : super(MessageTranslationState.initial);

  bool disposed = false;

  void set(MessageTranslationState next) {
    if (disposed) return;
    value = next;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// Facade owning all translation state. One instance for the app; all state
/// is partitioned by Matrix account.
class TranslationService {
  final TranslationSettingsStore settings;
  final TranslationCredentialStore _secureCredentials;
  final TranslationCredentialStore _sessionCredentials =
      MemoryTranslationCredentialStore();
  final TranslationProviderFactory _providerFactory;

  final TranslationCache cache;
  late final TranslationScheduler scheduler;

  String? _apiKey;
  ApiKeyStorage _apiKeyStorage = ApiKeyStorage.none;
  TranslationProvider? _provider;

  final Map<MessageRef, _Entry> _entries = {};
  final Map<MessageRef, ({String? target, String? source})> _overrides = {};
  final Set<MessageRef> _manualRequests = {};
  final LinkedHashMap<
    TranslationKey,
    ({TranslationErrorKind kind, DateTime at})
  >
  _failures = LinkedHashMap();

  /// Retryable failures (server offline, queue full...) are remembered for
  /// this long, so automatic translation resumes once the server recovers
  /// without hammering it in the meantime.
  final Duration retryableFailureMemory;

  String? _providerConfig;
  final Map<TranslationKey, TranslatableContent> _inFlightContent = {};
  final Map<Object, List<MessageRef>> _visible = {};

  final StreamController<void> _policyChanged = StreamController.broadcast();

  /// Fires whenever settings that affect what should be displayed changed:
  /// languages, room / space policies, provider, cache cleared...
  Stream<void> get onPolicyChanged => _policyChanged.stream;

  int _policyGeneration = 0;
  int get policyGeneration => _policyGeneration;

  StreamSubscription? _settingsSub;

  TranslationService({
    required this.settings,
    required TranslationCredentialStore credentials,
    TranslationProviderFactory? providerFactory,
    TranslationCache? cache,
    int maxQueued = 6,
    Duration baseBackoff = const Duration(seconds: 2),
    this.retryableFailureMemory = const Duration(minutes: 5),
  }) : _secureCredentials = credentials,
       _providerFactory = providerFactory ?? _defaultProviderFactory,
       cache = cache ?? TranslationCache() {
    scheduler = TranslationScheduler(
      execute: _execute,
      onUpdate: _onSchedulerUpdate,
      maxQueued: maxQueued,
      baseBackoff: baseBackoff,
    );
    _settingsSub = settings.onChanged.listen((_) => _onSettingsChanged());
  }

  static TranslationProvider _defaultProviderFactory(
    Uri baseUri,
    String apiKey, {
    String? model,
    String? version,
  }) => HttpTranslationProvider(
    baseUri: baseUri,
    apiKey: apiKey,
    model: model,
    version: version,
  );

  Future<void> init() async {
    try {
      // A locked / unresponsive keyring must not stall startup.
      _apiKey = await _secureCredentials.readApiKey().timeout(
        const Duration(seconds: 5),
      );
      if (_apiKey != null && _apiKey!.isNotEmpty) {
        _apiKeyStorage = ApiKeyStorage.secure;
      }
    } catch (_) {
      // Keyring unavailable; the user will need to re-enter the key.
      _apiKey = null;
    }
    _rebuildProvider();
  }

  // ---------------------------------------------------------------------------
  // Configuration

  Uri? get serverUri =>
      HttpTranslationProvider.parseServerUrl(settings.serverUrl);

  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  ApiKeyStorage get apiKeyStorage => _apiKeyStorage;

  bool get isConfigured => serverUri != null && hasApiKey;

  /// Master switch on and fully configured.
  bool get isEnabled => settings.enabled && isConfigured;

  TranslationProvider? get provider => _provider;

  TranslationErrorKind? get blockedBy => scheduler.blockedBy;

  /// Stores the API key in the platform keyring. If no keyring is available
  /// the key is only kept in memory for this session; it is never written
  /// to plaintext preferences.
  Future<ApiKeyStorage> setApiKey(String key) async {
    key = key.trim();
    if (key.isEmpty) {
      await clearApiKey();
      return ApiKeyStorage.none;
    }
    try {
      await _secureCredentials.writeApiKey(key);
      _apiKeyStorage = ApiKeyStorage.secure;
    } catch (_) {
      await _sessionCredentials.writeApiKey(key);
      _apiKeyStorage = ApiKeyStorage.sessionOnly;
    }
    _apiKey = key;
    _onConfigurationChanged();
    return _apiKeyStorage;
  }

  Future<void> clearApiKey() async {
    try {
      await _secureCredentials.deleteApiKey();
    } catch (_) {}
    await _sessionCredentials.deleteApiKey();
    _apiKey = null;
    _apiKeyStorage = ApiKeyStorage.none;
    _onConfigurationChanged();
  }

  /// Verifies URL, reachability + TLS, health, API key and language list.
  /// Uses the stored configuration unless overrides are given.
  Future<ConnectionTestResult> testConnection({
    String? serverUrl,
    String? apiKey,
  }) async {
    var uri = HttpTranslationProvider.parseServerUrl(
      serverUrl ?? settings.serverUrl,
    );
    if (uri == null) {
      return const ConnectionTestResult(
        success: false,
        failedStep: ConnectionTestStep.url,
        error: TranslationErrorKind.notConfigured,
      );
    }

    var key = apiKey ?? _apiKey ?? "";
    var provider = _providerFactory(uri, key);
    try {
      TranslationServerInfo info;
      try {
        info = await provider.health();
      } on TranslationException catch (e) {
        return ConnectionTestResult(
          success: false,
          failedStep:
              e.kind == TranslationErrorKind.invalidResponse ||
                  e.kind == TranslationErrorKind.backendFailure
              ? ConnectionTestStep.health
              : ConnectionTestStep.reachability,
          error: e.kind,
        );
      }

      if (!info.isOk) {
        return ConnectionTestResult(
          success: false,
          failedStep: ConnectionTestStep.health,
          error: TranslationErrorKind.backendFailure,
          model: info.model,
          version: info.version,
        );
      }

      if (key.isEmpty) {
        return ConnectionTestResult(
          success: false,
          failedStep: ConnectionTestStep.authentication,
          error: TranslationErrorKind.notConfigured,
          model: info.model,
          version: info.version,
        );
      }

      Map<String, String> languages;
      try {
        languages = await provider.languages();
      } on TranslationException catch (e) {
        return ConnectionTestResult(
          success: false,
          failedStep: e.kind == TranslationErrorKind.authentication
              ? ConnectionTestStep.authentication
              : ConnectionTestStep.languages,
          error: e.kind,
          model: info.model,
          version: info.version,
        );
      }

      // Only persist results for the configuration actually in use.
      if (serverUrl == null || serverUrl.trim() == settings.serverUrl.trim()) {
        await settings.setCachedLanguages(languages);
        await settings.setServerInfo(info.model, info.version);
        _failures.clear();
        scheduler.reset();
        _onConfigurationChanged();
      }

      return ConnectionTestResult(
        success: true,
        model: info.model,
        version: info.version,
        languages: languages,
      );
    } finally {
      provider.close();
    }
  }

  /// Languages known from the last successful connection test.
  Map<String, String> get languages => settings.cachedLanguages;

  String languageName(String? code) {
    if (code == null) return "";
    return languages[code] ?? code;
  }

  // ---------------------------------------------------------------------------
  // Per message state

  ValueListenable<MessageTranslationState> watch(MessageRef ref) =>
      _entryFor(ref).notifier;

  MessageTranslationState stateOf(MessageRef ref) =>
      _entries[ref]?.notifier.value ?? MessageTranslationState.initial;

  bool isKnown(MessageRef ref) => _entries[ref]?.extraction != null;

  TranslationRoomContext? contextOf(MessageRef ref) => _entries[ref]?.context;

  ({String? target, String? source})? overrideFor(MessageRef ref) =>
      _overrides[ref];

  _Entry _entryFor(MessageRef ref) => _entries.putIfAbsent(ref, () {
    _pruneEntries();
    return _Entry(ref);
  });

  void _pruneEntries() {
    if (_entries.length < 4000) return;
    // Drop entries nobody listens to any more.
    _entries.removeWhere((ref, entry) {
      // ignore: invalid_use_of_protected_member
      var unused = !entry.notifier.hasListeners;
      if (unused) {
        entry.notifier.dispose();
        _manualRequests.remove(ref);
        _overrides.remove(ref);
      }
      return unused;
    });
  }

  /// Called by the message widget whenever its content or room context may
  /// have changed. Cheap when nothing changed.
  void sync(
    MessageRef ref,
    TranslatableExtraction extraction,
    TranslationRoomContext context,
  ) {
    var entry = _entryFor(ref);
    entry.extraction = extraction;
    entry.context = context;
    _resolve(entry);
  }

  TranslationKey? _keyFor(_Entry entry) {
    var content = entry.content;
    var context = entry.context;
    var provider = _provider;
    if (content == null || context == null || provider == null) return null;

    var override = _overrides[entry.ref];
    return TranslationKey(
      accountId: entry.ref.accountId,
      roomId: entry.ref.roomId,
      eventId: entry.ref.eventId,
      contentHash: content.contentHash,
      sourceLanguage: override?.source ?? context.policy.sourceLanguage,
      targetLanguage: override?.target ?? context.policy.targetLanguage,
      providerIdentity: provider.identity,
    );
  }

  bool _autoEligible(_Entry entry) =>
      isEnabled && entry.context?.policy.autoTranslate == true;

  void _resolve(_Entry entry, {bool force = false}) {
    var current = entry.notifier.value;
    var manual = _manualRequests.contains(entry.ref);

    if (!isEnabled) {
      entry.key = null;
      _setState(
        entry,
        MessageTranslationState(showOriginal: current.showOriginal),
      );
      return;
    }

    var extraction = entry.extraction;
    if (extraction == null) return;

    if (!extraction.isEligible) {
      if (entry.key != null) {
        // Edited / redacted into something untranslatable: drop any old
        // translation of this event.
        cache.clearEvent(entry.ref);
      }
      entry.key = null;
      _setState(
        entry,
        MessageTranslationState(
          status: MessageTranslationStatus.unsupported,
          skipReason: extraction.skipReason,
          manual: manual,
          showOriginal: current.showOriginal,
        ),
      );
      return;
    }

    var key = _keyFor(entry);
    if (key == null) return;
    if (!force && key == entry.key) return;
    entry.key = key;

    var cached = cache.get(key);
    if (cached != null) {
      _setState(entry, _stateFromCache(key, cached, current, manual));
      return;
    }

    var failure = _activeFailure(key);
    if (failure != null) {
      _setState(
        entry,
        MessageTranslationState(
          status: MessageTranslationStatus.failed,
          error: failure,
          targetLanguage: key.targetLanguage,
          manual: manual,
          showOriginal: current.showOriginal,
        ),
      );
      return;
    }

    if (scheduler.isPending(key)) {
      if (manual) _requestManual(entry, key);
      _setState(
        entry,
        current.copyWith(
          status: MessageTranslationStatus.queued,
          manual: manual,
          targetLanguage: () => key.targetLanguage,
        ),
      );
      return;
    }

    _setState(
      entry,
      MessageTranslationState(
        status: MessageTranslationStatus.idle,
        manual: manual,
        targetLanguage: key.targetLanguage,
        showOriginal: current.showOriginal,
      ),
    );

    if (manual) {
      _requestManual(entry, key);
    } else if (_autoEligible(entry)) {
      // Visible messages are handed to the scheduler by the visibility
      // tracker; re-submit in case this message is already visible.
      _resubmitVisibleFor(entry.ref);
    }
  }

  MessageTranslationState _stateFromCache(
    TranslationKey key,
    CachedTranslation cached,
    MessageTranslationState current,
    bool manual,
  ) {
    if (cached.isSameLanguage) {
      return MessageTranslationState(
        status: MessageTranslationStatus.sameLanguage,
        detectedSource: cached.detectedSource,
        targetLanguage: key.targetLanguage,
        manual: manual,
      );
    }
    return MessageTranslationState(
      status: MessageTranslationStatus.translated,
      translatedText: cached.text,
      detectedSource: cached.detectedSource,
      targetLanguage: key.targetLanguage,
      manual: manual,
      showOriginal: current.showOriginal,
    );
  }

  void _setState(_Entry entry, MessageTranslationState state) {
    var notifier = entry.notifier;
    if (notifier.disposed) return;
    var ref = entry.ref;
    _pendingValues[ref] = state;
    // Notify asynchronously: this may run during a build phase.
    scheduleMicrotask(() {
      notifier.set(state);
      if (identical(_pendingValues[ref], state)) _pendingValues.remove(ref);
    });
  }

  // Latest state not yet flushed by the microtask, so synchronous reads are
  // consistent within the same frame.
  final Map<MessageRef, MessageTranslationState> _pendingValues = {};

  /// Current state including changes not yet delivered to listeners.
  MessageTranslationState currentState(MessageRef ref) =>
      _pendingValues[ref] ?? stateOf(ref);

  /// Manually translate a message, optionally to a specific language pair.
  ManualTranslationResult translate(
    MessageRef ref, {
    String? targetLanguage,
    String? sourceLanguage,
  }) {
    if (!isEnabled) return ManualTranslationResult.serviceDisabled;

    var entry = _entries[ref];
    if (entry == null || entry.extraction == null || entry.context == null) {
      return ManualTranslationResult.unknownMessage;
    }

    if (!entry.context!.policy.manualAllowed) {
      return ManualTranslationResult.needsPrivacyConsent;
    }

    if (!entry.extraction!.isEligible) {
      return ManualTranslationResult.unsupported;
    }

    if (targetLanguage != null || sourceLanguage != null) {
      _overrides[ref] = (target: targetLanguage, source: sourceLanguage);
    }

    _manualRequests.add(ref);

    var key = _keyFor(entry);
    if (key == null) return ManualTranslationResult.serviceDisabled;

    // A manual retry clears any remembered failure.
    _failures.remove(key);

    entry.key = null;
    var before = cache.get(key);
    _resolve(entry, force: true);

    // Make sure the translation (not the original) is shown.
    var state = currentState(ref);
    if (state.showOriginal) {
      _setState(entry, state.copyWith(showOriginal: false));
    }

    return before != null
        ? ManualTranslationResult.alreadyAvailable
        : ManualTranslationResult.started;
  }

  /// Retry a failed translation.
  ManualTranslationResult retry(MessageRef ref) => translate(ref);

  /// Toggle between original and translated text. Never makes a request.
  void setShowOriginal(MessageRef ref, bool showOriginal) {
    var entry = _entries[ref];
    if (entry == null) return;
    _setState(entry, currentState(ref).copyWith(showOriginal: showOriginal));
  }

  void _requestManual(_Entry entry, TranslationKey key) {
    var content = entry.content;
    if (content == null) return;
    _inFlightContent[key] = content;
    scheduler.requestManual(key, content);
  }

  // ---------------------------------------------------------------------------
  // Visibility driven automatic translation

  /// Report the messages currently visible in a timeline view, ordered by
  /// relevance (most relevant first). Replaces the previous report from
  /// [owner].
  void setVisible(Object owner, List<MessageRef> refs) {
    _visible[owner] = refs;
    _submitVisible(owner);
  }

  void removeVisibilityOwner(Object owner) {
    _visible.remove(owner);
    scheduler.removeOwner(owner);
  }

  void _resubmitVisibleFor(MessageRef ref) {
    for (var entry in _visible.entries) {
      if (entry.value.contains(ref)) {
        _submitVisible(entry.key);
      }
    }
  }

  void _submitVisible(Object owner) {
    var refs = _visible[owner] ?? const [];
    var jobs = <(TranslationKey, TranslatableContent)>[];

    if (isEnabled) {
      for (var ref in refs) {
        var entry = _entries[ref];
        if (entry == null || !_autoEligible(entry)) continue;
        var key = entry.key;
        var content = entry.content;
        if (key == null || content == null) continue;
        if (cache.get(key) != null || _activeFailure(key) != null) continue;
        _inFlightContent[key] = content;
        jobs.add((key, content));
      }
    }

    scheduler.updateVisible(owner, jobs);
  }

  // ---------------------------------------------------------------------------
  // Scheduler integration

  Future<TranslationResult> _execute(TranslationRequest request) {
    var provider = _provider;
    if (provider == null || !isEnabled) {
      return Future.error(
        const TranslationException(TranslationErrorKind.notConfigured),
      );
    }
    return provider.translate(request);
  }

  void _onSchedulerUpdate(TranslationKey key, TranslationJobUpdate update) {
    switch (update) {
      case TranslationJobQueued():
        _updateEntriesFor(
          key,
          (s) => s.copyWith(status: MessageTranslationStatus.queued),
        );
      case TranslationJobStarted():
        _updateEntriesFor(
          key,
          (s) => s.copyWith(status: MessageTranslationStatus.inProgress),
        );
      case TranslationJobCancelled():
        _inFlightContent.remove(key);
        _updateEntriesFor(
          key,
          (s) =>
              s.isBusy ? s.copyWith(status: MessageTranslationStatus.idle) : s,
        );
      case TranslationJobSucceeded(:var result):
        _onSuccess(key, result);
      case TranslationJobFailed(:var kind):
        _inFlightContent.remove(key);
        _recordFailure(key, kind);
    }
  }

  TranslationErrorKind? _activeFailure(TranslationKey key) {
    var failure = _failures[key];
    if (failure == null) return null;
    if (failure.kind.isRetryable &&
        DateTime.now().difference(failure.at) > retryableFailureMemory) {
      _failures.remove(key);
      return null;
    }
    return failure.kind;
  }

  void _recordFailure(TranslationKey key, TranslationErrorKind kind) {
    _failures[key] = (kind: kind, at: DateTime.now());
    while (_failures.length > 1000) {
      _failures.remove(_failures.keys.first);
    }
    _updateEntriesFor(
      key,
      (s) => s.copyWith(
        status: MessageTranslationStatus.failed,
        error: () => kind,
      ),
    );
  }

  void _onSuccess(TranslationKey key, TranslationResult result) {
    var content = _inFlightContent.remove(key);
    if (content == null) return;

    CachedTranslation cached;
    var sameLanguage =
        !result.translated ||
        (result.source != null && result.source == key.targetLanguage) ||
        result.translation.trim() == content.text.trim();

    if (sameLanguage) {
      cached = CachedTranslation(text: null, detectedSource: result.source);
    } else {
      var sanitized = TranslationOutputSanitizer.sanitize(
        result.translation,
        content,
      );
      if (!sanitized.isOk) {
        _recordFailure(key, TranslationErrorKind.invalidResponse);
        return;
      }
      cached = CachedTranslation(
        text: sanitized.text,
        detectedSource: result.source,
      );
    }

    cache.put(key, cached);
    _updateEntriesFor(key, (s) => _stateFromCache(key, cached, s, s.manual));
  }

  void _updateEntriesFor(
    TranslationKey key,
    MessageTranslationState Function(MessageTranslationState) update,
  ) {
    var entry = _entries[key.message];
    if (entry == null || entry.key != key) return;
    _setState(entry, update(currentState(entry.ref)));
  }

  // ---------------------------------------------------------------------------
  // Invalidation

  void _onSettingsChanged() {
    _rebuildProvider();
    _invalidateAll();
  }

  void _onConfigurationChanged() {
    _rebuildProvider();
    _invalidateAll();
  }

  void _rebuildProvider() {
    var uri = serverUri;
    var key = _apiKey;
    if (uri == null || key == null || key.isEmpty) {
      _provider?.close();
      _provider = null;
      _providerConfig = null;
      return;
    }

    var identity = HttpTranslationProvider.identityFor(
      uri,
      model: settings.serverModel,
      version: settings.serverVersion,
    );
    var config = "$identity\u0000$key";
    if (_provider != null && _providerConfig == config) {
      return;
    }

    _provider?.close();
    _providerConfig = config;
    _provider = _providerFactory(
      uri,
      key,
      model: settings.serverModel,
      version: settings.serverVersion,
    );
    // New configuration: forget blocks and failures caused by the old one.
    _failures.clear();
    scheduler.reset();
  }

  void _invalidateAll() {
    _policyGeneration++;
    if (!isEnabled) {
      scheduler.reset();
    }
    _policyChanged.add(null);
  }

  /// Called by the room / space settings UI after a policy change, so open
  /// timelines re-resolve their policy.
  void notifyPolicyChanged() => _invalidateAll();

  /// Re-evaluate one message with an updated room context (e.g. after the
  /// policy changed).
  void refresh(MessageRef ref, TranslationRoomContext context) {
    var entry = _entries[ref];
    if (entry == null) return;
    entry.context = context;
    _resolve(entry, force: true);
  }

  /// Clear the local translation cache. Does not touch the server cache.
  void clearCache() {
    cache.clear();
    _failures.clear();
    _inFlightContent.clear();
    scheduler.reset();
    for (var entry in _entries.values) {
      entry.key = null;
    }
    _invalidateAll();
  }

  /// Remove all translation state belonging to an account (logout).
  Future<void> onAccountRemoved(String accountId) async {
    cache.clearAccount(accountId);
    _failures.removeWhere((k, _) => k.accountId == accountId);
    _inFlightContent.removeWhere((k, _) => k.accountId == accountId);
    scheduler.cancelWhere((k) => k.accountId == accountId);
    _manualRequests.removeWhere((r) => r.accountId == accountId);
    _overrides.removeWhere((r, _) => r.accountId == accountId);
    _pendingValues.removeWhere((r, _) => r.accountId == accountId);
    _entries.removeWhere((ref, entry) {
      if (ref.accountId != accountId) return false;
      entry.notifier.dispose();
      return true;
    });
    await settings.clearAccount(accountId);
  }

  /// Forget a message's translation (redaction).
  void forgetMessage(MessageRef ref) {
    cache.clearEvent(ref);
    _failures.removeWhere((k, _) => k.message == ref);
    scheduler.cancelWhere((k) => k.message == ref);
    _manualRequests.remove(ref);
    _overrides.remove(ref);
    var entry = _entries.remove(ref);
    if (entry != null) {
      entry.notifier.set(MessageTranslationState.initial);
    }
    _pendingValues.remove(ref);
  }

  void dispose() {
    _settingsSub?.cancel();
    scheduler.dispose();
    _provider?.close();
  }
}
