import 'package:flashco/common/preferences.dart';
import 'package:flashco/enum/enum.dart';
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
    appSettingProps: config.appSettingProps.copyWith(
      autoRun: true,
      locale: 'ru',
    ),
    networkProps: config.networkProps.copyWith(
      systemProxy: false,
      bypassPrivateRoute: true,
    ),
    vpnProps: config.vpnProps.copyWith(systemProxy: false, allowBypass: false),
    themeProps: config.themeProps.copyWith(
      themeMode: ThemeMode.light,
      fontFamily: null,
    ),
    patchClashConfig: config.patchClashConfig.copyWith(
      mode: Mode.rule,
      tun: config.patchClashConfig.tun.copyWith(
        enable: true,
        autoRoute: true,
        stack: TunStack.mips,
        strictRoute: true,
      ),
    ),
  );
  if (!await preferences.saveConfig(updated)) {
    throw StateError('Failed to save personal startup defaults');
  }
  await preferences.markPersonalDefaultsApplied();
  return updated;
}
