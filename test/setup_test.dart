import 'package:test/test.dart';

import '../setup.dart' as setup;

void main() {
  group('setup.dart', () {
    test('passes an explicit artifact template to the package command', () {
      expect(
        setup.createPackageArtifactArgs(
          'app_name: Flashco\nartifact_name: Flashco-{{build_name}}.{{ext}}\n',
        ),
        ['--artifact-name=Flashco-{{build_name}}.{{ext}}'],
      );
      expect(setup.createPackageArtifactArgs('app_name: Flashco\n'), isEmpty);
    });

    test('parses -v as verbose mode', () {
      final results = setup.createSetupArgParser().parse(['android', '-v']);

      expect(results['verbose'], isTrue);
      expect(results.rest, ['android']);
    });

    test('parses the universal APK option', () {
      final results = setup.createSetupArgParser().parse([
        'android',
        '--universal-apk',
      ]);

      expect(results['universal-apk'], isTrue);
      expect(results.rest, ['android']);
    });

    test('accepts dev application environment', () {
      final results = setup.createSetupArgParser().parse([
        'android',
        '--env',
        'dev',
      ]);

      expect(results['env'], 'dev');
    });

    test('Flutter build environment does not depend on Core SHA256', () {
      expect(setup.createBuildEnvironment('dev'), {'APP_ENV': 'dev'});
      expect(setup.createBuildEnvironment('stable'), {'APP_ENV': 'stable'});
    });

    test('omits verbose from flutter build args by default', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: false,
      );

      expect(args, ['dart-define-from-file=env.json', 'split-per-abi']);
    });

    test('adds verbose to flutter build args with -v', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: true,
      );

      expect(args, [
        'verbose',
        'dart-define-from-file=env.json',
        'split-per-abi',
      ]);
    });

    test('universal Android APK omits split-per-abi and keeps define file', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: false,
        universalApk: true,
      );

      expect(args, ['dart-define-from-file=env.json']);
    });

    test(
      'universal APK rejects architecture selection and non-Android targets',
      () {
        expect(
          setup.validateUniversalApkOptions(
            platform: 'android',
            androidArch: 'arm64',
            universalApk: true,
          ),
          isNotNull,
        );
        expect(
          setup.validateUniversalApkOptions(
            platform: 'windows',
            universalApk: true,
          ),
          isNotNull,
        );
        expect(
          setup.validateUniversalApkOptions(
            platform: 'android',
            androidArch: 'arm64',
          ),
          isNull,
        );
      },
    );

    test('Windows package arguments remain unchanged', () {
      expect(
        setup.createFlutterBuildArgs(platform: 'windows', verbose: false),
        ['dart-define-from-file=env.json'],
      );
      expect(setup.createPackageTargets('windows', null), 'exe,zip');
    });

    test('refuses to package while a native build hook is skipped', () {
      const pubspec = '''
hooks:
  user_defines:
    setup:
      build_assets: false
    rust_api:
      build_assets: true
''';

      expect(setup.packagesNotBuildingAssets(pubspec), ['setup']);
      expect(setup.packagesNotBuildingAssets('name: x\n'), isEmpty);
    });

    test('packages every Linux format on every architecture', () {
      expect(setup.createPackageTargets('linux', null), 'deb,appimage,rpm');
      expect(setup.createPackageTargets('linux', 'deb'), 'deb');
      expect(setup.createPackageTargets('macos', null), 'dmg');
    });

    test('downloads the appimagetool build matching the host', () {
      expect(setup.appImageToolArch('arm64'), 'aarch64');
      expect(setup.appImageToolArch('amd64'), 'x86_64');
    });
  });
}
