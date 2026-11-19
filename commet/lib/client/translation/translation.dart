import 'package:commet/client/translation/matrix_translation_adapter.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/client/translation/translation_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Entry point to the message translation feature. Kept in one place so the
/// rest of Commet only needs a couple of small hooks.
class Translation {
  static TranslationService? _service;
  static MatrixTranslationAdapter? _adapter;

  static TranslationService? get service => _service;
  static MatrixTranslationAdapter? get adapter => _adapter;

  static bool get isEnabled => _service?.isEnabled == true;

  static Future<void> init(
    SharedPreferences preferences, {
    String? defaultTargetLanguage,
  }) async {
    if (_service != null) return;
    var settings = TranslationSettingsStore(preferences);
    if (defaultTargetLanguage != null && defaultTargetLanguage.isNotEmpty) {
      settings.defaultTargetLanguage = defaultTargetLanguage;
    }
    var service = TranslationService(
      settings: settings,
      credentials: SecureTranslationCredentialStore(),
    );
    service.diagnosticLog = (message) => Log.w(message);
    await service.init();
    _service = service;
    _adapter = MatrixTranslationAdapter(service);
  }

  /// For tests.
  static void overrideForTesting(TranslationService? service) {
    _service = service;
    _adapter = service == null ? null : MatrixTranslationAdapter(service);
  }

  /// Called when an account logs out: forget its translations and its local
  /// room / space translation settings.
  static Future<void> onAccountRemoved(String accountId) async {
    await _service?.onAccountRemoved(accountId);
  }
}
