import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException, TlsException;

import 'package:commet/client/translation/translation_provider.dart';
import 'package:http/http.dart' as http;

/// Provider for the self-hosted "Matrix Translate" HTTP API
/// (FastAPI + Ollama), exposing `/health`, `/languages` and `/translate`.
///
/// Security properties:
/// * Only `https` URLs are accepted, default certificate validation is used
///   and never overridden.
/// * Redirects are never followed, so the API key can not be forwarded to an
///   unexpected host.
/// * The API key is only ever sent in the `Authorization` header.
/// * Exceptions never include request bodies, headers or response bodies.
class HttpTranslationProvider implements TranslationProvider {
  static const String providerType = "matrix-translate-api";

  /// Upper bound on response size we are willing to read.
  static const int maxResponseBytes = 256 * 1024;

  final Uri baseUri;
  final String apiKey;
  final http.Client _client;
  final bool _ownsClient;

  /// Inference can take a long time on CPU only hardware, and a cold model
  /// load was measured at ~17s. The backend itself gives up after 120s, so
  /// we wait slightly longer than that to receive its error response.
  final Duration translateTimeout;
  final Duration metadataTimeout;

  /// Backend model / version, folded into [identity] when known.
  final String? model;
  final String? version;

  @override
  final int maxInputCodePoints;

  HttpTranslationProvider({
    required this.baseUri,
    required this.apiKey,
    http.Client? client,
    this.model,
    this.version,
    this.maxInputCodePoints = 500,
    this.translateTimeout = const Duration(seconds: 130),
    this.metadataTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Parses and validates a user supplied server URL. Returns null if the
  /// URL is not an absolute https URL.
  static Uri? parseServerUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    Uri? uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != "https") return null;
    if (uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty) return null;
    // Normalise: drop query / fragment, strip trailing slashes.
    var path = uri.path;
    while (path.endsWith("/")) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: "https",
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  static String identityFor(Uri baseUri, {String? model, String? version}) =>
      "$providerType|${baseUri.toString()}|${model ?? "?"}|${version ?? "?"}";

  @override
  String get identity => identityFor(baseUri, model: model, version: version);

  Uri _endpoint(String name) {
    var segments = [...baseUri.pathSegments.where((s) => s.isNotEmpty), name];
    return baseUri.replace(pathSegments: segments);
  }

  @override
  Future<TranslationServerInfo> health() async {
    var json = await _sendJson("GET", "health", authenticated: false);
    var status = json["status"];
    if (status is! String) {
      throw const TranslationException(TranslationErrorKind.invalidResponse);
    }

    var model = json["model"];
    var version = json["version"];
    return TranslationServerInfo(
      status: status,
      model: model is String ? model : null,
      version: version is String ? version : null,
    );
  }

  @override
  Future<Map<String, String>> languages() async {
    var json = await _sendJson("GET", "languages", authenticated: true);
    var result = <String, String>{};
    for (var entry in json.entries) {
      if (entry.value is String && entry.key.isNotEmpty) {
        result[entry.key] = entry.value as String;
      }
    }
    if (result.isEmpty) {
      throw const TranslationException(TranslationErrorKind.invalidResponse);
    }
    return result;
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    if (request.text.runes.length > maxInputCodePoints) {
      throw const TranslationException(TranslationErrorKind.tooLong);
    }

    var json = await _sendJson(
      "POST",
      "translate",
      authenticated: true,
      body: {
        "text": request.text,
        "source": request.source,
        "target": request.target,
      },
    );

    var translation = json["translation"];
    var translated = json["translated"];
    if (translation is! String || translated is! bool) {
      throw const TranslationException(TranslationErrorKind.invalidResponse);
    }

    var source = json["source"];
    var target = json["target"];
    var cached = json["cached"];
    var duration = json["duration"];

    return TranslationResult(
      translation: translation,
      source: source is String ? source : null,
      target: target is String ? target : request.target,
      translated: translated,
      cached: cached is bool ? cached : false,
      duration: duration is num
          ? Duration(milliseconds: (duration * 1000).round())
          : null,
    );
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String endpoint, {
    required bool authenticated,
    Map<String, dynamic>? body,
  }) async {
    var abort = Completer<void>();
    var request = http.AbortableRequest(
      method,
      _endpoint(endpoint),
      abortTrigger: abort.future,
    );
    request.followRedirects = false;
    request.persistentConnection = true;
    request.headers["Accept"] = "application/json";
    if (authenticated) {
      if (apiKey.isEmpty) {
        throw const TranslationException(TranslationErrorKind.notConfigured);
      }
      request.headers["Authorization"] = "Bearer $apiKey";
    }
    if (body != null) {
      request.headers["Content-Type"] = "application/json";
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }

    var timeout = endpoint == "translate" ? translateTimeout : metadataTimeout;
    var timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });

    http.StreamedResponse response;
    List<int> bytes;
    try {
      // The abort trigger closes the connection; the outer timeout is a
      // fallback for clients that do not support aborting.
      var grace = const Duration(seconds: 2);
      response = await _client.send(request).timeout(timeout + grace);
      bytes = await _readLimited(response.stream).timeout(timeout + grace);
    } on http.RequestAbortedException {
      throw const TranslationException(TranslationErrorKind.timeout);
    } on HandshakeException {
      throw const TranslationException(TranslationErrorKind.tls);
    } on TlsException {
      throw const TranslationException(TranslationErrorKind.tls);
    } on SocketException {
      throw const TranslationException(TranslationErrorKind.unavailable);
    } on TimeoutException {
      throw const TranslationException(TranslationErrorKind.timeout);
    } on TranslationException {
      rethrow;
    } on http.ClientException {
      throw const TranslationException(TranslationErrorKind.unavailable);
    } catch (_) {
      // Deliberately discard the original error, it may embed request data.
      throw const TranslationException(TranslationErrorKind.unknown);
    } finally {
      timer.cancel();
    }

    var status = response.statusCode;
    if (status != 200) {
      throw TranslationException(
        _kindForStatus(status),
        statusCode: status,
        retryAfter: _parseRetryAfter(response.headers["retry-after"]),
      );
    }

    try {
      var decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // fall through
    }
    throw const TranslationException(
      TranslationErrorKind.invalidResponse,
      statusCode: 200,
    );
  }

  Future<List<int>> _readLimited(Stream<List<int>> stream) async {
    var result = <int>[];
    await for (var chunk in stream) {
      result.addAll(chunk);
      if (result.length > maxResponseBytes) {
        throw const TranslationException(TranslationErrorKind.invalidResponse);
      }
    }
    return result;
  }

  static TranslationErrorKind _kindForStatus(int status) {
    if (status >= 300 && status < 400) return TranslationErrorKind.unknown;
    return switch (status) {
      400 => TranslationErrorKind.invalidRequest,
      401 || 403 => TranslationErrorKind.authentication,
      413 => TranslationErrorKind.tooLong,
      422 => TranslationErrorKind.unsupportedLanguage,
      429 => TranslationErrorKind.queueFull,
      502 || 503 || 504 => TranslationErrorKind.backendFailure,
      _ =>
        status >= 500
            ? TranslationErrorKind.backendFailure
            : TranslationErrorKind.unknown,
    };
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    var seconds = int.tryParse(value.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds.clamp(0, 300));
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
