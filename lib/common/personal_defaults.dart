import 'package:flashco/common/preferences.dart';
import 'package:flashco/models/models.dart';
import 'package:material_ui/material_ui.dart';

Future<Config> initializePersonalDefaults(
  Config config, {
  required String subscriptionUrl,
  required bool enabled,
}) async {
  final url = subscriptionUrl.trim();
  final uri = Uri.tryParse(url);
  if (!enabled ||
      uri == null ||
      uri.host.isEmpty ||
      !const ['https', 'http'].contains(uri.scheme) ||
      !await preferences.isInit ||
      await preferences.werePersonalDefaultsApplied()) {
    return config;
  }
  final updated = config.copyWith(
    themeProps: config.themeProps.copyWith(themeMode: ThemeMode.light),
    appSettingProps: config.appSettingProps.copyWith(autoRun: true),
  );
  if (!await preferences.saveConfig(updated)) {
    throw StateError('Failed to save personal startup defaults');
  }
  await preferences.markPersonalDefaultsApplied();
  return updated;
}
