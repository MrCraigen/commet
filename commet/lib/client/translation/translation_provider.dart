/// Core types shared by every translation provider.
///
/// Translation is strictly a client-side presentation feature: providers only
/// ever receive the text to translate plus the source and target language.
/// No Matrix identifiers, tokens or metadata may be passed to a provider.
library;

/// Language code meaning "let the backend detect the source language".
const String translationAutoSource = "auto";

/// Classified failure categories. These drive both retry behaviour in the
/// scheduler and the (localized) explanation shown to the user.
enum TranslationErrorKind {
  /// Server unreachable: DNS, connection refused, reset, proxy timeout etc.
  unavailable,

  /// TLS handshake / certificate validation failed. Never bypassed.
  tls,

  /// The client gave up waiting. The backend may still be busy with the
  /// request, cancellation of the HTTP request does not cancel inference.
  timeout,

  /// 401 - missing or invalid API key.
  authentication,

  /// 429 - the backend queue is full.
  queueFull,

  /// 400 - the request was rejected.
  invalidRequest,

  /// 422 - validation failure, most often an unsupported source language.
  unsupportedLanguage,

  /// The text exceeds the provider's maximum length.
  tooLong,

  /// 502 / 503 / 504 - the backend failed to produce a translation.
  backendFailure,

  /// The response could not be understood, or the model output failed the
  /// client side safety checks.
  invalidResponse,

  /// Translation is not configured (no URL / key).
  notConfigured,

  /// Anything else (unexpected status codes, redirects, ...).
  unknown,
}

extension TranslationErrorKindRetry on TranslationErrorKind {
  /// Whether a failure of this kind may succeed if simply tried again later.
  bool get isRetryable => switch (this) {
    TranslationErrorKind.unavailable => true,
    TranslationErrorKind.timeout => true,
    TranslationErrorKind.queueFull => true,
    TranslationErrorKind.backendFailure => true,
    _ => false,
  };

  /// Failures which affect every request, not just the current message.
  /// When these occur the scheduler pauses automatic translation.
  bool get isServiceWide => switch (this) {
    TranslationErrorKind.authentication => true,
    TranslationErrorKind.tls => true,
    TranslationErrorKind.notConfigured => true,
    _ => false,
  };
}

/// Exception thrown by providers. Deliberately contains no request content,
/// no headers and no server supplied text so it can never leak message
/// contents or credentials into logs.
class TranslationException implements Exception {
  final TranslationErrorKind kind;
  final int? statusCode;
  final Duration? retryAfter;

  const TranslationException(this.kind, {this.statusCode, this.retryAfter});

  @override
  String toString() =>
      "TranslationException(${kind.name}${statusCode != null ? ", status $statusCode" : ""})";
}

class TranslationRequest {
  final String text;
  final String source;
  final String target;

  const TranslationRequest({
    required this.text,
    required this.source,
    required this.target,
  });

  @override
  String toString() =>
      "TranslationRequest(source: $source, target: $target, length: ${text.runes.length})";
}

class TranslationResult {
  final String translation;

  /// Detected (or explicitly requested) source language, if reported.
  final String? source;
  final String target;

  /// False when the text was already in the target language.
  final bool translated;
  final bool cached;
  final Duration? duration;

  const TranslationResult({
    required this.translation,
    required this.source,
    required this.target,
    required this.translated,
    this.cached = false,
    this.duration,
  });
}

class TranslationServerInfo {
  final String status;
  final String? model;
  final String? version;

  const TranslationServerInfo({required this.status, this.model, this.version});

  bool get isOk => status == "ok";
}

abstract class TranslationProvider {
  /// Stable identifier for this provider configuration, used as part of the
  /// cache identity so results from a different provider / model / version
  /// are never reused. Must not contain credentials.
  String get identity;

  /// Maximum input length in Unicode code points.
  int get maxInputCodePoints;

  Future<TranslationServerInfo> health();

  /// Supported languages as code -> display name.
  Future<Map<String, String>> languages();

  Future<TranslationResult> translate(TranslationRequest request);

  void close();
}
