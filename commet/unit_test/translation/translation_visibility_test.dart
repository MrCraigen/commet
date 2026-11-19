import 'package:commet/client/translation/translation_cache.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/client/translation/translation_settings.dart';
import 'package:commet/ui/molecules/translation/translation_visibility_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingService extends TranslationService {
  _RecordingService(SharedPreferences prefs)
    : super(
        settings: TranslationSettingsStore(prefs),
        credentials: MemoryTranslationCredentialStore(),
      );

  List<MessageRef> lastVisible = [];
  int reports = 0;

  @override
  void setVisible(Object owner, List<MessageRef> refs) {
    reports++;
    lastVisible = refs;
  }

  @override
  void removeVisibilityOwner(Object owner) {
    lastVisible = [];
  }
}

class _Item extends StatefulWidget {
  const _Item(this.index, this.service);
  final int index;
  final TranslationService service;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  TranslationVisibilityTracker? tracker;
  late MessageRef ref = MessageRef("acc", "!r", "\$${widget.index}");

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    tracker = TranslationVisibilityTracker.of(context, widget.service);
    tracker?.register(ref, context);
  }

  @override
  void dispose() {
    tracker?.unregister(ref, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 100, child: Text("${widget.index}"));
}

void main() {
  testWidgets("only messages inside the viewport are reported", (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    var service = _RecordingService(await SharedPreferences.getInstance());
    var controller = ScrollController();

    await tester.binding.setSurfaceSize(const Size(400, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            // Build far beyond the viewport, like a timeline would.
            scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
            itemCount: 200,
            itemBuilder: (context, i) => _Item(i, service),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    var visible = service.lastVisible.map((r) => r.eventId).toSet();
    expect(visible, {for (var i = 0; i < 6; i++) "\$$i"});

    // Fast scrolling: reports only happen once scrolling settles.
    var before = service.reports;
    for (var i = 0; i < 20; i++) {
      controller.jumpTo(i * 300.0);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(service.reports, before);
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.reports, before + 1);
    visible = service.lastVisible.map((r) => r.eventId).toSet();
    expect(visible, {for (var i = 57; i < 63; i++) "\$$i"});

    // Offstage timelines report nothing.
    await tester.pumpWidget(
      MaterialApp(
        home: Offstage(
          child: ListView.builder(
            itemCount: 50,
            itemBuilder: (context, i) => _Item(i, service),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.lastVisible, isEmpty);
    service.dispose();
  });
}
