import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Why a message can not (or should not) be translated.
enum TranslationSkipReason {
  /// Nothing left after removing emoji, links, code, punctuation...
  noNaturalLanguage,

  /// Contains structure we can not yet preserve (code blocks, named links,
  /// tables, inline images...).
  unsupportedFormatting,

  /// Contains a spoiler. Translating it would expose hidden content.
  spoiler,

  /// Media message or caption.
  media,

  /// Not an ordinary text message (emote, notice of a special type...).
  unsupportedMessageType,

  /// Longer than the provider accepts. Never truncated.
  tooLong,
}

/// The natural language projection of a message which will be sent to the
/// translation provider, along with the fragments that must survive
/// translation unchanged (links, mentions, inline code, custom emoji).
class TranslatableContent {
  final String text;
  final List<String> protectedTokens;
  final Set<String> urls;

  TranslatableContent._(this.text, this.protectedTokens, this.urls);

  int get codePointLength => text.runes.length;

  /// Hash of the original content, part of the cache identity so edits
  /// invalidate any previous translation.
  late final String contentHash = sha256
      .convert(utf8.encode(text))
      .toString()
      .substring(0, 32);
}

class TranslatableExtraction {
  final TranslatableContent? content;
  final TranslationSkipReason? skipReason;

  const TranslatableExtraction.ok(TranslatableContent this.content)
    : skipReason = null;

  const TranslatableExtraction.skip(TranslationSkipReason this.skipReason)
    : content = null;

  bool get isEligible => content != null;
}

class _Unsupported implements Exception {
  final TranslationSkipReason reason;
  _Unsupported(this.reason);
}

class TranslatableContentExtractor {
  static final RegExp urlRegex = RegExp(
    r'(?:(?:https?):\/\/|www\.)(?:\([-A-Z0-9+&@#/%=~_|$?!:,.]*\)|[-A-Z0-9+&@#/%=~_|$?!:,.])*(?:\([-A-Z0-9+&@#/%=~_|$?!:,.]*\)|[A-Z0-9+&@#/%=~_|$])',
    caseSensitive: false,
  );

  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _inlineCode = RegExp(r'`[^`\n]+`');
  static final RegExp _matrixId = RegExp(
    r'(?<![\w])[@#!][\w.=\-/+]+:[\w.\-]+(?::\d+)?',
  );
  static final RegExp _shortcode = RegExp(r':[A-Za-z0-9_+\-]{2,}:');

  static const Set<String> _inlineTags = {
    "b",
    "strong",
    "i",
    "em",
    "u",
    "s",
    "del",
    "strike",
    "sub",
    "sup",
    "span",
    "font",
    "small",
    "big",
    "ins",
    "mark",
  };

  static const Set<String> _blockTags = {
    "p",
    "div",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "ul",
    "ol",
    "hr",
  };

  /// Extract translatable content from a message.
  ///
  /// [body] is the plain text body with any reply fallback / per message
  /// profile fallback already removed. [formattedBody] is the HTML body if
  /// the message uses `org.matrix.custom.html`.
  static TranslatableExtraction extract({
    required String body,
    String? formattedBody,
    String msgtype = "m.text",
    bool hasAttachment = false,
    bool isReply = false,
    int maxCodePoints = 500,
  }) {
    if (hasAttachment) {
      return const TranslatableExtraction.skip(TranslationSkipReason.media);
    }

    if (msgtype != "m.text" && msgtype != "m.notice") {
      if (["m.image", "m.file", "m.video", "m.audio"].contains(msgtype)) {
        return const TranslatableExtraction.skip(TranslationSkipReason.media);
      }
      return const TranslatableExtraction.skip(
        TranslationSkipReason.unsupportedMessageType,
      );
    }

    var tokens = <String>[];
    String text;

    try {
      if (formattedBody != null && formattedBody.trim().isNotEmpty) {
        text = _htmlToText(formattedBody, tokens);
      } else {
        text = _plainToText(body, tokens, isReply: isReply);
      }
    } on _Unsupported catch (e) {
      return TranslatableExtraction.skip(e.reason);
    }

    text = _normaliseWhitespace(text);

    if (!hasNaturalLanguage(text, tokens)) {
      return const TranslatableExtraction.skip(
        TranslationSkipReason.noNaturalLanguage,
      );
    }

    if (text.runes.length > maxCodePoints) {
      return const TranslatableExtraction.skip(TranslationSkipReason.tooLong);
    }

    var urls = findUrls(text);
    for (var url in urls) {
      if (!tokens.contains(url)) tokens.add(url);
    }

    return TranslatableExtraction.ok(
      TranslatableContent._(text, List.unmodifiable(tokens), urls),
    );
  }

  static Set<String> findUrls(String text) =>
      urlRegex.allMatches(text).map((m) => m.group(0)!).toSet();

  /// True if, after removing links, code, ids, shortcodes, emoji, digits and
  /// punctuation, there is at least one letter left.
  static bool hasNaturalLanguage(String text, [List<String>? tokens]) {
    var stripped = text;
    for (var token in tokens ?? const <String>[]) {
      stripped = stripped.replaceAll(token, " ");
    }
    stripped = stripped
        .replaceAll(urlRegex, " ")
        .replaceAll(_inlineCode, " ")
        .replaceAll(_matrixId, " ")
        .replaceAll(_shortcode, " ");
    return _letter.hasMatch(stripped);
  }

  static String _plainToText(
    String body,
    List<String> tokens, {
    required bool isReply,
  }) {
    var text = body;

    if (isReply) {
      text = stripPlainReplyFallback(text);
    }

    if (text.contains("```")) {
      throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
    }

    if (text.contains("||")) {
      // Discord style spoiler markers bridged as plain text.
      throw _Unsupported(TranslationSkipReason.spoiler);
    }

    for (var match in _inlineCode.allMatches(text)) {
      tokens.add(match.group(0)!);
    }

    return text;
  }

  /// Removes the legacy `> <@user:server> quoted text` reply fallback that
  /// precedes the actual reply body.
  static String stripPlainReplyFallback(String text) {
    var lines = text.split("\n");
    var i = 0;
    while (i < lines.length && lines[i].startsWith(">")) {
      i++;
    }
    if (i == 0) return text;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    return lines.sublist(i).join("\n");
  }

  static String _htmlToText(String html, List<String> tokens) {
    var fragment = html_parser.parseFragment(html);
    var buffer = StringBuffer();
    for (var node in fragment.nodes) {
      _visit(node, buffer, tokens, listDepth: 0);
    }
    return buffer.toString();
  }

  static void _ensureNewline(StringBuffer buffer) {
    var s = buffer.toString();
    if (s.isNotEmpty && !s.endsWith("\n")) buffer.write("\n");
  }

  static void _visit(
    dom.Node node,
    StringBuffer buffer,
    List<String> tokens, {
    required int listDepth,
    int? orderedIndex,
  }) {
    if (node is dom.Text) {
      buffer.write(node.text.replaceAll(RegExp(r'[ \t\r\n]+'), " "));
      return;
    }

    if (node is! dom.Element) {
      // Comments etc.
      return;
    }

    var tag = node.localName?.toLowerCase() ?? "";

    if (node.attributes.containsKey("data-mx-spoiler")) {
      throw _Unsupported(TranslationSkipReason.spoiler);
    }

    if (tag == "mx-reply") {
      return;
    }

    if (tag == "br") {
      buffer.write("\n");
      return;
    }

    if (tag == "img") {
      if (node.attributes.containsKey("data-mx-emoticon")) {
        var alt = (node.attributes["alt"] ?? node.attributes["title"] ?? "")
            .trim();
        if (alt.isEmpty) {
          throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
        }
        tokens.add(alt);
        buffer.write(alt);
        return;
      }
      throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
    }

    if (tag == "code") {
      var parent = node.parent;
      if (parent != null && parent.localName == "pre") {
        throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
      }
      var code = "`${node.text}`";
      tokens.add(code);
      buffer.write(code);
      return;
    }

    if (tag == "a") {
      var href = node.attributes["href"] ?? "";
      var text = node.text.trim();
      var uri = Uri.tryParse(href);
      if (uri != null && uri.host == "matrix.to") {
        // User / room pill. Keep the visible text verbatim.
        if (text.isNotEmpty) {
          tokens.add(text);
          buffer.write(text);
        }
        return;
      }
      var isBareLink =
          text.isEmpty ||
          text == href ||
          href == "https://$text" ||
          href == "http://$text" ||
          href == "mailto:$text";
      if (isBareLink) {
        var link = text.isEmpty ? href : text;
        tokens.add(link);
        buffer.write(link);
        return;
      }
      // Named link: translation would lose the link target.
      throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
    }

    if (tag == "li") {
      _ensureNewline(buffer);
      buffer.write("  " * (listDepth > 0 ? listDepth - 1 : 0));
      buffer.write(orderedIndex != null ? "$orderedIndex. " : "\u2022 ");
      for (var child in node.nodes) {
        _visit(child, buffer, tokens, listDepth: listDepth);
      }
      _ensureNewline(buffer);
      return;
    }

    if (tag == "ul" || tag == "ol") {
      _ensureNewline(buffer);
      var index = 1;
      for (var child in node.nodes) {
        var isLi = child is dom.Element && child.localName == "li";
        _visit(
          child,
          buffer,
          tokens,
          listDepth: listDepth + 1,
          orderedIndex: tag == "ol" && isLi ? index : null,
        );
        if (isLi) index++;
      }
      _ensureNewline(buffer);
      return;
    }

    if (tag == "hr") {
      _ensureNewline(buffer);
      return;
    }

    if (_blockTags.contains(tag)) {
      _ensureNewline(buffer);
      for (var child in node.nodes) {
        _visit(child, buffer, tokens, listDepth: listDepth);
      }
      _ensureNewline(buffer);
      return;
    }

    if (_inlineTags.contains(tag)) {
      for (var child in node.nodes) {
        _visit(child, buffer, tokens, listDepth: listDepth);
      }
      return;
    }

    // pre, table, details, unknown tags...
    throw _Unsupported(TranslationSkipReason.unsupportedFormatting);
  }

  static String _normaliseWhitespace(String text) {
    var lines = text
        .split("\n")
        .map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ""))
        .toList();
    var joined = lines.join("\n");
    joined = joined.replaceAll(RegExp(r'\n{3,}'), "\n\n");
    return joined.trim();
  }
}

/// Why a model output was rejected.
enum TranslationOutputRejection {
  empty,
  tooLong,
  missingProtectedContent,
  unexpectedLink,
}

class SanitizedTranslation {
  final String? text;
  final TranslationOutputRejection? rejection;

  const SanitizedTranslation.ok(String this.text) : rejection = null;
  const SanitizedTranslation.rejected(TranslationOutputRejection this.rejection)
    : text = null;

  bool get isOk => text != null;
}

/// Treats model output as untrusted text.
class TranslationOutputSanitizer {
  // C0 / C1 control characters other than tab and newline.
  static final RegExp _controlChars = RegExp(
    r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]',
  );

  // Bidirectional overrides / isolates which can be used to visually
  // disguise text ("Trojan source" style).
  static final RegExp _bidiControls = RegExp(r'[\u202A-\u202E\u2066-\u2069]');

  static SanitizedTranslation sanitize(
    String output,
    TranslatableContent source,
  ) {
    var text = output.replaceAll("\r\n", "\n").replaceAll(_controlChars, "");

    if (!_bidiControls.hasMatch(source.text)) {
      text = text.replaceAll(_bidiControls, "");
    }

    text = text.trim();

    if (text.isEmpty) {
      return const SanitizedTranslation.rejected(
        TranslationOutputRejection.empty,
      );
    }

    var maxLength = source.codePointLength * 4 + 200;
    if (text.runes.length > maxLength) {
      return const SanitizedTranslation.rejected(
        TranslationOutputRejection.tooLong,
      );
    }

    for (var token in source.protectedTokens) {
      if (!text.contains(token)) {
        return const SanitizedTranslation.rejected(
          TranslationOutputRejection.missingProtectedContent,
        );
      }
    }

    // The model must never introduce links that were not in the original.
    for (var url in TranslatableContentExtractor.findUrls(text)) {
      if (!source.urls.contains(url)) {
        return const SanitizedTranslation.rejected(
          TranslationOutputRejection.unexpectedLink,
        );
      }
    }

    return SanitizedTranslation.ok(text);
  }
}
