import 'dart:convert';
import 'dart:io';

import 'package:flashco/bootstrap.dart';
import 'package:flashco/common/common.dart';
import 'package:flashco/providers/app.dart';
import 'package:flashco/providers/config.dart';
import 'package:flashco/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

final _packageInfo = PackageInfo(
  appName: 'Flashco',
  packageName: 'com.follow.flashco',
  version: '1.2.3',
  buildNumber: '1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUpAll(() {
    globalState.packageInfo = _packageInfo;
  });

  setUp(() {
    container = ProviderContainer();
    globalState.container = container;
  });

  tearDown(() {
    container.dispose();
    globalState.isAttach = false;
  });

  void setGlobalUa(String value) {
    container
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(globalUa: value));
  }

  group('user agent', () {
    test(
      'Flashco has its own installation and compatible subscription identity',
      () {
        expect(appName, 'Flashco');
        expect(appInstallationName, 'Flashco');
        expect(packageName, 'com.follow.flashco');
        expect(defaultTunDeviceName, 'Flashco');
        expect(repository, 'Artypoul/Flashco');
        expect(_packageInfo.ua, startsWith('mihomo Flashco/v1.2.3'));
      },
    );

    test('falls back to the package user agent when none is configured', () {
      setGlobalUa('');

      expect(globalState.ua, _packageInfo.ua);
      expect(globalState.ua, startsWith('mihomo Flashco/v1.2.3'));
    });

    test('negotiates Mihomo YAML with subscription response rules', () {
      final contract =
          jsonDecode(
                File(
                  'test/fixtures/subscription_response_rules.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final rules = contract['rules'] as List;
      final mihomoRule =
          rules.firstWhere((rule) => rule['responseType'] == 'MIHOMO')
              as Map<String, dynamic>;
      final condition =
          (mihomoRule['conditions'] as List).single as Map<String, dynamic>;
      final matcher = RegExp(
        condition['value'] as String,
        caseSensitive: condition['caseSensitive'] as bool,
      );
      setGlobalUa('');

      expect(matcher.hasMatch(globalState.ua), isTrue);
      expect(
        matcher.hasMatch('Flashco/v1.2.3 clash-verge Platform/windows'),
        isFalse,
      );
    });

    test('prefers the configured global user agent', () {
      setGlobalUa('custom-agent/1.0');

      expect(globalState.ua, 'custom-agent/1.0');
    });

    test('treats a blank configured user agent as unset', () {
      setGlobalUa('   ');

      expect(globalState.ua, _packageInfo.ua);
    });
  });

  group('attach', () {
    test('an already attached app never re-runs startup', () async {
      globalState.isAttach = true;

      await bootstrap.attach();

      expect(globalState.isAttach, isTrue);
      expect(
        container.read(initProvider),
        isFalse,
        reason: 'startup must not have run a second time',
      );
    });
  });

  group('canCrashCoreFor', () {
    test('allows a forced Core crash in debug and on the dev channel', () {
      expect(
        GlobalState.canCrashCoreFor(isDebug: true, appEnv: 'stable'),
        isTrue,
      );
      expect(
        GlobalState.canCrashCoreFor(isDebug: false, appEnv: 'dev'),
        isTrue,
      );
    });

    test('never allows a forced Core crash in a release build', () {
      expect(
        GlobalState.canCrashCoreFor(isDebug: false, appEnv: 'stable'),
        isFalse,
      );
      expect(
        GlobalState.canCrashCoreFor(isDebug: false, appEnv: 'pre'),
        isFalse,
      );
    });
  });
}
