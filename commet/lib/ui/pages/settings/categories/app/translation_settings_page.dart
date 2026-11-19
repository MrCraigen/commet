import 'dart:async';

import 'package:commet/client/translation/http_translation_provider.dart';
import 'package:commet/client/translation/translation.dart';
import 'package:commet/client/translation/translation_provider.dart';
import 'package:commet/client/translation/translation_service.dart';
import 'package:commet/ui/molecules/translation/translation_strings.dart';
import 'package:commet/ui/molecules/translation/translation_ui.dart';
import 'package:commet/ui/pages/settings/categories/app/boolean_toggle.dart';
import 'package:flutter/material.dart';
import 'package:tiamat/tiamat.dart' as tiamat;

class TranslationSettingsPage extends StatefulWidget {
  const TranslationSettingsPage({super.key});

  @override
  State<TranslationSettingsPage> createState() =>
      _TranslationSettingsPageState();
}

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
  late final TextEditingController urlController;
  final TextEditingController keyController = TextEditingController();
  StreamSubscription? _sub;

  bool testing = false;
  ConnectionTestResult? lastTest;
  String? urlError;

  TranslationService get service => Translation.service!;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: service.settings.serverUrl);
    _sub = service.settings.onChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    urlController.dispose();
    keyController.dispose();
    super.dispose();
  }

  Future<bool> _saveServer() async {
    var url = urlController.text.trim();
    var parsed = HttpTranslationProvider.parseServerUrl(url);
    if (url.isNotEmpty && parsed == null) {
      setState(
        () => urlError = TranslationStrings.labelTranslationErrorInvalidUrl,
      );
      return false;
    }
    setState(() => urlError = null);

    var normalised = parsed?.toString() ?? "";
    if (normalised != service.settings.serverUrl) {
      await service.settings.setServerUrl(normalised);
      urlController.text = normalised;
      lastTest = null;
    }

    if (keyController.text.trim().isNotEmpty) {
      await service.setApiKey(keyController.text);
      keyController.clear();
      lastTest = null;
    }
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _test() async {
    if (!await _saveServer()) return;
    setState(() => testing = true);
    var result = await service.testConnection();
    if (!mounted) return;
    setState(() {
      testing = false;
      lastTest = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    var settings = service.settings;
    return Column(
      children: [
        tiamat.Panel(
          header: TranslationStrings.labelTranslationSettings,
          mode: tiamat.TileType.surfaceContainerLow,
          child: BooleanToggle(
            getValue: () => settings.enabled,
            setValue: (v) => settings.setEnabled(v),
            title: TranslationStrings.labelTranslationEnableTitle,
            description: TranslationStrings.labelTranslationEnableDescription,
            onChanged: (_) => setState(() {}),
          ),
        ),
        tiamat.Panel(
          header: TranslationStrings.labelTranslationServerTitle,
          mode: tiamat.TileType.surfaceContainerLow,
          child: _buildServer(context),
        ),
        tiamat.Panel(
          header: TranslationStrings.labelTranslationDefaultsTitle,
          mode: tiamat.TileType.surfaceContainerLow,
          child: _buildDefaults(context),
        ),
        tiamat.Panel(
          header: TranslationStrings.labelTranslationCacheTitle,
          mode: tiamat.TileType.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              tiamat.Text.labelLow(
                TranslationStrings.labelTranslationCacheDescription(
                  service.cache.length,
                ),
              ),
              const SizedBox(height: 8),
              tiamat.Button.secondary(
                text: TranslationStrings.promptTranslationClearCache,
                onTap: () {
                  service.clearCache();
                  setState(() {});
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        TranslationStrings.labelTranslationCacheCleared,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        tiamat.Panel(
          header: TranslationStrings.labelTranslationPrivacyTitle,
          mode: tiamat.TileType.surfaceContainerLow,
          child: tiamat.Text.labelLow(
            TranslationStrings.labelTranslationPrivacyExplanation,
          ),
        ),
      ],
    );
  }

  Widget _buildServer(BuildContext context) {
    var keyStatus = switch (service.apiKeyStorage) {
      ApiKeyStorage.secure =>
        TranslationStrings.labelTranslationApiKeyStoredSecurely,
      ApiKeyStorage.sessionOnly =>
        TranslationStrings.labelTranslationApiKeySessionOnly,
      ApiKeyStorage.none => TranslationStrings.labelTranslationApiKeyNotSet,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: TranslationStrings.labelTranslationServerUrl,
              hintText: "https://translate.example.com",
              errorText: urlError,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: keyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: TranslationStrings.labelTranslationApiKey,
              hintText: service.hasApiKey
                  ? TranslationStrings.labelTranslationApiKeyReplaceHint
                  : null,
            ),
          ),
        ),
        tiamat.Text.labelLow(keyStatus),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(
              width: 160,
              child: tiamat.Button.secondary(
                text: TranslationStrings.promptTranslationSaveServer,
                onTap: _saveServer,
              ),
            ),
            SizedBox(
              width: 200,
              child: tiamat.Button(
                text: TranslationStrings.promptTranslationTestConnection,
                isLoading: testing,
                onTap: testing ? null : _test,
              ),
            ),
            if (service.hasApiKey)
              SizedBox(
                width: 160,
                child: tiamat.Button.danger(
                  text: TranslationStrings.promptTranslationRemoveApiKey,
                  onTap: () async {
                    await service.clearApiKey();
                    if (mounted) setState(() => lastTest = null);
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _buildStatus(context),
      ],
    );
  }

  Widget _buildStatus(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var settings = service.settings;

    String status;
    Color color;
    IconData icon;

    if (testing) {
      status = TranslationStrings.labelTranslationTestingConnection;
      color = scheme.onSurfaceVariant;
      icon = Icons.sync;
    } else if (lastTest == null) {
      status = TranslationStrings.labelTranslationConnectionNotTested;
      color = scheme.onSurfaceVariant;
      icon = Icons.help_outline;
    } else if (lastTest!.success) {
      status = TranslationStrings.labelTranslationConnectionOk;
      color = scheme.primary;
      icon = Icons.check_circle_outline;
    } else {
      var reason = lastTest!.failedStep == ConnectionTestStep.url
          ? TranslationStrings.labelTranslationErrorInvalidUrl
          : TranslationUi.errorText(lastTest!.error);
      status = TranslationStrings.labelTranslationConnectionFailed(reason);
      color = scheme.error;
      icon = Icons.error_outline;
    }

    var model = lastTest?.model ?? settings.serverModel;
    var version = lastTest?.version ?? settings.serverVersion;
    var languageCount = settings.cachedLanguages.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(status, style: TextStyle(color: color)),
            ),
          ],
        ),
        if (model != null)
          tiamat.Text.labelLow(
            TranslationStrings.labelTranslationServerModel(model),
          ),
        if (version != null)
          tiamat.Text.labelLow(
            TranslationStrings.labelTranslationServerVersion(version),
          ),
        if (languageCount > 0)
          tiamat.Text.labelLow(
            TranslationStrings.labelTranslationLanguageCount(languageCount),
          ),
      ],
    );
  }

  Widget _buildDefaults(BuildContext context) {
    var settings = service.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tiamat.Text.labelEmphasised(
          TranslationStrings.labelTranslationTargetLanguage,
        ),
        const SizedBox(height: 4),
        TranslationLanguageDropdown(
          value: settings.targetLanguage,
          onChanged: (v) {
            if (v != null) settings.setTargetLanguage(v);
          },
        ),
        const SizedBox(height: 12),
        tiamat.Text.labelEmphasised(
          TranslationStrings.labelTranslationSourceLanguage,
        ),
        const SizedBox(height: 4),
        TranslationLanguageDropdown(
          value: settings.sourceLanguage,
          allowAuto: true,
          onChanged: (v) =>
              settings.setSourceLanguage(v ?? translationAutoSource),
        ),
        const SizedBox(height: 12),
        BooleanToggle(
          getValue: () => settings.autoTranslateByDefault,
          setValue: (v) => settings.setAutoTranslateByDefault(v),
          title: TranslationStrings.labelTranslationAutoByDefaultTitle,
          description:
              TranslationStrings.labelTranslationAutoByDefaultDescription,
        ),
      ],
    );
  }
}
