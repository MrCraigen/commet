import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commet/client/translation/http_translation_provider.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _secret = "s3cr3t-api-key";

HttpTranslationProvider _provider(
  MockClientHandler handler, {
  Duration translateTimeout = const Duration(seconds: 5),
}) => HttpTranslationProvider(
  baseUri: Uri.parse("https://translate.example.test"),
  apiKey: _secret,
  client: MockClient(handler),
  translateTimeout: translateTimeout,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {"content-type": "application/json; charset=utf-8"},
);

Future<TranslationErrorKind?> _errorOf(Future<Object?> future) async {
  try {
    await future;
    return null;
  } on TranslationException catch (e) {
    expect(e.toString(), isNot(contains(_secret)));
    return e.kind;
  }
}

void main() {
  const request = TranslationRequest(
    text: "¿Cuántos jugadores pueden participar en esta campaña?",
    source: "auto",
    target: "sv",
  );

  test("successful translation sends only text, source and target", () async {
    http.Request? captured;
    var provider = _provider((req) async {
      captured = req;
      return _json({
        "translation": "Hur många spelare kan delta i denna kampanj?",
        "source": "es",
        "target": "sv",
        "translated": true,
        "cached": false,
        "duration": 6.51,
      });
    });

    var result = await provider.translate(request);
    expect(result.translation, "Hur många spelare kan delta i denna kampanj?");
    expect(result.source, "es");
    expect(result.translated, isTrue);
    expect(result.cached, isFalse);
    expect(result.duration, const Duration(milliseconds: 6510));

    expect(captured!.method, "POST");
    expect(
      captured!.url.toString(),
      "https://translate.example.test/translate",
    );
    expect(captured!.headers["Authorization"], "Bearer $_secret");
    expect(captured!.followRedirects, isFalse);
    var body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body.keys.toSet(), {"text", "source", "target"});
    expect(body["text"], request.text);
  });

  test("cached response without optional fields", () async {
    var provider = _provider(
      (_) async => _json({
        "translation": "Hej",
        "source": "es",
        "target": "sv",
        "translated": true,
        "cached": true,
      }),
    );
    var result = await provider.translate(request);
    expect(result.cached, isTrue);
    expect(result.duration, isNull);
  });

  test("minimal response with only required fields", () async {
    var provider = _provider(
      (_) async => _json({"translation": "Hej", "translated": true}),
    );
    var result = await provider.translate(request);
    expect(result.source, isNull);
    expect(result.target, "sv");
    expect(result.cached, isFalse);
  });

  test("same language returns translated false", () async {
    var provider = _provider(
      (_) async => _json({
        "translation": "Hej",
        "source": "sv",
        "target": "sv",
        "translated": false,
      }),
    );
    var result = await provider.translate(request);
    expect(result.translated, isFalse);
  });

  test("HTTP errors are classified", () async {
    final cases = {
      400: TranslationErrorKind.invalidRequest,
      401: TranslationErrorKind.authentication,
      422: TranslationErrorKind.unsupportedLanguage,
      429: TranslationErrorKind.queueFull,
      502: TranslationErrorKind.backendFailure,
      504: TranslationErrorKind.backendFailure,
      418: TranslationErrorKind.unknown,
      302: TranslationErrorKind.unknown,
    };
    for (var entry in cases.entries) {
      var provider = _provider(
        (_) async => http.Response(
          '{"detail":"${request.text}"}',
          entry.key,
          headers: entry.key == 302
              ? {"location": "https://evil.example.test/steal"}
              : {},
        ),
      );
      expect(
        await _errorOf(provider.translate(request)),
        entry.value,
        reason: "status ${entry.key}",
      );
    }
  });

  test("429 exposes Retry-After", () async {
    var provider = _provider(
      (_) async => http.Response("", 429, headers: {"retry-after": "7"}),
    );
    try {
      await provider.translate(request);
      fail("expected exception");
    } on TranslationException catch (e) {
      expect(e.kind, TranslationErrorKind.queueFull);
      expect(e.retryAfter, const Duration(seconds: 7));
    }
  });

  test("malformed and unexpected responses", () async {
    for (var body in [
      "not json",
      "[1,2,3]",
      '{"translation": 5, "translated": true}',
      '{"translation": "x"}',
      "",
    ]) {
      var provider = _provider((_) async => http.Response(body, 200));
      expect(
        await _errorOf(provider.translate(request)),
        TranslationErrorKind.invalidResponse,
        reason: body,
      );
    }
  });

  test("connection failures", () async {
    var socket = _provider(
      (_) async => throw const SocketException("Failed host lookup"),
    );
    expect(
      await _errorOf(socket.translate(request)),
      TranslationErrorKind.unavailable,
    );

    var tls = _provider(
      (_) async => throw const HandshakeException("CERTIFICATE_VERIFY_FAILED"),
    );
    expect(await _errorOf(tls.translate(request)), TranslationErrorKind.tls);

    var client = _provider(
      (_) async =>
          throw http.ClientException("Connection reset ${request.text}"),
    );
    expect(
      await _errorOf(client.translate(request)),
      TranslationErrorKind.unavailable,
    );
  });

  test("timeout", () async {
    var provider = _provider(
      (_) => Completer<http.Response>().future,
      translateTimeout: const Duration(milliseconds: 50),
    );
    expect(
      await _errorOf(provider.translate(request)),
      TranslationErrorKind.timeout,
    );
  }, timeout: const Timeout(Duration(seconds: 10)));

  test("oversized text is never sent", () async {
    var sent = false;
    var provider = _provider((_) async {
      sent = true;
      return _json({});
    });
    var long = TranslationRequest(
      text: "a" * 501,
      source: "auto",
      target: "sv",
    );
    expect(
      await _errorOf(provider.translate(long)),
      TranslationErrorKind.tooLong,
    );
    expect(sent, isFalse);

    // 500 code points that are 1000 UTF-16 code units are accepted.
    var astral = TranslationRequest(
      text: "\u{1D538}" * 500,
      source: "auto",
      target: "sv",
    );
    expect(astral.text.length, 1000);
    await _errorOf(provider.translate(astral));
    expect(sent, isTrue);
  });

  test("health does not send the API key, languages does", () async {
    var headers = <String, Map<String, String>>{};
    var provider = _provider((req) async {
      headers[req.url.path] = req.headers;
      if (req.url.path == "/health") {
        return _json({
          "status": "ok",
          "model": "translategemma:4b",
          "version": "0.1.0",
        });
      }
      return _json({"en": "English", "sv": "Swedish", "bad": 3});
    });

    var info = await provider.health();
    expect(info.isOk, isTrue);
    expect(info.model, "translategemma:4b");
    expect(headers["/health"]!.containsKey("Authorization"), isFalse);

    var languages = await provider.languages();
    expect(languages, {"en": "English", "sv": "Swedish"});
    expect(headers["/languages"]!["Authorization"], "Bearer $_secret");
  });

  test("server URL validation", () {
    expect(
      HttpTranslationProvider.parseServerUrl("https://translate.example.org/"),
      Uri.parse("https://translate.example.org"),
    );
    expect(
      HttpTranslationProvider.parseServerUrl(" https://host:8443/api/ "),
      Uri.parse("https://host:8443/api"),
    );
    expect(HttpTranslationProvider.parseServerUrl("http://host"), isNull);
    expect(HttpTranslationProvider.parseServerUrl("ftp://host"), isNull);
    expect(HttpTranslationProvider.parseServerUrl("https://u:p@host"), isNull);
    expect(HttpTranslationProvider.parseServerUrl(""), isNull);
    expect(HttpTranslationProvider.parseServerUrl("not a url"), isNull);
  });

  test("path prefixes are respected", () async {
    Uri? url;
    var provider = HttpTranslationProvider(
      baseUri: Uri.parse("https://host/api"),
      apiKey: _secret,
      client: MockClient((req) async {
        url = req.url;
        return _json({"status": "ok"});
      }),
    );
    await provider.health();
    expect(url.toString(), "https://host/api/health");
  });

  test("identity excludes credentials", () {
    var provider = _provider((_) async => _json({}));
    expect(provider.identity, isNot(contains(_secret)));
  });
}
