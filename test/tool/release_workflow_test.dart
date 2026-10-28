import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('manual release workflow contract', () {
    test('accepts only a manually selected stable release tag', () {
      final workflow = _workflow();
      final triggers = _map(workflow['on']);
      final dispatch = _map(triggers['workflow_dispatch']);
      final inputs = _map(dispatch['inputs']);
      final tag = _map(inputs['release_tag']);
      final concurrency = _map(workflow['concurrency']);

      expect(workflow['name'], 'release');
      expect(workflow['run-name'], r'release-${{ inputs.release_tag }}');
      expect(triggers.keys, ['workflow_dispatch']);
      expect(inputs.keys, ['release_tag']);
      expect(tag['required'], isTrue);
      expect(concurrency['group'], r'release-${{ inputs.release_tag }}');
      expect(concurrency['queue'], 'max');
      expect(concurrency['cancel-in-progress'], isFalse);
    });

    test(
      'isolates metadata checks, signing credentials, and write permission',
      () {
        final workflow = _workflow();
        final rootPermissions = _map(workflow['permissions']);
        final jobs = _map(workflow['jobs']);
        final preflight = _map(jobs['preflight']);
        final android = _map(jobs['android']);
        final publish = _map(jobs['publish']);
        final preflightSteps = _steps(preflight);
        final androidSteps = _steps(android);

        expect(rootPermissions, {'contents': 'read', 'actions': 'read'});
        expect(jobs.keys.toSet(), {
          'preflight',
          'android',
          'windows',
          'bundle',
          'publish',
        });
        expect(preflight['if'], "github.ref == 'refs/heads/main'");
        expect(_map(publish['permissions'])['contents'], 'write');
        expect(android['environment'], 'flashco-release');
        expect(workflow['env'], isA<YamlMap>());
        expect(_map(workflow['env'])['ANDROID_CERT_SHA256'], contains('vars.'));

        final hookStep = preflightSteps.singleWhere(
          (step) => '${step['run']}'.contains('build_assets: false'),
        );
        expect('${hookStep['run']}', contains("b'    setup:'"));
        expect('${hookStep['run']}', contains("b'    rust_api:'"));
        expect('${hookStep['run']}', contains('source.count(before) != 1'));
        expect(
          preflightSteps.any(
            (step) => '${step['run']}'.contains('release_cli.dart preflight'),
          ),
          isTrue,
        );
        expect(
          preflightSteps.any(
            (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
          ),
          isFalse,
        );
        expect(
          _map(
            preflightSteps.singleWhere(
              (step) =>
                  '${step['uses']}'.startsWith('subosito/flutter-action@'),
            )['with'],
          )['cache'],
          isFalse,
        );
        final preflightCheckout = _map(
          preflightSteps.singleWhere(
            (step) => step['uses'] == 'actions/checkout@v4',
          )['with'],
        );
        expect(preflightCheckout['ref'], r'${{ github.sha }}');
        expect(preflightCheckout['fetch-depth'], 0);

        final signing = androidSteps.singleWhere(
          (step) => step['name'] == 'Prepare Android signing',
        );
        final signingEnv = _map(signing['env']);
        expect(signing['run'], 'java tool/PrepareAndroidSigning.java');
        expect(signingEnv.keys.toSet(), {
          'ANDROID_KEYSTORE_BASE64',
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_ALIAS',
          'ANDROID_KEY_PASSWORD',
        });
        expect(
          androidSteps.any(
            (step) =>
                step['name'] ==
                'Build universal stable APK (setup.dart rejects disabled asset hooks)',
          ),
          isTrue,
        );
        final cleanup = androidSteps.singleWhere(
          (step) =>
              step['name'] ==
              'Remove signing material and runner-local Android properties',
        );
        expect(cleanup['if'], 'always()');
        expect('${cleanup['run']}', contains('android/app/keystore.jks'));
        expect('${cleanup['run']}', contains('android/local.properties'));

        for (final entry in jobs.entries) {
          if (entry.key != 'publish') {
            expect(
              _map(_map(entry.value)['permissions'])['contents'],
              isNot('write'),
              reason: '${entry.key} must not have release write permission',
            );
          }
          final steps = _steps(_map(entry.value));
          final secretReferences = steps
              .where((step) => step['env'] is YamlMap)
              .expand((step) => _map(step['env']).values)
              .whereType<String>()
              .where((value) => value.contains('secrets.'));
          expect(entry.key == 'android' || secretReferences.isEmpty, isTrue);
        }
      },
    );

    test('packages only the verified source with native hooks enabled', () {
      final jobs = _map(_workflow()['jobs']);
      final workflowEnv = _map(_workflow()['env']);
      expect(workflowEnv['FLUTTER_VERSION'], '3.47.6');
      expect(workflowEnv['GO_VERSION'], '1.27.1');
      expect(workflowEnv['NDK_VERSION'], 'r28c');
      for (final jobId in ['android', 'windows', 'bundle', 'publish']) {
        final job = _map(jobs[jobId]);
        expect(
          job['runs-on'],
          jobId == 'windows' ? 'windows-2022' : 'ubuntu-24.04',
        );
        final steps = _steps(job);
        final checkout = _map(
          steps.singleWhere(
            (step) => step['uses'] == 'actions/checkout@v4',
          )['with'],
        );
        expect(
          checkout['ref'],
          r'${{ needs.preflight.outputs.source_sha }}',
          reason: '$jobId must use the source SHA verified by preflight',
        );
        expect(checkout['submodules'], 'recursive');
        expect(
          steps.any((step) => '${step['run']}'.contains('flutter pub get')),
          isTrue,
        );
        expect(
          steps.any((step) => '${step['run']}'.contains('build_assets: false')),
          isFalse,
          reason: '$jobId must retain the native build hooks',
        );
        expect(
          steps.any(
            (step) => '${step['run']}'.contains(
              'git diff --exit-code -- pubspec.yaml pubspec.lock',
            ),
          ),
          isTrue,
          reason: '$jobId must not change dependency declarations',
        );
        expect(
          steps.any((step) => '${step['uses']}'.startsWith('actions/cache@')),
          isFalse,
          reason: '$jobId must not cache runner contents',
        );
        for (final step in steps.where((step) {
          final action = '${step['uses']}';
          return action.startsWith('subosito/flutter-action@') ||
              action.startsWith('actions/setup-go@');
        })) {
          expect(_map(step['with'])['cache'], isFalse);
          if ('${step['uses']}'.startsWith('subosito/flutter-action@')) {
            expect(
              _map(step['with'])['flutter-version'],
              r'${{ env.FLUTTER_VERSION }}',
            );
          } else {
            expect(_map(step['with'])['go-version'], r'${{ env.GO_VERSION }}');
          }
        }
        final nativeCheck = steps.singleWhere(
          (step) => '${step['run']}'.contains('go version'),
        );
        expect('${nativeCheck['run']}', contains('rustc --version'));
        expect('${nativeCheck['run']}', contains('cargo --version'));
      }

      final androidSteps = _steps(_map(jobs['android']));
      final windowsSteps = _steps(_map(jobs['windows']));
      final ndk = androidSteps.singleWhere(
        (step) => step['uses'] == 'nttld/setup-ndk@v1',
      );
      expect(_map(ndk['with'])['ndk-version'], r'${{ env.NDK_VERSION }}');
      for (final jobId in ['bundle', 'publish']) {
        final step = _steps(_map(jobs[jobId])).singleWhere(
          (value) => value['name'] == 'Discover Android APK inspection tools',
        );
        final script = '${step['run']}';
        expect(
          script,
          contains('cmdline-tools/latest/bin/apkanalyzer'),
          reason: '$jobId must check the exact analyzer path used by the CLI',
        );
        expect(script, contains(r'"$version" =~ ^[0-9]+([.][0-9]+)*$'));
        expect(script, contains('sort -V -k1,1'));
        expect(script, contains('build-tools'));
      }
      expect(
        androidSteps.any(
          (step) => '${step['run']}'.contains('--targets apk --universal-apk'),
        ),
        isTrue,
      );
      expect(
        windowsSteps.any(
          (step) => '${step['run']}'.contains('--targets exe,zip'),
        ),
        isTrue,
      );
      final androidArtifact = androidSteps.singleWhere(
        (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
      );
      final windowsArtifact = windowsSteps.singleWhere(
        (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
      );
      expect(
        _map(androidArtifact['with'])['path'],
        r'dist/Flashco-${{ needs.preflight.outputs.release_version }}-android.apk',
      );
      expect(
        _map(windowsArtifact['with'])['path'],
        contains('windows-amd64-setup.exe'),
      );
      expect(
        _map(windowsArtifact['with'])['path'],
        contains('windows-amd64.zip'),
      );
      expect(_map(jobs['publish'])['permissions'], {
        'contents': 'write',
        'actions': 'read',
      });
    });

    test('saves a verified complete bundle before any draft publishing', () {
      final jobs = _map(_workflow()['jobs']);
      final bundle = _map(jobs['bundle']);
      final publish = _map(jobs['publish']);
      final bundleSteps = _steps(bundle);
      final publishSteps = _steps(publish);
      final bundleUpload = bundleSteps.singleWhere(
        (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
      );
      final bundleRecoveryDownload = bundleSteps.singleWhere(
        (step) => step['name'] == 'Download original bundle when recovering',
      );
      final bundleRecoveryConfig = _map(bundleRecoveryDownload['with']);
      final publishDownload = publishSteps.singleWhere(
        (step) => '${step['uses']}'.startsWith('actions/download-artifact@'),
      );
      final downloadConfig = _map(publishDownload['with']);

      expect(bundle['needs'], ['preflight', 'android', 'windows']);
      expect(
        bundleSteps.any(
          (step) => '${step['run']}'.contains('release_cli.dart bundle'),
        ),
        isTrue,
      );
      final bundleCommand = bundleSteps.singleWhere(
        (step) => '${step['run']}'.contains('release_cli.dart bundle'),
      );
      final bundleEnv = _map(bundleCommand['env']);
      expect(
        bundleEnv['BUILD_NUMBER'],
        r'${{ needs.preflight.outputs.build_number }}',
      );
      expect(bundleEnv.containsKey('RELEASE_BUILD_NUMBER'), isFalse);
      expect(bundleEnv.containsKey('GH_TOKEN'), isFalse);
      expect(
        bundleUpload['if'],
        "needs.preflight.outputs.recovery_action == 'build'",
      );
      expect(_map(bundleUpload['with'])['path'], 'build/release-bundle/');
      expect(
        bundleRecoveryDownload['if'],
        "needs.preflight.outputs.recovery_action == 'reuse'",
      );
      expect(
        bundleRecoveryConfig['run-id'],
        r'${{ needs.preflight.outputs.original_run_id }}',
      );
      expect(
        bundleRecoveryConfig['name'],
        r'${{ needs.preflight.outputs.bundle_artifact_name }}',
      );
      expect(publish['needs'], ['preflight', 'bundle']);
      expect(publish['if'], contains('!cancelled()'));
      expect(publish['if'], contains("needs.preflight.result == 'success'"));
      expect(publish['if'], contains("needs.bundle.result == 'success'"));
      expect(publish['outputs'], {
        'draft_release_id': r'${{ steps.release.outputs.draft_release_id }}',
        'draft_release_completed':
            r'${{ steps.release.outputs.draft_release_completed }}',
      });
      expect(
        downloadConfig['name'],
        r'${{ needs.preflight.outputs.bundle_artifact_name }}',
      );
      expect(
        downloadConfig['run-id'],
        r'${{ needs.preflight.outputs.original_run_id }}',
      );
      expect(
        publishSteps.any(
          (step) => '${step['run']}'.contains('release_cli.dart publish'),
        ),
        isTrue,
      );
      final publishCommand = publishSteps.singleWhere(
        (step) => '${step['run']}'.contains('release_cli.dart publish'),
      );
      final publishEnv = _map(publishCommand['env']);
      expect(
        publishEnv['BUILD_NUMBER'],
        r'${{ needs.preflight.outputs.build_number }}',
      );
      expect(publishEnv.containsKey('RELEASE_BUILD_NUMBER'), isFalse);
      expect(publishCommand['id'], 'release');
      expect(
        publishSteps.any(
          (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
        ),
        isFalse,
      );
    });
  });
}

YamlMap _workflow() =>
    loadYaml(File('.github/workflows/release.yaml').readAsStringSync())
        as YamlMap;

Map<Object?, Object?> _map(Object? value) => value as YamlMap;

List<Map<Object?, Object?>> _steps(Map<Object?, Object?> job) =>
    (job['steps'] as YamlList).map((step) => _map(step)).toList();
