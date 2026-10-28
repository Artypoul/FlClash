import 'dart:async';

import 'package:flashco/common/personal_defaults.dart';
import 'package:flashco/common/preferences.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://example.invalid/subscription';
const _existing = Config(
  currentProfileId: 42,
  excludeSSIDs: ['home'],
  themeProps: ThemeProps(
    themeMode: ThemeMode.dark,
    primaryColor: 0xff123456,
    fontFamily: 'Missing Font',
  ),
  appSettingProps: AppSettingProps(locale: 'en', autoRun: false),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() async {
    final store = await SharedPreferences.getInstance();
    await store.clear();
  });

  test(
    'personal update persists light and auto-run without replacing data',
    () async {
      final updated = await initializePersonalDefaults(
        _existing,
        subscriptionUrl: _url,
        enabled: true,
      );

      expect(updated.themeProps.themeMode, ThemeMode.light);
      expect(updated.themeProps.fontFamily, isNull);
      expect(updated.appSettingProps.autoRun, isTrue);
      expect(updated.appSettingProps.locale, 'ru');
      expect(updated.networkProps.systemProxy, isFalse);
      expect(updated.networkProps.bypassPrivateRoute, isTrue);
      expect(updated.vpnProps.systemProxy, isFalse);
      expect(updated.vpnProps.allowBypass, isFalse);
      expect(updated.patchClashConfig.mode, Mode.rule);
      expect(updated.patchClashConfig.tun.enable, isTrue);
      expect(updated.patchClashConfig.tun.autoRoute, isTrue);
      expect(updated.patchClashConfig.tun.stack, TunStack.mips);
      expect(updated.patchClashConfig.tun.strictRoute, isTrue);
      expect(updated.currentProfileId, 42);
      expect(updated.excludeSSIDs, ['home']);
      expect(updated.themeProps.primaryColor, 0xff123456);
      expect(updated.appSettingProps.locale, 'ru');
      expect(await preferences.getConfig(), updated);
    },
  );

  test(
    'later launches preserve a manual dark theme and disabled auto-run',
    () async {
      await initializePersonalDefaults(
        _existing,
        subscriptionUrl: _url,
        enabled: true,
      );
      await preferences.saveConfig(_existing);

      final reloaded = await initializePersonalDefaults(
        _existing,
        subscriptionUrl: _url,
        enabled: true,
      );

      expect(reloaded, _existing);
      expect(await preferences.getConfig(), _existing);
    },
  );

  test(
    'fresh personal install persists auto-run before importing a profile',
    () async {
      final updated = await initializePersonalDefaults(
        const Config(themeProps: ThemeProps()),
        subscriptionUrl: _url,
        enabled: true,
      );

      expect(updated.currentProfileId, isNull);
      expect(updated.themeProps.themeMode, ThemeMode.light);
      expect(updated.appSettingProps.autoRun, isTrue);
    },
  );

  test('changing a bundled URL does not reset later manual choices', () async {
    await initializePersonalDefaults(
      _existing,
      subscriptionUrl: _url,
      enabled: true,
    );
    await preferences.saveConfig(_existing);

    final reloaded = await initializePersonalDefaults(
      _existing,
      subscriptionUrl: 'https://example.invalid/other-subscription',
      enabled: true,
    );

    expect(reloaded, _existing);
    expect(await preferences.getConfig(), _existing);
  });

  test(
    'safe mode and unsupported platforms leave settings and marker untouched',
    () async {
      expect(
        await initializePersonalDefaults(
          _existing,
          subscriptionUrl: _url,
          enabled: false,
        ),
        _existing,
      );
      expect(await preferences.getConfig(), isNull);
      final updated = await initializePersonalDefaults(
        _existing,
        subscriptionUrl: _url,
        enabled: true,
      );
      expect(updated.appSettingProps.autoRun, isTrue);
    },
  );

  test('generic and invalid builds do not change settings', () async {
    for (final url in ['', 'invalid', 'https://', 'file:///subscription']) {
      expect(
        await initializePersonalDefaults(
          _existing,
          subscriptionUrl: url,
          enabled: true,
        ),
        _existing,
      );
    }
    expect(await preferences.getConfig(), isNull);
  });

  test(
    'unavailable preferences cannot mark the defaults as complete',
    () async {
      final previous = preferences.sharedPreferencesCompleter;
      preferences.sharedPreferencesCompleter = Completer()..complete(null);
      try {
        expect(
          await initializePersonalDefaults(
            _existing,
            subscriptionUrl: _url,
            enabled: true,
          ),
          _existing,
        );
      } finally {
        preferences.sharedPreferencesCompleter = previous;
      }
      final updated = await initializePersonalDefaults(
        _existing,
        subscriptionUrl: _url,
        enabled: true,
      );
      expect(updated.appSettingProps.autoRun, isTrue);
    },
  );
}
