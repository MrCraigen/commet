import 'package:commet/client/client.dart';
import 'package:commet/client/components/direct_messages/direct_message_component.dart';
import 'package:commet/client/matrix/matrix_room.dart';
import 'package:commet/client/matrix/timeline_events/matrix_timeline_event_message.dart';
import 'package:commet/client/translation/translatable_content.dart';
import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_policy.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/client/timeline_events/timeline_event.dart';
import 'package:matrix/matrix.dart' as matrix;

/// Builds the space hierarchy of one client: for every room / space, the
/// spaces which directly contain it.
class ClientTranslationHierarchy implements TranslationHierarchy {
  final Map<String, List<String>> _parents = {};

  ClientTranslationHierarchy(Client client) {
    for (var space in client.spaces) {
      for (var room in space.rooms) {
        _parents.putIfAbsent(room.identifier, () => []).add(space.identifier);
      }
      for (var sub in space.subspaces) {
        _parents.putIfAbsent(sub.identifier, () => []).add(space.identifier);
      }
    }
  }

  @override
  Iterable<String> parentsOf(String childId) => _parents[childId] ?? const [];
}

class MatrixTranslationAdapter {
  final TranslationService service;

  MatrixTranslationAdapter(this.service);

  final Map<String, (int, DateTime, ClientTranslationHierarchy)> _hierarchies =
      {};
  final Map<String, (int, DateTime, TranslationRoomContext)> _contexts = {};

  static const Duration _hierarchyTtl = Duration(seconds: 30);

  ClientTranslationHierarchy hierarchyFor(Client client) {
    var cached = _hierarchies[client.identifier];
    var now = DateTime.now();
    if (cached != null &&
        cached.$1 == service.policyGeneration &&
        now.difference(cached.$2) < _hierarchyTtl) {
      return cached.$3;
    }
    var hierarchy = ClientTranslationHierarchy(client);
    _hierarchies[client.identifier] = (
      service.policyGeneration,
      now,
      hierarchy,
    );
    return hierarchy;
  }

  /// Encrypted rooms, direct chats and very small rooms count as protected.
  /// When uncertain we err on the side of protection.
  static bool isProtectedRoom(Room room) {
    if (room.isE2EE) return true;

    var dms = room.client.getComponent<DirectMessagesComponent>();
    if (dms?.isRoomDirectMessage(room) == true) return true;

    if (room is MatrixRoom) {
      var mx = room.matrixRoom;
      if (mx.isDirectChat) return true;
      // Bridged one-to-one chats usually contain the user, the remote ghost
      // and a bridge bot. Use the server provided count where available,
      // the locally loaded member list may be incomplete.
      var joined = mx.summary.mJoinedMemberCount;
      if (joined != null) return joined <= 3;
      return mx.getParticipants([matrix.Membership.join]).length <= 3;
    }

    return true;
  }

  TranslationRoomContext contextFor(Room room) {
    var id = "${room.client.identifier}\u0000${room.identifier}";
    var cached = _contexts[id];
    var now = DateTime.now();
    if (cached != null &&
        cached.$1 == service.policyGeneration &&
        now.difference(cached.$2) < _hierarchyTtl) {
      return cached.$3;
    }

    var accountId = room.client.identifier;
    var policy = TranslationPolicyResolver.resolve(
      roomId: room.identifier,
      room: service.settings.roomSettings(accountId, room.identifier),
      spaces: (spaceId) => service.settings.spaceSettings(accountId, spaceId),
      hierarchy: hierarchyFor(room.client),
      global: service.settings.globalDefaults,
      isProtected: isProtectedRoom(room),
    );

    var context = TranslationRoomContext(
      accountId: accountId,
      roomId: room.identifier,
      policy: policy,
    );
    _contexts[id] = (service.policyGeneration, now, context);
    return context;
  }

  /// Policy for a room computed fresh, for settings pages.
  EffectiveTranslationPolicy policyFor(Room room) {
    _contexts.remove("${room.client.identifier}\u0000${room.identifier}");
    _hierarchies.remove(room.client.identifier);
    return contextFor(room).policy;
  }

  static MessageRef refFor(Room room, TimelineEvent event) =>
      MessageRef(room.client.identifier, room.identifier, event.eventId);

  /// Extract the translatable text of a message as currently displayed
  /// (i.e. taking edits into account).
  static TranslatableExtraction extract(
    TimelineEvent event, {
    required dynamic timeline,
    int maxCodePoints = 500,
  }) {
    if (event is! MatrixTimelineEventMessage) {
      return const TranslatableExtraction.skip(
        TranslationSkipReason.unsupportedMessageType,
      );
    }

    var display = event.getDisplayEvent(timeline);

    if (display.redacted || event.event.redacted) {
      return const TranslatableExtraction.skip(
        TranslationSkipReason.noNaturalLanguage,
      );
    }

    var msgtype = display.messageType;
    var hasAttachment =
        display.content.containsKey("url") || display.content["file"] is Map;

    // Raw body, not plaintextBody: the latter is derived from HTML.
    String body = event.stripFallback(display.text, timeline: timeline);

    String? formatted;
    if (display.content.tryGet<String>("format") == "org.matrix.custom.html") {
      var html = display.content.tryGet<String>("formatted_body");
      if (html != null) {
        formatted = event.stripFallbackHtml(html, timeline: timeline);
      }
    }

    // Edits replace the content with m.new_content, which carries no
    // relation, so check the original event too.
    bool isReplyEvent(matrix.Event e) =>
        e.inReplyToEventId() != null ||
        e.content.tryGetMap<String, Object?>(
              "m.relates_to",
            )?["m.in_reply_to"] !=
            null;
    var isReply = isReplyEvent(display) || isReplyEvent(event.event);

    return TranslatableContentExtractor.extract(
      body: body,
      formattedBody: formatted,
      msgtype: msgtype,
      hasAttachment: hasAttachment,
      isReply: isReply,
      maxCodePoints: maxCodePoints,
    );
  }
}
