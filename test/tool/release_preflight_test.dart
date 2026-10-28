import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_preflight.dart';

void main() {
  group('validateReleaseIdentity', () {
    test('accepts a matching stable tag and version with a positive build', () {
      expect(
        validateReleaseIdentity(
          tag: 'v1.2.3',
          version: '1.2.3',
          buildNumber: 12,
        ),
        isEmpty,
      );
    });

    test('rejects a tag that does not match the stable version', () {
      expect(
        validateReleaseIdentity(
          tag: 'v1.2.4',
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
    });

    test('rejects prerelease versions and nonpositive build numbers', () {
      expect(
        validateReleaseIdentity(
          tag: 'v1.2.3-rc.1',
          version: '1.2.3-rc.1',
          buildNumber: 0,
        ),
        isNotEmpty,
      );
    });

    test('rejects numeric components outside the supported integer range', () {
      final oversizedVersion = '${List.filled(100, '9').join()}.0.0';

      expect(
        validateReleaseIdentity(
          tag: 'v$oversizedVersion',
          version: oversizedVersion,
          buildNumber: 1,
        ),
        isNotEmpty,
      );
      expect(
        validatePublishedUpgrade(
          version: '1.0.0',
          buildNumber: 2,
          publishedVersion: oversizedVersion,
          publishedBuildNumber: 1,
        ),
        isNotEmpty,
      );
    });
  });

  group('validatePublishedUpgrade', () {
    test('accepts an initial release when published history is empty', () {
      expect(
        validatePublishedUpgrade(
          version: '1.0.0',
          buildNumber: 1,
          publishedVersion: null,
          publishedBuildNumber: null,
        ),
        isEmpty,
      );
    });

    test('rejects incomplete published history', () {
      expect(
        validatePublishedUpgrade(
          version: '1.0.0',
          buildNumber: 1,
          publishedVersion: '0.9.0',
          publishedBuildNumber: null,
        ),
        isNotEmpty,
      );
    });

    test('requires both version and build number to increase', () {
      expect(
        validatePublishedUpgrade(
          version: '1.0.0',
          buildNumber: 8,
          publishedVersion: '0.9.9',
          publishedBuildNumber: 8,
        ),
        isNotEmpty,
      );
      expect(
        validatePublishedUpgrade(
          version: '0.9.9',
          buildNumber: 9,
          publishedVersion: '1.0.0',
          publishedBuildNumber: 8,
        ),
        isNotEmpty,
      );
    });
  });

  group('validatePublicBuildDefines', () {
    test('accepts stable public defines without subscription or safe mode', () {
      expect(
        validatePublicBuildDefines({
          'APP_ENV': 'stable',
          'BOOTSTRAP_SUBSCRIPTION_URL': '',
          'SAFE_MODE': 'false',
        }),
        isEmpty,
      );
    });

    test(
      'rejects a personal subscription, nonstable environment, or safe mode',
      () {
        expect(
          validatePublicBuildDefines({
            'APP_ENV': 'dev',
            'BOOTSTRAP_SUBSCRIPTION_URL': 'private-value',
            'SAFE_MODE': 'true',
          }),
          isNotEmpty,
        );
      },
    );
  });

  group('validateAndroidIdentity', () {
    final validMetadata = <String, Object?>{
      'packageName': 'com.follow.flashco',
      'versionName': '1.2.3',
      'versionCode': 12,
      'signerSha256': 'ab' * 32,
      'abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
      'debuggable': false,
      'testOnly': false,
    };

    test('accepts the expected package, signature, version, and ABI set', () {
      expect(
        validateAndroidIdentity(
          metadata: validMetadata,
          expectedSignerSha256: List.filled(32, 'AB').join(':'),
          version: '1.2.3',
          buildNumber: 12,
        ),
        isEmpty,
      );
    });

    test('rejects development package and wrong signer', () {
      expect(
        validateAndroidIdentity(
          metadata: {...validMetadata, 'packageName': 'com.follow.flashco.dev'},
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateAndroidIdentity(
          metadata: validMetadata,
          expectedSignerSha256: 'cd' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateAndroidIdentity(
          metadata: validMetadata,
          expectedSignerSha256: 'missing-signer',
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
    });

    test('rejects missing required ABI and debug or test-only APKs', () {
      expect(
        validateAndroidIdentity(
          metadata: {
            ...validMetadata,
            'abis': ['arm64-v8a', 'x86_64'],
          },
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateAndroidIdentity(
          metadata: {...validMetadata, 'debuggable': true},
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateAndroidIdentity(
          metadata: {...validMetadata, 'testOnly': true},
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
    });

    test('rejects absent and wrongly typed metadata fields', () {
      final incomplete = Map<String, Object?>.from(validMetadata)
        ..remove('testOnly');
      final wronglyTyped = {...validMetadata, 'versionCode': '12'};

      expect(
        validateAndroidIdentity(
          metadata: incomplete,
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateAndroidIdentity(
          metadata: wronglyTyped,
          expectedSignerSha256: 'ab' * 32,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
    });

    test('rejects the real development APK metadata fixture', () {
      final metadata =
          jsonDecode(
                File(
                  'test/fixtures/release/android-dev-metadata.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      expect(
        validateAndroidIdentity(
          metadata: metadata,
          expectedSignerSha256: 'ab' * 32,
          version: '0.9.0',
          buildNumber: 2026101401,
        ),
        isNotEmpty,
      );
    });
  });

  group('runReleasePreflight', () {
    test(
      'rejects incomplete history and never prints private define values',
      () {
        final directory = Directory.systemTemp.createTempSync(
          'release-preflight-',
        );
        final inputFile = File('${directory.path}/input.json');
        const privateValue = 'private-subscription-value';
        inputFile.writeAsStringSync(
          jsonEncode({
            ..._validPreflightInput(),
            'defines': {
              'APP_ENV': 'stable',
              'BOOTSTRAP_SUBSCRIPTION_URL': privateValue,
            },
            'publishedHistory': {
              'complete': false,
              'highestVersion': null,
              'highestBuildNumber': null,
            },
          }),
        );
        final outputLines = <String>[];
        final errorLines = <String>[];

        final result = runReleasePreflight(
          ['--input', inputFile.path],
          writeOutput: outputLines.add,
          writeError: errorLines.add,
        );

        expect(result, 1);
        expect(outputLines, isEmpty);
        expect(errorLines.join('\n'), contains('history must be complete'));
        expect(errorLines.join('\n'), isNot(contains(privateValue)));
        directory.deleteSync(recursive: true);
      },
    );

    test('rejects missing required CLI metadata fields', () {
      final directory = Directory.systemTemp.createTempSync(
        'release-preflight-',
      );
      final inputFile = File('${directory.path}/input.json');
      final input = _validPreflightInput()..remove('expectedSignerSha256');
      inputFile.writeAsStringSync(jsonEncode(input));
      final errorLines = <String>[];

      final result = runReleasePreflight([
        '--input',
        inputFile.path,
      ], writeError: errorLines.add);

      expect(result, 1);
      expect(
        errorLines.join('\n'),
        contains('Expected Android signer fingerprint'),
      );
      directory.deleteSync(recursive: true);
    });

    test('rejects an oversized published version without echoing it', () {
      final directory = Directory.systemTemp.createTempSync(
        'release-preflight-',
      );
      final inputFile = File('${directory.path}/input.json');
      final oversizedVersion = List.filled(100, '9').join();
      inputFile.writeAsStringSync(
        jsonEncode({
          ..._validPreflightInput(),
          'publishedHistory': {
            'complete': true,
            'highestVersion': '$oversizedVersion.0.0',
            'highestBuildNumber': 11,
          },
        }),
      );
      final errorLines = <String>[];

      final result = runReleasePreflight([
        '--input',
        inputFile.path,
      ], writeError: errorLines.add);

      expect(result, 1);
      expect(
        errorLines.join('\n'),
        contains('Published release history is invalid'),
      );
      expect(errorLines.join('\n'), isNot(contains(oversizedVersion)));
      directory.deleteSync(recursive: true);
    });
  });
}

Map<String, Object?> _validPreflightInput() => {
  'tag': 'v1.2.3',
  'version': '1.2.3',
  'buildNumber': 12,
  'defines': {
    'APP_ENV': 'stable',
    'BOOTSTRAP_SUBSCRIPTION_URL': '',
    'SAFE_MODE': 'false',
  },
  'publishedHistory': {
    'complete': true,
    'highestVersion': null,
    'highestBuildNumber': null,
  },
  'expectedSignerSha256': 'ab' * 32,
  'androidMetadata': {
    'packageName': 'com.follow.flashco',
    'versionName': '1.2.3',
    'versionCode': 12,
    'signerSha256': 'ab' * 32,
    'abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    'debuggable': false,
    'testOnly': false,
  },
};
