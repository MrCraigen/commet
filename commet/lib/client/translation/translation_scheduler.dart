import 'dart:async';
import 'dart:math';

import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_provider.dart';

enum TranslationPriority { manual, visible }

/// Progress notifications emitted by the scheduler.
sealed class TranslationJobUpdate {
  const TranslationJobUpdate();
}

class TranslationJobQueued extends TranslationJobUpdate {
  const TranslationJobQueued();
}

class TranslationJobStarted extends TranslationJobUpdate {
  const TranslationJobStarted();
}

/// Request was dropped before completing (no longer visible, room switched,
/// queue pressure, settings changed...).
class TranslationJobCancelled extends TranslationJobUpdate {
  const TranslationJobCancelled();
}

class TranslationJobSucceeded extends TranslationJobUpdate {
  final TranslationResult result;
  const TranslationJobSucceeded(this.result);
}

class TranslationJobFailed extends TranslationJobUpdate {
  final TranslationErrorKind kind;

  /// True if retrying later (without changing anything) is pointless.
  final bool permanent;
  const TranslationJobFailed(this.kind, {required this.permanent});
}

typedef TranslationExecutor = Future<TranslationResult> Function(
  TranslationRequest request,
);

typedef TranslationUpdateListener = void Function(
  TranslationKey key,
  TranslationJobUpdate update,
);

class _Interest {
  bool manual = false;
  final Set<Object> owners = {};
  bool get wanted => manual || owners.isNotEmpty;
}

class _Job {
  final String requestKey;
  final TranslationRequest request;
  final Map<TranslationKey, _Interest> interests = {};
  int sequence;
  int attempts = 0;
  bool inFlight = false;
  int generation;

  _Job(this.requestKey, this.request, this.sequence, this.generation);

  bool get isManual => interests.values.any((i) => i.manual);
  bool get wanted => interests.values.any((i) => i.wanted);
}

/// Central scheduler for all translation requests.
///
/// * Exactly [maxConcurrent] (default 1) requests in flight; the backend
///   processes one inference at a time.
/// * Bounded queue of [maxQueued] pending requests. Visible-message jobs are
///   evicted (oldest first) to make space; manual jobs are never evicted.
/// * Manual jobs run first (FIFO), then visible jobs, most recently seen
///   first, which keeps work focused on the user's reading position.
/// * Identical requests (same text, languages, provider) are deduplicated.
/// * Retryable failures use bounded exponential backoff, honouring
///   `Retry-After` for 429. Permanent failures are never retried.
/// * Service wide failures (authentication, TLS, configuration) block
///   automatic work until [reset] is called.
class TranslationScheduler {
  final TranslationExecutor execute;
  final TranslationUpdateListener onUpdate;
  final int maxConcurrent;
  final int maxQueued;
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;

  final Map<String, _Job> _jobs = {};
  int _sequence = 0;
  int _generation = 0;
  int _inFlight = 0;

  DateTime? _pausedUntil;
  Timer? _resumeTimer;
  TranslationErrorKind? _blockedBy;
  bool _disposed = false;

  /// For tests / diagnostics.
  int requestsSent = 0;

  TranslationScheduler({
    required this.execute,
    required this.onUpdate,
    this.maxConcurrent = 1,
    this.maxQueued = 6,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
  });

  TranslationErrorKind? get blockedBy => _blockedBy;

  int get queuedCount => _jobs.values.where((j) => !j.inFlight).length;
  int get inFlightCount => _inFlight;
  bool get isPaused =>
      _pausedUntil != null && DateTime.now().isBefore(_pausedUntil!);

  bool isPending(TranslationKey key) =>
      _jobs.values.any((j) => j.interests.containsKey(key));

  /// Request a translation for a manual user action.
  void requestManual(TranslationKey key, TranslatableContent content) {
    var job = _jobFor(key, content);
    var interest = job.interests.putIfAbsent(key, _Interest.new);
    interest.manual = true;
    if (!job.inFlight) onUpdate(key, const TranslationJobQueued());
    _enforceQueueLimit();
    _pump();
  }

  /// Replace the set of visible messages reported by [owner] (usually one
  /// timeline view). Entries are ordered by preference, first = most
  /// relevant. Queued visible work from this owner which is no longer
  /// visible is cancelled.
  void updateVisible(
    Object owner,
    List<(TranslationKey, TranslatableContent)> visible,
  ) {
    var visibleKeys = visible.map((e) => e.$1).toSet();

    // Drop this owner's interest in messages that are no longer visible.
    for (var job in _jobs.values.toList()) {
      for (var entry in job.interests.entries.toList()) {
        if (!visibleKeys.contains(entry.key)) {
          entry.value.owners.remove(owner);
        }
      }
      _dropUnwanted(job);
    }

    if (_blockedBy != null) return;

    // Add newly visible ones, most relevant gets the highest sequence.
    for (var (key, content) in visible.reversed) {
      var existed = isPending(key);
      var job = _jobFor(key, content);
      var interest = job.interests.putIfAbsent(key, _Interest.new);
      if (interest.owners.add(owner) && !existed) {
        job.sequence = ++_sequence;
        if (!job.inFlight) onUpdate(key, const TranslationJobQueued());
      }
    }

    _enforceQueueLimit();
    _pump();
  }

  /// Remove all interest registered by [owner], e.g. a timeline view being
  /// disposed when the user switches rooms.
  void removeOwner(Object owner) => updateVisible(owner, const []);

  /// Cancel queued (not in-flight) work matching [test].
  void cancelWhere(bool Function(TranslationKey key) test) {
    for (var job in _jobs.values.toList()) {
      if (job.inFlight) continue;
      for (var key in job.interests.keys.where(test).toList()) {
        job.interests.remove(key);
        onUpdate(key, const TranslationJobCancelled());
      }
      if (job.interests.isEmpty) _jobs.remove(job.requestKey);
    }
  }

  /// Forget all queued work, unblock and clear backoff. In-flight responses
  /// arriving afterwards are treated as stale and ignored.
  void reset() {
    _generation++;
    for (var job in _jobs.values.toList()) {
      for (var key in job.interests.keys) {
        onUpdate(key, const TranslationJobCancelled());
      }
    }
    _jobs.clear();
    _blockedBy = null;
    _pausedUntil = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void dispose() {
    _disposed = true;
    _resumeTimer?.cancel();
    _jobs.clear();
  }

  _Job _jobFor(TranslationKey key, TranslatableContent content) {
    var requestKey = key.requestKey;
    return _jobs.putIfAbsent(
      requestKey,
      () => _Job(
        requestKey,
        TranslationRequest(
          text: content.text,
          source: key.sourceLanguage,
          target: key.targetLanguage,
        ),
        ++_sequence,
        _generation,
      ),
    );
  }

  void _dropUnwanted(_Job job) {
    // In-flight work can not be cancelled on the backend; keep the keys so
    // the result still lands in the cache when it arrives.
    if (job.inFlight) return;
    for (var entry in job.interests.entries.toList()) {
      if (!entry.value.wanted) {
        job.interests.remove(entry.key);
        if (!job.inFlight) {
          onUpdate(entry.key, const TranslationJobCancelled());
        }
      }
    }
    if (job.interests.isEmpty && !job.inFlight) {
      _jobs.remove(job.requestKey);
    }
  }

  void _enforceQueueLimit() {
    var queued = _jobs.values.where((j) => !j.inFlight).toList();
    if (queued.length <= maxQueued) return;

    var evictable = queued.where((j) => !j.isManual).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    var excess = queued.length - maxQueued;
    for (var job in evictable.take(excess)) {
      _jobs.remove(job.requestKey);
      for (var key in job.interests.keys) {
        onUpdate(key, const TranslationJobCancelled());
      }
    }
  }

  _Job? _nextJob() {
    var queued = _jobs.values.where((j) => !j.inFlight).toList();
    if (queued.isEmpty) return null;

    var manual = queued.where((j) => j.isManual).toList();
    if (manual.isNotEmpty) {
      manual.sort((a, b) => a.sequence.compareTo(b.sequence));
      return manual.first;
    }

    if (_blockedBy != null) return null;

    queued.sort((a, b) => b.sequence.compareTo(a.sequence));
    return queued.first;
  }

  void _pump() {
    if (_disposed) return;

    while (_inFlight < maxConcurrent) {
      if (_pausedUntil != null) {
        var remaining = _pausedUntil!.difference(DateTime.now());
        if (remaining > Duration.zero) {
          _scheduleResume(remaining);
          return;
        }
        _pausedUntil = null;
      }

      var job = _nextJob();
      if (job == null) return;
      _start(job);
    }
  }

  void _scheduleResume(Duration delay) {
    if (_resumeTimer?.isActive == true) return;
    _resumeTimer = Timer(delay, () {
      _resumeTimer = null;
      _pump();
    });
  }

  Duration _backoffFor(int attempts, Duration? retryAfter) {
    if (retryAfter != null) {
      return retryAfter > maxBackoff ? maxBackoff : retryAfter;
    }
    var ms = baseBackoff.inMilliseconds * pow(2, max(0, attempts - 1));
    return Duration(milliseconds: min(ms.toInt(), maxBackoff.inMilliseconds));
  }

  void _start(_Job job) {
    job.inFlight = true;
    job.attempts++;
    job.generation = _generation;
    _inFlight++;
    requestsSent++;

    for (var key in job.interests.keys) {
      onUpdate(key, const TranslationJobStarted());
    }

    var generation = _generation;

    execute(job.request).then(
      (result) => _complete(job, generation, result: result),
      onError: (Object error) => _complete(job, generation, error: error),
    );
  }

  void _complete(
    _Job job,
    int generation, {
    TranslationResult? result,
    Object? error,
  }) {
    _inFlight--;
    job.inFlight = false;

    if (_disposed) return;

    if (generation != _generation) {
      // Settings changed while this was in flight: stale, ignore.
      _pump();
      return;
    }

    if (result != null) {
      _jobs.remove(job.requestKey);
      for (var key in job.interests.keys) {
        onUpdate(key, TranslationJobSucceeded(result));
      }
      _pump();
      return;
    }

    var exception = error is TranslationException
        ? error
        : const TranslationException(TranslationErrorKind.unknown);
    var kind = exception.kind;

    if (kind.isServiceWide) {
      _blockedBy = kind;
    }

    var canRetry = kind.isRetryable && job.attempts < maxAttempts;

    if (kind.isRetryable) {
      // Apply backpressure to the whole queue, the server is struggling.
      _pausedUntil = DateTime.now().add(
        _backoffFor(job.attempts, exception.retryAfter),
      );
    }

    if (canRetry && job.wanted) {
      // Keep the job queued; it will be retried after the pause.
      for (var key in job.interests.keys) {
        onUpdate(key, const TranslationJobQueued());
      }
    } else if (canRetry) {
      // Retryable, but nobody is interested any more: forget it without
      // marking it failed, so it is tried again once visible.
      _jobs.remove(job.requestKey);
      for (var key in job.interests.keys) {
        onUpdate(key, const TranslationJobCancelled());
      }
    } else {
      _jobs.remove(job.requestKey);
      for (var key in job.interests.keys) {
        onUpdate(key, TranslationJobFailed(kind, permanent: !kind.isRetryable));
      }
    }

    _pump();
  }
}
