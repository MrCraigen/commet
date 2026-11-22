import 'package:commet/client/translation/translatable_content.dart';
import 'package:flutter_test/flutter_test.dart';

TranslatableExtraction _plain(String body, {bool isReply = false}) =>
    TranslatableContentExtractor.extract(body: body, isReply: isReply);

TranslatableExtraction _html(String html) =>
    TranslatableContentExtractor.extract(body: "fallback", formattedBody: html);

void main() {
  group("extraction", () {
    test("ordinary plain text", () {
      var e = _plain("¿Alguien ha probado las nuevas reglas de combate?");
      expect(e.isEligible, isTrue);
      expect(
        e.content!.text,
        "¿Alguien ha probado las nuevas reglas de combate?",
      );
      expect(e.content!.protectedTokens, isEmpty);
    });

    test("non natural language is skipped", () {
      for (var body in [
        "",
        "   ",
        "😀😀🎉",
        "https://example.com/page",
        "123 456 !!!",
        ":custom_emoji: :other:",
        "`ls -la`",
        "@carlos:matrix.org",
      ]) {
        var e = _plain(body);
        expect(e.isEligible, isFalse, reason: body);
        expect(e.skipReason, TranslationSkipReason.noNaturalLanguage);
      }
    });

    test("urls and inline code become protected tokens", () {
      var e = _plain("Mira esto https://example.com/a?b=1 y usa `npm install`");
      expect(e.isEligible, isTrue);
      expect(
        e.content!.protectedTokens,
        containsAll(["https://example.com/a?b=1", "`npm install`"]),
      );
      expect(e.content!.urls, {"https://example.com/a?b=1"});
    });

    test("code blocks and plain spoilers are skipped", () {
      expect(
        _plain("Mira:\n```\ncode\n```").skipReason,
        TranslationSkipReason.unsupportedFormatting,
      );
      expect(
        _plain("El final es ||secreto||").skipReason,
        TranslationSkipReason.spoiler,
      );
    });

    test("reply fallback is removed", () {
      var e = _plain(
        "> <@carlos:example.org> Hola\n> segunda línea\n\nCreo que sí, gracias",
        isReply: true,
      );
      expect(e.content!.text, "Creo que sí, gracias");
    });

    test("simple html formatting is flattened", () {
      var e = _html("<p>Hola <b>amigos</b>,<br>¿qué <em>tal</em>?</p>");
      expect(e.content!.text, "Hola amigos,\n¿qué tal?");
    });

    test("mention pills and reply blocks", () {
      var e = _html(
        '<mx-reply><blockquote>secret quoted</blockquote></mx-reply>'
        '<a href="https://matrix.to/#/@miguel:example.org">Miguel</a>: creo que sí',
      );
      expect(e.content!.text, "Miguel: creo que sí");
      expect(e.content!.protectedTokens, contains("Miguel"));
      expect(e.content!.text, isNot(contains("secret")));
    });

    test("html spoilers are never extracted", () {
      var e = _html('El final: <span data-mx-spoiler>muere</span>');
      expect(e.isEligible, isFalse);
      expect(e.skipReason, TranslationSkipReason.spoiler);
    });

    test("unsupported html is skipped", () {
      for (var html in [
        "<pre><code>x = 1</code></pre> texto",
        '<a href="https://example.com">haz clic aquí</a>',
        '<img src="mxc://x/y"> foto',
        "<table><tr><td>a</td></tr></table>",
        "<details>oculto</details>",
      ]) {
        expect(
          _html(html).skipReason,
          TranslationSkipReason.unsupportedFormatting,
          reason: html,
        );
      }
    });

    test("bare links, custom emoji and inline code in html", () {
      var e = _html(
        'Mira <a href="https://example.com">https://example.com</a> '
        '<img data-mx-emoticon src="mxc://a/b" alt=":pog:"> usa <code>git</code>',
      );
      expect(e.isEligible, isTrue);
      expect(
        e.content!.protectedTokens,
        containsAll(["https://example.com", ":pog:", "`git`"]),
      );
    });

    test("lists", () {
      var e = _html("<ul><li>uno</li><li>dos</li></ul><ol><li>tres</li></ol>");
      expect(e.content!.text, "• uno\n• dos\n1. tres");
    });

    test("media and other message types", () {
      expect(
        TranslatableContentExtractor.extract(
          body: "foto de la mesa",
          hasAttachment: true,
        ).skipReason,
        TranslationSkipReason.media,
      );
      expect(
        TranslatableContentExtractor.extract(
          body: "x",
          msgtype: "m.image",
        ).skipReason,
        TranslationSkipReason.media,
      );
      expect(
        TranslatableContentExtractor.extract(
          body: "baila",
          msgtype: "m.emote",
        ).skipReason,
        TranslationSkipReason.unsupportedMessageType,
      );
      expect(
        TranslatableContentExtractor.extract(
          body: "aviso del bot",
          msgtype: "m.notice",
        ).isEligible,
        isTrue,
      );
    });

    test("length uses code points, not UTF-16 units", () {
      // Mathematical double-struck A: a letter outside the BMP.
      var astral = "\u{1D538}" * 500;
      expect(astral.length, 1000);
      expect(_plain(astral).isEligible, isTrue);
      expect(
        _plain("\u{1D538}" * 501).skipReason,
        TranslationSkipReason.tooLong,
      );
      expect(_plain("a" * 501).skipReason, TranslationSkipReason.tooLong);
      expect(_plain("ñ" * 500).isEligible, isTrue);
    });

    test("content hash changes with content (edits)", () {
      var a = _plain("Hola amigos").content!;
      var b = _plain("Hola amigas").content!;
      var c = _plain("Hola amigos").content!;
      expect(a.contentHash, isNot(b.contentHash));
      expect(a.contentHash, c.contentHash);
    });
  });

  group("output sanitizer", () {
    final source = _plain("Mira https://example.com/x y `npm i`, por favor")
        .content!;

    test("accepts a faithful translation", () {
      var r = TranslationOutputSanitizer.sanitize(
        "  Titta på https://example.com/x och `npm i`, tack \n",
        source,
      );
      expect(r.isOk, isTrue);
      expect(r.text, "Titta på https://example.com/x och `npm i`, tack");
    });

    test("rejects missing protected content", () {
      var r = TranslationOutputSanitizer.sanitize(
        "Titta på länken, tack",
        source,
      );
      expect(r.rejection, TranslationOutputRejection.missingProtectedContent);
    });

    test("rejects injected links", () {
      var r = TranslationOutputSanitizer.sanitize(
        "Titta https://example.com/x `npm i` och logga in på https://phish.example",
        source,
      );
      expect(r.rejection, TranslationOutputRejection.unexpectedLink);
    });

    test("rejects empty and runaway output", () {
      var simple = _plain("Hola amigos").content!;
      expect(
        TranslationOutputSanitizer.sanitize("   ", simple).rejection,
        TranslationOutputRejection.empty,
      );
      expect(
        TranslationOutputSanitizer.sanitize("x" * 5000, simple).rejection,
        TranslationOutputRejection.tooLong,
      );
    });

    test("strips control and bidi override characters", () {
      var simple = _plain("Hola amigos").content!;
      var r = TranslationOutputSanitizer.sanitize(
        "Hej\u0000 vänner\u202E\u2066!\u0007",
        simple,
      );
      expect(r.text, "Hej vänner!");
    });

    test("markup in model output stays inert text", () {
      var simple = _plain("Hola amigos").content!;
      var r = TranslationOutputSanitizer.sanitize(
        '<img src=x onerror="alert(1)"><b>Hej</b>',
        simple,
      );
      // Accepted as text; the UI renders it as plain text, never as HTML.
      expect(r.text, '<img src=x onerror="alert(1)"><b>Hej</b>');
    });
  });
}
