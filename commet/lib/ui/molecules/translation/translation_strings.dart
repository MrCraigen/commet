// Strings for the message translation feature.
import 'package:intl/intl.dart';

class TranslationStrings {
  static String get labelTranslationSettings => Intl.message(
    "Translation",
    name: "labelTranslationSettings",
    desc: "Label for the translation settings page",
  );

  static String get labelTranslationEnableTitle => Intl.message(
    "Message translation",
    name: "labelTranslationEnableTitle",
    desc: "Title of the master switch for message translation",
  );

  static String get labelTranslationEnableDescription => Intl.message(
    "Translate messages with your own translation server. Original messages are never changed and translations are never sent to anyone.",
    name: "labelTranslationEnableDescription",
    desc: "Description of the master switch for message translation",
  );

  static String get labelTranslationServerTitle => Intl.message(
    "Translation server",
    name: "labelTranslationServerTitle",
    desc: "Header for the translation server section",
  );

  static String get labelTranslationServerUrl => Intl.message(
    "Server URL",
    name: "labelTranslationServerUrl",
    desc: "Label for the translation server URL field",
  );

  static String get labelTranslationApiKey => Intl.message(
    "API key",
    name: "labelTranslationApiKey",
    desc: "Label for the translation API key field",
  );

  static String get labelTranslationApiKeyStoredSecurely => Intl.message(
    "An API key is stored in the system keyring",
    name: "labelTranslationApiKeyStoredSecurely",
    desc: "Shown when the API key is stored in secure storage",
  );

  static String get labelTranslationApiKeySessionOnly => Intl.message(
    "No system keyring is available. The API key is only kept until Commet is closed.",
    name: "labelTranslationApiKeySessionOnly",
    desc: "Shown when the API key could not be stored in secure storage",
  );

  static String get labelTranslationApiKeyNotSet => Intl.message(
    "No API key set",
    name: "labelTranslationApiKeyNotSet",
    desc: "Shown when no API key is configured",
  );

  static String get labelTranslationApiKeyReplaceHint => Intl.message(
    "Enter a new key to replace the stored one",
    name: "labelTranslationApiKeyReplaceHint",
    desc: "Hint for the API key field when a key is already stored",
  );

  static String get promptTranslationSaveServer => Intl.message(
    "Save",
    name: "promptTranslationSaveServer",
    desc: "Button to save translation server settings",
  );

  static String get promptTranslationRemoveApiKey => Intl.message(
    "Remove key",
    name: "promptTranslationRemoveApiKey",
    desc: "Button to remove the stored translation API key",
  );

  static String get promptTranslationTestConnection => Intl.message(
    "Test connection",
    name: "promptTranslationTestConnection",
    desc: "Button to test the connection to the translation server",
  );

  static String get labelTranslationTestingConnection => Intl.message(
    "Testing connection…",
    name: "labelTranslationTestingConnection",
    desc: "Shown while testing the connection to the translation server",
  );

  static String get labelTranslationConnectionOk => Intl.message(
    "Connected, API key accepted",
    name: "labelTranslationConnectionOk",
    desc: "Shown when the translation server connection test succeeded",
  );

  static String get labelTranslationConnectionNotTested => Intl.message(
    "Connection not tested",
    name: "labelTranslationConnectionNotTested",
    desc: "Shown when the translation server connection has not been tested",
  );

  static String labelTranslationConnectionFailed(Object reason) => Intl.message(
    "Connection failed: $reason",
    name: "labelTranslationConnectionFailed",
    desc: "Shown when the translation server connection test failed",
    args: [reason],
  );

  static String labelTranslationServerModel(Object model) => Intl.message(
    "Model: $model",
    name: "labelTranslationServerModel",
    desc: "Shows the translation model reported by the server",
    args: [model],
  );

  static String labelTranslationServerVersion(Object version) => Intl.message(
    "API version: $version",
    name: "labelTranslationServerVersion",
    desc: "Shows the API version reported by the translation server",
    args: [version],
  );

  static String labelTranslationLanguageCount(Object count) => Intl.message(
    "$count supported languages",
    name: "labelTranslationLanguageCount",
    desc: "Number of languages supported by the translation server",
    args: [count],
  );

  static String get labelTranslationDefaultsTitle => Intl.message(
    "Defaults",
    name: "labelTranslationDefaultsTitle",
    desc: "Header for default translation settings",
  );

  static String get labelTranslationTargetLanguage => Intl.message(
    "Translate to",
    name: "labelTranslationTargetLanguage",
    desc: "Label for the target language selector",
  );

  static String get labelTranslationSourceLanguage => Intl.message(
    "Source language",
    name: "labelTranslationSourceLanguage",
    desc: "Label for the source language selector",
  );

  static String get labelTranslationAutoDetect => Intl.message(
    "Detect automatically",
    name: "labelTranslationAutoDetect",
    desc: "Option to automatically detect the source language",
  );

  static String labelTranslationInheritLanguage(Object language) =>
      Intl.message(
        "Inherited ($language)",
        name: "labelTranslationInheritLanguage",
        desc: "Language option meaning the inherited language is used",
        args: [language],
      );

  static String get labelTranslationAutoByDefaultTitle => Intl.message(
    "Translate all rooms automatically",
    name: "labelTranslationAutoByDefaultTitle",
    desc: "Title of the global automatic translation fallback toggle",
  );

  static String get labelTranslationAutoByDefaultDescription => Intl.message(
    "Applies to rooms without their own or a space setting. Encrypted and private conversations are never included.",
    name: "labelTranslationAutoByDefaultDescription",
    desc: "Description of the global automatic translation fallback toggle",
  );

  static String get labelTranslationCacheTitle => Intl.message(
    "Local cache",
    name: "labelTranslationCacheTitle",
    desc: "Header for the translation cache section",
  );

  static String labelTranslationCacheDescription(Object count) => Intl.message(
    "Translations are kept in memory only and disappear when Commet is closed. Cached translations: $count",
    name: "labelTranslationCacheDescription",
    desc: "Description of the local translation cache",
    args: [count],
  );

  static String get promptTranslationClearCache => Intl.message(
    "Clear translation cache",
    name: "promptTranslationClearCache",
    desc: "Button to clear the local translation cache",
  );

  static String get labelTranslationCacheCleared => Intl.message(
    "Translation cache cleared",
    name: "labelTranslationCacheCleared",
    desc: "Shown after the translation cache was cleared",
  );

  static String get labelTranslationPrivacyTitle => Intl.message(
    "Privacy",
    name: "labelTranslationPrivacyTitle",
    desc: "Header for the translation privacy section",
  );

  static String get labelTranslationPrivacyExplanation => Intl.message(
    "Only the text of a message and the language pair are sent to your translation server, never Matrix identifiers or credentials. Rooms are only translated automatically when you enable it for the room or one of its spaces. Encrypted and private conversations additionally require your explicit consent for each conversation. Your translation server may store translations in an unencrypted cache.",
    name: "labelTranslationPrivacyExplanation",
    desc: "Explanation of how message translation handles privacy",
  );

  static String get labelTranslationErrorInvalidUrl => Intl.message(
    "enter a valid https:// address",
    name: "labelTranslationErrorInvalidUrl",
    desc: "Error when the translation server URL is invalid",
  );

  static String get labelTranslationErrorUnavailable => Intl.message(
    "The translation server is unavailable",
    name: "labelTranslationErrorUnavailable",
    desc: "Error when the translation server can not be reached",
  );

  static String get labelTranslationErrorTls => Intl.message(
    "The secure connection to the translation server could not be verified",
    name: "labelTranslationErrorTls",
    desc: "Error when TLS certificate validation fails",
  );

  static String get labelTranslationErrorTimeout => Intl.message(
    "The translation server did not respond in time",
    name: "labelTranslationErrorTimeout",
    desc: "Error when a translation request timed out",
  );

  static String get labelTranslationErrorAuthentication => Intl.message(
    "The translation server rejected the API key",
    name: "labelTranslationErrorAuthentication",
    desc: "Error when the translation API key is rejected",
  );

  static String get labelTranslationErrorQueueFull => Intl.message(
    "The translation server is busy, try again shortly",
    name: "labelTranslationErrorQueueFull",
    desc: "Error when the translation server queue is full",
  );

  static String get labelTranslationErrorInvalidRequest => Intl.message(
    "The translation server rejected the request",
    name: "labelTranslationErrorInvalidRequest",
    desc: "Error when the translation server rejects a request",
  );

  static String get labelTranslationErrorUnsupportedLanguage => Intl.message(
    "The language of this message is not supported",
    name: "labelTranslationErrorUnsupportedLanguage",
    desc: "Error when the source language is not supported",
  );

  static String get labelTranslationErrorTooLong => Intl.message(
    "This message is too long to translate",
    name: "labelTranslationErrorTooLong",
    desc: "Error when a message is too long to translate",
  );

  static String get labelTranslationErrorBackend => Intl.message(
    "The translation server could not translate this message",
    name: "labelTranslationErrorBackend",
    desc: "Error when the translation backend fails",
  );

  static String get labelTranslationErrorInvalidResponse => Intl.message(
    "The translation could not be verified and was discarded",
    name: "labelTranslationErrorInvalidResponse",
    desc: "Error when the translation response is invalid or failed safety checks",
  );

  static String get labelTranslationErrorNotConfigured => Intl.message(
    "Translation is not configured",
    name: "labelTranslationErrorNotConfigured",
    desc: "Error when translation is not configured",
  );

  static String get labelTranslationErrorUnknown => Intl.message(
    "Translation failed",
    name: "labelTranslationErrorUnknown",
    desc: "Generic translation failure",
  );

  static String get labelTranslationSkipNoText => Intl.message(
    "This message contains no text to translate",
    name: "labelTranslationSkipNoText",
    desc: "Explains that a message has no natural language text",
  );

  static String get labelTranslationSkipFormatting => Intl.message(
    "This message contains formatting, such as code blocks or named links, that can not be translated safely yet",
    name: "labelTranslationSkipFormatting",
    desc: "Explains that a message contains unsupported formatting",
  );

  static String get labelTranslationSkipSpoiler => Intl.message(
    "Messages containing spoilers are not translated, so hidden content is not revealed",
    name: "labelTranslationSkipSpoiler",
    desc: "Explains that messages with spoilers are not translated",
  );

  static String get labelTranslationSkipMedia => Intl.message(
    "Media messages and captions are not translated yet",
    name: "labelTranslationSkipMedia",
    desc: "Explains that media messages are not translated",
  );

  static String get labelTranslationSkipMessageType => Intl.message(
    "This type of message can not be translated",
    name: "labelTranslationSkipMessageType",
    desc: "Explains that the message type is not supported",
  );

  static String labelTranslationSkipTooLong(Object max) => Intl.message(
    "This message is longer than the translation server accepts ($max characters). It will not be shortened.",
    name: "labelTranslationSkipTooLong",
    desc: "Explains that a message is too long to translate",
    args: [max],
  );

  static String labelTranslatedFrom(Object language) => Intl.message(
    "Translated from $language",
    name: "labelTranslatedFrom",
    desc: "Indicator shown below a translated message",
    args: [language],
  );

  static String get labelTranslated => Intl.message(
    "Translated",
    name: "labelTranslated",
    desc: "Indicator shown below a translated message when the source language is unknown",
  );

  static String get promptTranslationShowOriginal => Intl.message(
    "Show original",
    name: "promptTranslationShowOriginal",
    desc: "Prompt to show the original text of a translated message",
  );

  static String get promptTranslationShowTranslation => Intl.message(
    "Show translation",
    name: "promptTranslationShowTranslation",
    desc: "Prompt to show the translation of a message",
  );

  static String get labelTranslationInProgress => Intl.message(
    "Translating…",
    name: "labelTranslationInProgress",
    desc: "Shown while a message is being translated",
  );

  static String get labelTranslationQueued => Intl.message(
    "Waiting to translate…",
    name: "labelTranslationQueued",
    desc: "Shown while a message is waiting to be translated",
  );

  static String labelTranslationAlreadyInLanguage(Object language) =>
      Intl.message(
        "Already in $language",
        name: "labelTranslationAlreadyInLanguage",
        desc: "Shown when a message is already in the target language",
        args: [language],
      );

  static String get promptTranslationRetry => Intl.message(
    "Retry",
    name: "promptTranslationRetry",
    desc: "Prompt to retry a failed translation",
  );

  static String get promptTranslate => Intl.message(
    "Translate",
    name: "promptTranslate",
    desc: "Menu option to translate a message",
  );

  static String get promptTranslateTo => Intl.message(
    "Translate to…",
    name: "promptTranslateTo",
    desc: "Menu option to translate a message to a chosen language",
  );

  static String get promptRetryTranslation => Intl.message(
    "Retry translation",
    name: "promptRetryTranslation",
    desc: "Menu option to retry translating a message",
  );

  static String get labelTranslateMessageTitle => Intl.message(
    "Translate message",
    name: "labelTranslateMessageTitle",
    desc:
        "Title of the dialog for translating a message to a specific language",
  );

  static String get labelTranslationConsentTitle => Intl.message(
    "Translate a private conversation?",
    name: "labelTranslationConsentTitle",
    desc: "Title of the consent dialog for translating encrypted or private conversations",
  );

  static String labelTranslationConsentBody(Object server) => Intl.message(
    "This conversation is encrypted or private. Translating it sends the decrypted text of its messages to your translation server at $server. The server may store translations in an unencrypted cache. Using a self-hosted server does not by itself guarantee end-to-end confidentiality.",
    name: "labelTranslationConsentBody",
    desc: "Body of the consent dialog for translating encrypted or private conversations",
    args: [server],
  );

  static String get promptTranslationConsentAllow => Intl.message(
    "Allow for this conversation",
    name: "promptTranslationConsentAllow",
    desc:
        "Button to consent to translating an encrypted or private conversation",
  );

  static String get labelTranslationDisabledHint => Intl.message(
    "Message translation is turned off. Enable it in the app settings under Translation.",
    name: "labelTranslationDisabledHint",
    desc: "Shown when trying to translate while translation is disabled",
  );

  static String get labelTranslationAutoTitle => Intl.message(
    "Automatic translation",
    name: "labelTranslationAutoTitle",
    desc: "Header for the automatic translation setting of a room or space",
  );

  static String get labelTranslationModeInherit => Intl.message(
    "Inherit",
    name: "labelTranslationModeInherit",
    desc: "Automatic translation mode: use inherited setting",
  );

  static String get labelTranslationModeEnabled => Intl.message(
    "On",
    name: "labelTranslationModeEnabled",
    desc: "Automatic translation mode: enabled",
  );

  static String get labelTranslationModeDisabled => Intl.message(
    "Off",
    name: "labelTranslationModeDisabled",
    desc: "Automatic translation mode: disabled",
  );

  static String get labelTranslationRoomDescription => Intl.message(
    "Visible messages in this room are translated as you read. Originals stay available.",
    name: "labelTranslationRoomDescription",
    desc: "Description of room level automatic translation",
  );

  static String get labelTranslationSpaceDescription => Intl.message(
    "Applies to all rooms in this space, unless a room or a closer space has its own setting.",
    name: "labelTranslationSpaceDescription",
    desc: "Description of space level automatic translation",
  );

  static String labelTranslationEffectiveOn(
    Object source,
    Object target,
  ) => Intl.message(
    "Automatic translation is on: $source → $target",
    name: "labelTranslationEffectiveOn",
    desc: "Summary of the effective automatic translation policy when enabled",
    args: [source, target],
  );

  static String get labelTranslationEffectiveOff => Intl.message(
    "Automatic translation is off",
    name: "labelTranslationEffectiveOff",
    desc: "Summary of the effective automatic translation policy when disabled",
  );

  static String get labelTranslationOriginRoom => Intl.message(
    "Set for this room",
    name: "labelTranslationOriginRoom",
    desc: "Explains that the translation policy comes from the room",
  );

  static String labelTranslationOriginSpace(Object spaces) => Intl.message(
    "Inherited from: $spaces",
    name: "labelTranslationOriginSpace",
    desc: "Explains that the translation policy is inherited from spaces",
    args: [spaces],
  );

  static String labelTranslationOriginConflict(Object spaces) => Intl.message(
    "Conflicting settings in $spaces. Automatic translation is off until you choose a setting for this room.",
    name: "labelTranslationOriginConflict",
    desc: "Explains that parent spaces have conflicting translation settings",
    args: [spaces],
  );

  static String get labelTranslationOriginGlobal => Intl.message(
    "Using the app default",
    name: "labelTranslationOriginGlobal",
    desc: "Explains that the translation policy comes from the global default",
  );

  static String get labelTranslationOriginServiceDisabled => Intl.message(
    "Message translation is turned off in the app settings",
    name: "labelTranslationOriginServiceDisabled",
    desc: "Explains that the translation service is disabled",
  );

  static String get labelTranslationPrivateRoomTitle => Intl.message(
    "Encrypted or private conversation",
    name: "labelTranslationPrivateRoomTitle",
    desc: "Header for the privacy section of a protected room",
  );

  static String get labelTranslationPrivateRoomConsent => Intl.message(
    "Allow sending this conversation to the translation server",
    name: "labelTranslationPrivateRoomConsent",
    desc: "Toggle for consenting to translating a protected room",
  );

  static String get labelTranslationPrivateRoomBlocked => Intl.message(
    "Automatic translation needs both \"On\" for this room and your consent below. Space and app settings never apply to private conversations.",
    name: "labelTranslationPrivateRoomBlocked",
    desc: "Explains why automatic translation is blocked in a protected room",
  );

  static String get promptToggleAutoTranslation => Intl.message(
    "Auto-translate",
    name: "promptToggleAutoTranslation",
    desc: "Room menu toggle for automatic translation",
  );
}
