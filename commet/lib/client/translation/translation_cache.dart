import 'dart:collection';

/// Full identity of one translation of one message.
///
/// The account, room and event identify the message locally. The content hash
/// covers edits, the language pair covers settings changes, and the provider
/// identity covers server / model / version changes. These identifiers are
/// only used locally and are never sent to the translation server.
class TranslationKey {
  final String accountId;
  final String roomId;
  final String eventId;
  final String contentHash;
  final String sourceLanguage;
  final String targetLanguage;
  final String providerIdentity;

  const TranslationKey({
    required this.accountId,
    required this.roomId,
    required this.eventId,
    required this.contentHash,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.providerIdentity,
  });

  /// Key used to deduplicate identical in-flight requests: the same text in
  /// the same language pair at the same provider yields the same result.
  String get requestKey =>
      "$providerIdentity\u0000$contentHash\u0000$sourceLanguage\u0000$targetLanguage";

  MessageRef get message => MessageRef(accountId, roomId, eventId);

  @override
  bool operator ==(Object other) =>
      other is TranslationKey &&
      other.accountId == accountId &&
      other.roomId == roomId &&
      other.eventId == eventId &&
      other.contentHash == contentHash &&
      other.sourceLanguage == sourceLanguage &&
      other.targetLanguage == targetLanguage &&
      other.providerIdentity == providerIdentity;

  @override
  int get hashCode => Object.hash(
    accountId,
    roomId,
    eventId,
    contentHash,
    sourceLanguage,
    targetLanguage,
    providerIdentity,
  );

  @override
  String toString() => "TranslationKey($sourceLanguage->$targetLanguage)";
}

/// Identifies a message independent of its content / language settings.
class MessageRef {
  final String accountId;
  final String roomId;
  final String eventId;

  const MessageRef(this.accountId, this.roomId, this.eventId);

  @override
  bool operator ==(Object other) =>
      other is MessageRef &&
      other.accountId == accountId &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(accountId, roomId, eventId);
}

/// A completed translation. Holds no credentials.
class CachedTranslation {
  /// Null when the message was already in the target language.
  final String? text;
  final String? detectedSource;

  const CachedTranslation({required this.text, this.detectedSource});

  bool get isSameLanguage => text == null;
}

/// Bounded in-memory LRU cache. Nothing is written to disk: the server keeps
/// its own persistent cache, so the client avoids storing decrypted
/// conversation content in plaintext.
class TranslationCache {
  final int capacity;
  final LinkedHashMap<TranslationKey, CachedTranslation> _entries =
      LinkedHashMap();

  TranslationCache({this.capacity = 2000});

  int get length => _entries.length;

  CachedTranslation? get(TranslationKey key) {
    var value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(TranslationKey key, CachedTranslation value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void removeWhere(bool Function(TranslationKey key) test) {
    _entries.removeWhere((k, _) => test(k));
  }

  void clearAccount(String accountId) =>
      removeWhere((k) => k.accountId == accountId);

  void clearEvent(MessageRef ref) => removeWhere((k) => k.message == ref);

  void clear() => _entries.clear();
}
