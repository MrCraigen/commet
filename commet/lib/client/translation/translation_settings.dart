import 'dart:async';
import 'dart:convert';

import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage for the translation API key. Implementations must keep the key
/// out of plaintext preference files.
abstract class TranslationCredentialStore {
  Future<String?> readApiKey();
  Future<void> writeApiKey(String key);
  Future<void> deleteApiKey();
}

/// Uses the platform keyring: Secret Service (KWallet / GNOME Keyring via
/// libsecret) on Linux, Keystore backed storage on Android.
class SecureTranslationCredentialStore implements TranslationCredentialStore {
  static const String _key = "commet.translation.api_key";

  final FlutterSecureStorage _storage;

  SecureTranslationCredentialStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            lOptions: LinuxOptions(),
            aOptions: AndroidOptions(),
          );

  @override
  Future<String?> readApiKey() => _storage.read(key: _key);

  @override
  Future<void> writeApiKey(String key) => _storage.write(key: _key, value: key);

  @override
  Future<void> deleteApiKey() => _storage.delete(key: _key);
}

/// In-memory store, used in tests and as a session-only fallback when no
/// platform keyring is available.
class MemoryTranslationCredentialStore implements TranslationCredentialStore {
  String? _value;

  @override
  Future<String?> readApiKey() async => _value;

  @override
  Future<void> writeApiKey(String key) async => _value = key;

  @override
  Future<void> deleteApiKey() async => _value = null;
}

/// Non-secret translation settings, persisted locally in shared preferences.
/// Nothing here is ever published to Matrix.
class TranslationSettingsStore {
  static const String _prefix = "translation.";
  static const String _enabledKey = "${_prefix}enabled";
  static const String _serverUrlKey = "${_prefix}server_url";
  static const String _targetKey = "${_prefix}target_language";
  static const String _sourceKey = "${_prefix}source_language";
  static const String _autoDefaultKey = "${_prefix}auto_by_default";
  static const String _modelKey = "${_prefix}server_model";
  static const String _versionKey = "${_prefix}server_version";
  static const String _languagesKey = "${_prefix}languages";
  static String _roomsKey(String accountId) => "${_prefix}rooms.$accountId";
  static String _spacesKey(String accountId) => "${_prefix}spaces.$accountId";

  final SharedPreferences _prefs;
  final Map<String, Map<String, TranslationScopeSettings>> _roomCache = {};
  final Map<String, Map<String, TranslationScopeSettings>> _spaceCache = {};

  final StreamController<void> _changed = StreamController.broadcast();
  Stream<void> get onChanged => _changed.stream;

  TranslationSettingsStore(this._prefs);

  bool get enabled => _prefs.getBool(_enabledKey) ?? false;
  Future<void> setEnabled(bool v) => _setBool(_enabledKey, v);

  String get serverUrl => _prefs.getString(_serverUrlKey) ?? "";
  Future<void> setServerUrl(String v) => _setString(_serverUrlKey, v);

  /// Used until the user picks a target language (usually the UI locale).
  String defaultTargetLanguage = "en";

  String get targetLanguage =>
      _prefs.getString(_targetKey) ?? defaultTargetLanguage;
  Future<void> setTargetLanguage(String v) => _setString(_targetKey, v);

  String get sourceLanguage =>
      _prefs.getString(_sourceKey) ?? translationAutoSource;
  Future<void> setSourceLanguage(String v) => _setString(_sourceKey, v);

  /// Global automatic translation fallback, off unless explicitly enabled.
  bool get autoTranslateByDefault => _prefs.getBool(_autoDefaultKey) ?? false;
  Future<void> setAutoTranslateByDefault(bool v) =>
      _setBool(_autoDefaultKey, v);

  String? get serverModel => _prefs.getString(_modelKey);
  String? get serverVersion => _prefs.getString(_versionKey);

  Future<void> setServerInfo(String? model, String? version) async {
    if (model == null) {
      await _prefs.remove(_modelKey);
    } else {
      await _prefs.setString(_modelKey, model);
    }
    if (version == null) {
      await _prefs.remove(_versionKey);
    } else {
      await _prefs.setString(_versionKey, version);
    }
    _changed.add(null);
  }

  /// Last language list retrieved from the server, so pickers work while
  /// the server is offline. The server remains the source of truth.
  Map<String, String> get cachedLanguages {
    var raw = _prefs.getString(_languagesKey);
    if (raw == null) return const {};
    try {
      var json = jsonDecode(raw);
      if (json is Map) {
        return {
          for (var e in json.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        };
      }
    } catch (_) {}
    return const {};
  }

  Future<void> setCachedLanguages(Map<String, String> languages) async {
    await _prefs.setString(_languagesKey, jsonEncode(languages));
    _changed.add(null);
  }

  GlobalTranslationDefaults get globalDefaults => GlobalTranslationDefaults(
    serviceEnabled: enabled,
    autoTranslateByDefault: autoTranslateByDefault,
    targetLanguage: targetLanguage,
    sourceLanguage: sourceLanguage,
  );

  TranslationScopeSettings roomSettings(String accountId, String roomId) =>
      _scopes(_roomCache, _roomsKey(accountId))[roomId] ??
      TranslationScopeSettings.empty;

  TranslationScopeSettings spaceSettings(String accountId, String spaceId) =>
      _scopes(_spaceCache, _spacesKey(accountId))[spaceId] ??
      TranslationScopeSettings.empty;

  Future<void> setRoomSettings(
    String accountId,
    String roomId,
    TranslationScopeSettings settings,
  ) => _setScope(_roomCache, _roomsKey(accountId), roomId, settings);

  Future<void> setSpaceSettings(
    String accountId,
    String spaceId,
    TranslationScopeSettings settings,
  ) => _setScope(_spaceCache, _spacesKey(accountId), spaceId, settings);

  /// Remove all per-room / per-space settings of an account.
  Future<void> clearAccount(String accountId) async {
    _roomCache.remove(_roomsKey(accountId));
    _spaceCache.remove(_spacesKey(accountId));
    await _prefs.remove(_roomsKey(accountId));
    await _prefs.remove(_spacesKey(accountId));
    _changed.add(null);
  }

  Map<String, TranslationScopeSettings> _scopes(
    Map<String, Map<String, TranslationScopeSettings>> cache,
    String key,
  ) {
    return cache.putIfAbsent(key, () {
      var raw = _prefs.getString(key);
      if (raw == null) return {};
      try {
        var json = jsonDecode(raw);
        if (json is! Map) return {};
        return {
          for (var e in json.entries)
            if (e.key is String && e.value is Map<String, dynamic>)
              e.key as String: TranslationScopeSettings.fromJson(
                e.value as Map<String, dynamic>,
              ),
        };
      } catch (_) {
        return {};
      }
    });
  }

  Future<void> _setScope(
    Map<String, Map<String, TranslationScopeSettings>> cache,
    String key,
    String id,
    TranslationScopeSettings settings,
  ) async {
    var map = _scopes(cache, key);
    if (settings.isEmpty) {
      map.remove(id);
    } else {
      map[id] = settings;
    }
    await _prefs.setString(
      key,
      jsonEncode({for (var e in map.entries) e.key: e.value.toJson()}),
    );
    _changed.add(null);
  }

  Future<void> _setBool(String key, bool v) async {
    await _prefs.setBool(key, v);
    _changed.add(null);
  }

  Future<void> _setString(String key, String v) async {
    await _prefs.setString(key, v);
    _changed.add(null);
  }
}
