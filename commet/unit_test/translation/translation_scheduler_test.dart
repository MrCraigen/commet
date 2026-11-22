import 'dart:async';

import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:commet/client/translation/translation_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Executor whose requests complete only when the test says so.
class _ManualExecutor {
  final List<(TranslationRequest, Completer<TranslationResult>)> calls = [];
  int active = 0;
  int maxActive = 0;

  Future<TranslationResult> call(TranslationRequest request) {
    var c = Completer<TranslationResult>();
    calls.add((request, c));
    active++;
    if (active > maxActive) maxActive = active;
    return c.future.whenComplete(() => active--);
  }

  void succeed(int i) => calls[i].$2.complete(
    TranslationResult(
      translation: "T:${calls[i].$1.text}",
      source: "es",
      target: calls[i].$1.target,
      translated: true,
    ),
  );

  void fail(int i, TranslationErrorKind kind, {Duration? retryAfter}) =>
      calls[i].$2.completeError(
        TranslationException(kind, retryAfter: retryAfter),
      );
}

TranslationKey _key(
  String event, {
  String text = "",
  String target = "sv",
  String room = "!r",
  String account = "acc",
}) {
  var content = _content(text.isEmpty ? "texto $event" : text);
  return TranslationKey(
    accountId: account,
    roomId: room,
    eventId: event,
    contentHash: content.contentHash,
    sourceLanguage: "auto",
    targetLanguage: target,
    providerIdentity: "test",
  );
}

TranslatableContent _content(String text) =>
    TranslatableContentExtractor.extract(body: text).content!;

(TranslationKey, TranslatableContent) _job(
  String event, {
  String? text,
  String room = "!r",
}) {
  var t = text ?? "texto $event";
  return (_key(event, text: t, room: room), _content(t));
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _ManualExecutor exec;
  late List<(TranslationKey, TranslationJobUpdate)> updates;
  late TranslationScheduler scheduler;

  setUp(() {
    exec = _ManualExecutor();
    updates = [];
    scheduler = TranslationScheduler(
      execute: exec.call,
      onUpdate: (k, u) => updates.add((k, u)),
      maxQueued: 4,
      baseBackoff: const Duration(milliseconds: 20),
      maxBackoff: const Duration(milliseconds: 100),
    );
  });

  tearDown(() => scheduler.dispose());

  Iterable<TranslationJobUpdate> updatesFor(TranslationKey key) =>
      updates.where((u) => u.$1 == key).map((u) => u.$2);

  test("one request at a time", () async {
    var owner = Object();
    scheduler.updateVisible(owner, [_job("a"), _job("b"), _job("c")]);
    expect(exec.calls.length, 1);
    exec.succeed(0);
    await _settle();
    expect(exec.calls.length, 2);
    exec.succeed(1);
    await _settle();
    exec.succeed(2);
    await _settle();
    expect(exec.maxActive, 1);
    expect(scheduler.queuedCount, 0);
  });

  test("identical requests are deduplicated", () async {
    var owner = Object();
    var a = _job("a", text: "mismo texto");
    var b = _job("b", text: "mismo texto");
    scheduler.updateVisible(owner, [a, b]);
    expect(exec.calls.length, 1);
    exec.succeed(0);
    await _settle();
    expect(updatesFor(a.$1).last, isA<TranslationJobSucceeded>());
    expect(updatesFor(b.$1).last, isA<TranslationJobSucceeded>());
    expect(exec.calls.length, 1);
  });

  test(
    "re-reporting the same visible messages does not duplicate work",
    () async {
      var owner = Object();
      var jobs = [_job("a"), _job("b")];
      for (var i = 0; i < 10; i++) {
        scheduler.updateVisible(owner, jobs);
      }
      expect(exec.calls.length, 1);
      expect(scheduler.queuedCount, 1);
    },
  );

  test("manual requests take priority over visible ones", () async {
    var owner = Object();
    scheduler.updateVisible(owner, [_job("v1"), _job("v2"), _job("v3")]);
    var manual = _job("m");
    scheduler.requestManual(manual.$1, manual.$2);
    exec.succeed(0);
    await _settle();
    expect(exec.calls[1].$1.text, manual.$2.text);
  });

  test("most relevant visible message goes first", () async {
    var blocker = _job("blocker");
    scheduler.requestManual(blocker.$1, blocker.$2);
    var owner = Object();
    scheduler.updateVisible(owner, [_job("center"), _job("edge")]);
    exec.succeed(0);
    await _settle();
    expect(exec.calls[1].$1.text, "texto center");
  });

  test("messages scrolled out of view are cancelled", () async {
    var owner = Object();
    var a = _job("a"), b = _job("b"), c = _job("c");
    scheduler.updateVisible(owner, [a, b, c]);
    // User scrolls: only c remains visible.
    scheduler.updateVisible(owner, [c]);
    expect(updatesFor(b.$1).last, isA<TranslationJobCancelled>());
    exec.succeed(0); // a was already in flight
    await _settle();
    expect(updatesFor(a.$1).last, isA<TranslationJobSucceeded>());
    expect(exec.calls.length, 2);
    expect(exec.calls[1].$1.text, c.$2.text);
  });

  test("scrolling through history never builds an unbounded backlog", () async {
    var owner = Object();
    for (var page = 0; page < 50; page++) {
      scheduler.updateVisible(owner, [
        for (var i = 0; i < 10; i++) _job("p$page-$i"),
      ]);
      expect(scheduler.queuedCount, lessThanOrEqualTo(4));
    }
    expect(exec.calls.length, 1);
  });

  test("rapid room switching prioritises the new room", () async {
    var roomA = Object();
    var roomB = Object();
    scheduler.updateVisible(roomA, [
      _job("a1", room: "!a"),
      _job("a2", room: "!a"),
      _job("a3", room: "!a"),
    ]);
    scheduler.removeOwner(roomA);
    scheduler.updateVisible(roomB, [_job("b1", room: "!b")]);
    exec.succeed(0);
    await _settle();
    expect(exec.calls.length, 2);
    expect(exec.calls[1].$1.text, "texto b1");
    expect(scheduler.queuedCount, 0);
  });

  test(
    "queue full applies backoff and retries a bounded number of times",
    () async {
      var job = _job("m");
      scheduler.requestManual(job.$1, job.$2);
      exec.fail(0, TranslationErrorKind.queueFull);
      await _settle();
      expect(scheduler.isPaused, isTrue);
      expect(exec.calls.length, 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(exec.calls.length, 2);
      exec.fail(1, TranslationErrorKind.queueFull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exec.calls.length, 3);
      exec.fail(2, TranslationErrorKind.queueFull);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(exec.calls.length, 3, reason: "max 3 attempts");
      var last = updatesFor(job.$1).last as TranslationJobFailed;
      expect(last.kind, TranslationErrorKind.queueFull);
      expect(last.permanent, isFalse);
    },
  );

  test("Retry-After is honoured but capped", () async {
    var job = _job("m");
    scheduler.requestManual(job.$1, job.$2);
    exec.fail(
      0,
      TranslationErrorKind.queueFull,
      retryAfter: const Duration(seconds: 30),
    );
    await _settle();
    expect(scheduler.isPaused, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(exec.calls.length, 2, reason: "capped at maxBackoff");
  });

  test("permanent failures are not retried", () async {
    var job = _job("m");
    scheduler.requestManual(job.$1, job.$2);
    exec.fail(0, TranslationErrorKind.unsupportedLanguage);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(exec.calls.length, 1);
    var last = updatesFor(job.$1).last as TranslationJobFailed;
    expect(last.permanent, isTrue);
  });

  test("authentication failure blocks automatic work until reset", () async {
    var owner = Object();
    scheduler.updateVisible(owner, [_job("a"), _job("b")]);
    exec.fail(0, TranslationErrorKind.authentication);
    await _settle();
    expect(scheduler.blockedBy, TranslationErrorKind.authentication);
    expect(exec.calls.length, 1);
    scheduler.updateVisible(owner, [_job("c")]);
    expect(exec.calls.length, 1);

    scheduler.reset();
    scheduler.updateVisible(owner, [_job("c")]);
    expect(exec.calls.length, 2);
  });

  test("stale responses after reset are ignored", () async {
    var job = _job("a");
    scheduler.requestManual(job.$1, job.$2);
    scheduler.reset();
    exec.succeed(0);
    await _settle();
    expect(updatesFor(job.$1).whereType<TranslationJobSucceeded>(), isEmpty);
  });

  test("cancelWhere drops matching queued work", () async {
    var owner = Object();
    var a = _job("a");
    var other = (_key("x", account: "other"), _content("texto x"));
    scheduler.updateVisible(owner, [a, _job("b"), other]);
    scheduler.cancelWhere((k) => k.accountId == "other");
    expect(updatesFor(other.$1).last, isA<TranslationJobCancelled>());
  });
}
