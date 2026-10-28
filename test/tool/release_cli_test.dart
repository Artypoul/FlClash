import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import '../../tool/release_bundle.dart';
import '../../tool/release_cli.dart';
import '../../tool/release_publisher.dart';

const _sourceSha = '83089903cc33bbfb720af5e7ec37ba58cef5474e';
const _futureSha = 'dddddddddddddddddddddddddddddddddddddddd';
const _tag = 'v0.9.0';
const _fingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('ReleaseCli preflight', () {
    test(
      'checks source, latest build jobs, history, and candidate run provenance',
      () async {
        final runner = _FixtureRunner();
        final cli = ReleaseCli(
          environment: _environment(),
          runner: runner.call,
        );

        final result = await cli.run(['preflight']);

        expect(
          result.exitCode,
          0,
          reason: '${result.error}\n${runner.calls.join('\n')}',
        );
        expect(result.output, {
          'source_sha': _sourceSha,
          'release_version': '0.9.0',
          'build_number': '2026101401',
          'recovery_action': 'build',
          'original_run_id': '501',
          'original_run_attempt': '1',
          'bundle_artifact_name':
              'flashco-release-bundle-v0.9.0-run-501-attempt-1',
        });
        expect(
          runner.calls.every(
            (call) =>
                !call.contains('--repo') || call.contains('Artypoul/Flashco'),
          ),
          isTrue,
        );
        expect(
          runner.calls.any((call) => call.contains('releases?per_page=100')),
          isTrue,
        );
        expect(
          runner.calls.any((call) => call.contains('workflow_id')),
          isFalse,
        );
        final ghCalls = runner.calls
            .where((call) => call.startsWith('gh '))
            .toList();
        expect(ghCalls, isNotEmpty);
        expect(
          ghCalls.every((call) => call.contains('--hostname github.com')),
          isTrue,
        );
      },
    );

    test(
      'fails closed when a GitHub read returns 403 instead of treating it as empty',
      () async {
        final runner = _FixtureRunner(failReleases: true);
        final cli = ReleaseCli(
          environment: _environment(),
          runner: runner.call,
        );

        final result = await cli.run(['preflight']);

        expect(result.exitCode, 1);
        expect(result.error, 'A required GitHub API read failed.');
        expect(result.error, isNot(contains('403')));
        expect(
          runner.calls.any(
            (call) => call.contains('workflow_runs?event=workflow_dispatch'),
          ),
          isFalse,
        );
      },
    );

    test('rejects a malformed build response before selecting a run', () async {
      final runner = _FixtureRunner(malformedRuns: true);
      final cli = ReleaseCli(environment: _environment(), runner: runner.call);

      final result = await cli.run(['preflight']);

      expect(result.exitCode, 1);
      expect(result.error, 'The build run list response is incomplete.');
    });

    test(
      'uses an earlier completed bundle attempt when the run shows a later attempt',
      () async {
        final runner = _FixtureRunner(priorAttemptTwo: true, currentRunId: 900);
        final result = await ReleaseCli(
          environment: _environment()
            ..['GITHUB_RUN_ID'] = '900'
            ..['GITHUB_RUN_ATTEMPT'] = '1',
          runner: runner.call,
        ).run(['preflight']);

        expect(
          result.exitCode,
          0,
          reason: '${result.error}\n${runner.calls.join('\n')}',
        );
        expect(result.output['recovery_action'], 'reuse');
        expect(result.output['original_run_id'], '700');
        expect(result.output['original_run_attempt'], '1');
        expect(
          result.output['bundle_artifact_name'],
          'flashco-release-bundle-v0.9.0-run-700-attempt-1',
        );
      },
    );

    test(
      'rejects an invalid artifact record even beside a valid recovery candidate',
      () async {
        final result = await ReleaseCli(
          environment: _environment()
            ..['GITHUB_RUN_ID'] = '900'
            ..['GITHUB_RUN_ATTEMPT'] = '1',
          runner: _FixtureRunner(
            priorAttemptTwo: true,
            currentRunId: 900,
            malformedArtifact: true,
          ).call,
        ).run(['preflight']);

        expect(result.exitCode, 1);
      },
    );

    test(
      'rejects duplicate expected bundle artifacts instead of selecting another attempt',
      () async {
        final result = await ReleaseCli(
          environment: _environment()
            ..['GITHUB_RUN_ID'] = '900'
            ..['GITHUB_RUN_ATTEMPT'] = '1',
          runner: _FixtureRunner(
            priorAttemptTwo: true,
            currentRunId: 900,
            duplicateExpectedArtifact: true,
          ).call,
        ).run(['preflight']);

        expect(result.exitCode, 1);
      },
    );

    test('uses the greater run ID to break equal build timestamps', () async {
      final runner = _FixtureRunner(equalBuildTimestamps: true);

      final result = await ReleaseCli(
        environment: _environment(),
        runner: runner.call,
      ).run(['preflight']);

      expect(result.exitCode, 0, reason: result.error);
      expect(
        runner.calls.any(
          (call) => call.contains('/actions/runs/38913914850/jobs?'),
        ),
        isTrue,
      );
    });

    test(
      'rejects duplicate run records and untitled prior workflows',
      () async {
        for (final runner in [
          _FixtureRunner(duplicateBuildRun: true),
          _FixtureRunner(untitledPriorRun: true),
        ]) {
          final result = await ReleaseCli(
            environment: _environment(),
            runner: runner.call,
          ).run(['preflight']);
          expect(result.exitCode, 1);
        }
      },
    );

    test('validates run number counters before filtering prior runs', () async {
      for (final runner in [
        _FixtureRunner(duplicateRunNumber: true),
        _FixtureRunner(mismatchedCurrentRunNumber: true),
        _FixtureRunner(invalidRunNumber: true),
      ]) {
        final result = await ReleaseCli(
          environment: _environment(),
          runner: runner.call,
        ).run(['preflight']);
        expect(result.exitCode, 1);
      }
    });

    test(
      'rejects a zero-page release response instead of accepting empty history',
      () async {
        final result = await ReleaseCli(
          environment: _environment(),
          runner: _FixtureRunner(zeroPageReleases: true).call,
        ).run(['preflight']);

        expect(result.exitCode, 1);
        expect(result.error, 'A GitHub API response was incomplete.');
      },
    );

    test(
      'ignores a future queued same-tag run on repeated preflight',
      () async {
        final runner = _FixtureRunner(futureQueuedRun: true);
        final cli = ReleaseCli(
          environment: _environment(),
          runner: runner.call,
        );

        final first = await cli.run(['preflight']);
        final second = await cli.run(['preflight']);

        expect(first.exitCode, 0, reason: first.error);
        expect(first.output['recovery_action'], 'build');
        expect(second.exitCode, 0, reason: second.error);
        expect(second.output['recovery_action'], 'build');
        expect(runner.calls.any((call) => call.contains(_futureSha)), isFalse);
      },
    );

    test(
      'selects an earlier bundle and excludes a later queued same-tag run',
      () async {
        final environment = _environment()..['GITHUB_RUN_ATTEMPT'] = '2';
        final runner = _FixtureRunner(
          futureQueuedAfterBundle: true,
          currentAttempt: 2,
        );

        final result = await ReleaseCli(
          environment: environment,
          runner: runner.call,
        ).run(['preflight']);

        expect(result.exitCode, 0, reason: result.error);
        expect(result.output['recovery_action'], 'reuse');
        expect(result.output['original_run_id'], '501');
        expect(result.output['original_run_attempt'], '1');
        expect(runner.calls.any((call) => call.contains(_futureSha)), isFalse);
      },
    );

    test(
      'rejects non-main dispatch and invalid public fingerprint before any command',
      () async {
        for (final environment in [
          _environment()..['GITHUB_REF'] = 'refs/heads/feature',
          _environment()..['ANDROID_CERT_SHA256'] = 'invalid',
        ]) {
          final runner = _FixtureRunner();
          final result = await ReleaseCli(
            environment: environment,
            runner: runner.call,
          ).run(['preflight']);
          expect(result.exitCode, 1);
          expect(runner.calls, isEmpty);
        }
      },
    );

    test(
      'rejects publish without valid bundle context before any API call',
      () async {
        final runner = _FixtureRunner();
        final cli = ReleaseCli(
          environment: _environment(),
          runner: runner.call,
        );

        final result = await cli.run(['publish']);
        expect(result.exitCode, 1);
        expect(
          result.error,
          'Release bundle identity or recovery inputs are invalid.',
        );
        expect(runner.calls, isEmpty);
      },
    );

    test(
      'builds a synthetic six-file bundle from one APK and emits verified outputs',
      () async {
        final context = await _newBundleContext();
        try {
          await _writePayloads(context.bundleDirectory);
          final runner = _BundleRunner(_syntheticSdkOutputs());
          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 0, reason: result.error);
          expect(
            result.output['release_bundle_dir'],
            context.bundleDirectory.path,
          );
          expect(result.output['bundle_verified'], 'true');
          expect(result.output['original_run_id'], '42');
          expect(result.output['original_run_attempt'], '1');
          expect(result.output['manifest_sha256'], hasLength(64));
          expect(await _names(context.bundleDirectory), {
            'Flashco-1.2.3-android.apk',
            'Flashco-1.2.3-windows-amd64-setup.exe',
            'Flashco-1.2.3-windows-amd64.zip',
            'release-manifest.json',
            'SHA256SUMS',
            'release.md',
          });
          expect(runner.androidApkPaths.toSet(), {
            path.join(
              context.bundleDirectory.path,
              'Flashco-1.2.3-android.apk',
            ),
          });
          final manifest =
              jsonDecode(
                    File(
                      '${context.bundleDirectory.path}/release-manifest.json',
                    ).readAsStringSync(),
                  )
                  as Map;
          expect(manifest['workflowRunId'], 42);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'reuses and verifies a synthetic bundle without rewriting its six files',
      () async {
        final context = await _newBundleContext(recoveryAction: 'reuse');
        try {
          await _writeSyntheticBundle(context.bundleDirectory);
          final before = await _bundleFileBytes(context.bundleDirectory);
          final runner = _BundleRunner(_syntheticSdkOutputs());

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 0, reason: result.error);
          expect(await _bundleFileBytes(context.bundleDirectory), before);
          expect(runner.androidApkPaths.toSet(), {
            path.join(
              context.bundleDirectory.path,
              'Flashco-1.2.3-android.apk',
            ),
          });
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'rejects a coherent recovery bundle with a different source build number',
      () async {
        final context = await _newBundleContext(recoveryAction: 'reuse');
        try {
          await _writeSyntheticBundle(context.bundleDirectory, buildNumber: 11);
          final before = await _bundleFileBytes(context.bundleDirectory);
          final runner = _BundleRunner(_syntheticSdkOutputs(versionCode: 11));

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 1);
          expect(
            result.error,
            'Saved release manifest does not match the selected source version.',
          );
          expect(result.output, isEmpty);
          expect(await _bundleFileBytes(context.bundleDirectory), before);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'rejects the captured debug APK metadata without writing bundle metadata',
      () async {
        final context = await _newBundleContext();
        try {
          await _writePayloads(context.bundleDirectory);
          final runner = _BundleRunner(_capturedDebugSdkOutputs());

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 1);
          expect(await _names(context.bundleDirectory), {
            'Flashco-1.2.3-android.apk',
            'Flashco-1.2.3-windows-amd64-setup.exe',
            'Flashco-1.2.3-windows-amd64.zip',
          });
          expect(runner.androidApkPaths.toSet(), {
            path.join(
              context.bundleDirectory.path,
              'Flashco-1.2.3-android.apk',
            ),
          });
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'requires apksigner verify success before producing the manifest',
      () async {
        final context = await _newBundleContext();
        try {
          await _writePayloads(context.bundleDirectory);
          final runner = _BundleRunner(
            _syntheticSdkOutputs(),
            apksignerExitCode: 1,
          );

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 1);
          expect(
            File(
              '${context.bundleDirectory.path}/release-manifest.json',
            ).existsSync(),
            isFalse,
          );
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'rejects an APK changed during SDK inspection before writing metadata',
      () async {
        final context = await _newBundleContext();
        try {
          await _writePayloads(context.bundleDirectory);
          final apk = File(
            path.join(
              context.bundleDirectory.path,
              'Flashco-1.2.3-android.apk',
            ),
          );
          final runner = _BundleRunner(
            _syntheticSdkOutputs(),
            afterApksigner: (apkPath) {
              expect(apkPath, apk.path);
              apk.writeAsBytesSync([...apk.readAsBytesSync(), 0x42]);
            },
          );

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 1);
          expect(result.output, isEmpty);
          expect(await _names(context.bundleDirectory), {
            'Flashco-1.2.3-android.apk',
            'Flashco-1.2.3-windows-amd64-setup.exe',
            'Flashco-1.2.3-windows-amd64.zip',
          });
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test('rejects native libraries for an unapproved ABI', () async {
      final context = await _newBundleContext();
      try {
        await _writePayloads(context.bundleDirectory);
        final runner = _BundleRunner(
          _syntheticSdkOutputs(
            abiPaths: '${_syntheticSdkOutputs().abiPaths}/lib/mips/libx.so\n',
          ),
        );

        final result = await ReleaseCli(
          environment: context.environment,
          runner: runner.call,
        ).run(['bundle']);

        expect(result.exitCode, 1);
        expect(
          File(
            path.join(context.bundleDirectory.path, 'release-manifest.json'),
          ).existsSync(),
          isFalse,
        );
      } finally {
        await context.directory.delete(recursive: true);
      }
    });

    test(
      'rejects a checkout that differs from the selected source SHA',
      () async {
        final context = await _newBundleContext();
        try {
          await _writePayloads(context.bundleDirectory);
          final runner = _BundleRunner(
            _syntheticSdkOutputs(),
            checkoutSha: 'd' * 40,
          );

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
          ).run(['bundle']);

          expect(result.exitCode, 1);
          expect(runner.androidApkPaths, isEmpty);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'publishes only a verified bundle and emits completed draft outputs',
      () async {
        final context = await _newPreflightBundleContext();
        try {
          await _writePreflightSyntheticBundle(context.bundleDirectory);
          final runner = _PublishRunner();
          final api = _CliPublishApi();
          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
            releaseApiExecutor: api.execute,
          ).run(['publish']);

          expect(result.exitCode, 0, reason: result.error);
          expect(result.output, {
            'draft_release_id': '77',
            'draft_release_completed': 'true',
          });
          expect(
            api.requests.whereType<CreateDraftReleaseRequest>(),
            hasLength(1),
          );
          expect(
            api.requests.whereType<UploadReleaseAssetRequest>(),
            hasLength(5),
          );
          expect(
            api.requests.whereType<DownloadReleaseAssetRequest>(),
            hasLength(10),
          );
          expect(runner.fixtureRunner.preflightCalls, 2);
          expect(await _bundleFileBytes(context.bundleDirectory), hasLength(6));
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test('revalidates the tag before a draft write', () async {
      final context = await _newPreflightBundleContext();
      try {
        await _writePreflightSyntheticBundle(context.bundleDirectory);
        final runner = _PublishRunner();
        final api = _CliPublishApi(
          onLatestRead: () {
            runner.fixtureRunner.tagSha = 'd' * 40;
          },
        );
        final result = await ReleaseCli(
          environment: context.environment,
          runner: runner.call,
          releaseApiExecutor: api.execute,
        ).run(['publish']);

        expect(result.exitCode, 1);
        expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
        expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
      } finally {
        await context.directory.delete(recursive: true);
      }
    });

    test(
      'rechecks the verified bundle immediately before the first write',
      () async {
        final context = await _newPreflightBundleContext();
        final replacementDirectory = await Directory.systemTemp.createTemp(
          'flashco-cli-replacement-bundle-',
        );
        try {
          await _writePreflightSyntheticBundle(context.bundleDirectory);
          await _writePreflightSyntheticBundle(
            replacementDirectory,
            apkBytes: [9, 8, 7],
          );
          final replacement = await _bundleFileBytes(replacementDirectory);
          final runner = _PublishRunner();
          var replaced = false;
          final api = _CliPublishApi(
            onLatestRead: () {
              if (replaced) return;
              replaced = true;
              for (final entry in replacement.entries) {
                File(
                  path.join(context.bundleDirectory.path, entry.key),
                ).writeAsBytesSync(entry.value);
              }
            },
          );

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
            releaseApiExecutor: api.execute,
          ).run(['publish']);

          expect(result.exitCode, 1);
          expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
          expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
          expect(await _bundleFileBytes(context.bundleDirectory), replacement);
        } finally {
          await context.directory.delete(recursive: true);
          await replacementDirectory.delete(recursive: true);
        }
      },
    );

    test('publishes only the selected earlier-attempt bundle', () async {
      final context = await _newPreflightBundleContext(
        recoveryAction: 'reuse',
        originalRunId: '700',
        originalRunAttempt: '1',
      );
      context.environment['GITHUB_RUN_ID'] = '900';
      try {
        await _writePreflightSyntheticBundle(
          context.bundleDirectory,
          originalRunId: 700,
        );
        final before = await _bundleFileBytes(context.bundleDirectory);
        final runner = _PublishRunner(priorAttemptTwo: true);
        final api = _CliPublishApi();
        final result = await ReleaseCli(
          environment: context.environment,
          runner: runner.call,
          releaseApiExecutor: api.execute,
        ).run(['publish']);

        expect(result.exitCode, 0, reason: result.error);
        expect(await _bundleFileBytes(context.bundleDirectory), before);
        expect(runner.fixtureRunner.preflightCalls, 2);
        expect(
          api.requests.whereType<CreateDraftReleaseRequest>(),
          hasLength(1),
        );
      } finally {
        await context.directory.delete(recursive: true);
      }
    });

    test(
      'requires completed bundle job proof before using a saved bundle',
      () async {
        final context = await _newPreflightBundleContext();
        try {
          await _writePreflightSyntheticBundle(context.bundleDirectory);
          final runner = _PublishRunner(missingCurrentBundleJob: true);
          final api = _CliPublishApi();

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
            releaseApiExecutor: api.execute,
          ).run(['publish']);

          expect(result.exitCode, 1);
          expect(api.requests, isEmpty);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test(
      'rejects bundle tampering before the publisher makes any API call',
      () async {
        final context = await _newPreflightBundleContext();
        try {
          await _writePreflightSyntheticBundle(context.bundleDirectory);
          File(
            path.join(
              context.bundleDirectory.path,
              'Flashco-0.9.0-android.apk',
            ),
          ).writeAsBytesSync([1, 9, 3]);
          final runner = _PublishRunner();
          final api = _CliPublishApi();

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
            releaseApiExecutor: api.execute,
          ).run(['publish']);

          expect(result.exitCode, 1);
          expect(api.requests, isEmpty);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );

    test('rejects a saved bundle with a different original run ID', () async {
      final context = await _newPreflightBundleContext();
      try {
        await _writePreflightSyntheticBundle(context.bundleDirectory);
        final manifestFile = File(
          path.join(context.bundleDirectory.path, 'release-manifest.json'),
        );
        final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
        manifest['workflowRunId'] = 900;
        await manifestFile.writeAsString(jsonEncode(manifest));
        final runner = _PublishRunner();
        final api = _CliPublishApi();

        final result = await ReleaseCli(
          environment: context.environment,
          runner: runner.call,
          releaseApiExecutor: api.execute,
        ).run(['publish']);

        expect(result.exitCode, 1);
        expect(api.requests, isEmpty);
      } finally {
        await context.directory.delete(recursive: true);
      }
    });

    test(
      'rejects a coherent published candidate with a different source build number',
      () async {
        final context = await _newPreflightBundleContext(
          recoveryAction: 'reuse',
          originalRunId: '700',
        );
        context.environment['GITHUB_RUN_ID'] = '900';
        try {
          await _writePreflightSyntheticBundle(
            context.bundleDirectory,
            originalRunId: 700,
            buildNumber: 2026101402,
          );
          final before = await _bundleFileBytes(context.bundleDirectory);
          final runner = _PublishRunner(
            priorAttemptTwo: true,
            bundleBuildNumber: 2026101402,
          );
          final api = _CliPublishApi();

          final result = await ReleaseCli(
            environment: context.environment,
            runner: runner.call,
            releaseApiExecutor: api.execute,
          ).run(['publish']);

          expect(result.exitCode, 1);
          expect(
            result.error,
            'Saved release manifest does not match the selected source version.',
          );
          expect(runner.fixtureRunner.preflightCalls, 1);
          expect(runner.bundleRunner.androidApkPaths, isNotEmpty);
          expect(api.requests, isEmpty);
          expect(await _bundleFileBytes(context.bundleDirectory), before);
        } finally {
          await context.directory.delete(recursive: true);
        }
      },
    );
  });
}

Map<String, String> _environment() => {
  'GH_TOKEN': 'fake-token-for-injected-runner',
  'GH_HOST': 'github.enterprise.invalid',
  'GITHUB_EVENT_NAME': 'workflow_dispatch',
  'GITHUB_REF': 'refs/heads/main',
  'GITHUB_SHA': _sourceSha,
  'GITHUB_RUN_ID': '501',
  'GITHUB_RUN_ATTEMPT': '1',
  'GITHUB_REPOSITORY': 'Artypoul/Flashco',
  'GITHUB_WORKFLOW_REF':
      'Artypoul/Flashco/.github/workflows/release.yaml@refs/heads/main',
  'GITHUB_WORKFLOW_SHA': _sourceSha,
  'RELEASE_TAG': _tag,
  'ANDROID_CERT_SHA256': _fingerprint,
};

class _FixtureRunner {
  _FixtureRunner({
    this.currentRunId = 501,
    this.currentAttempt = 1,
    this.failReleases = false,
    this.malformedRuns = false,
    this.priorAttemptTwo = false,
    this.duplicateBuildRun = false,
    this.untitledPriorRun = false,
    this.zeroPageReleases = false,
    this.malformedArtifact = false,
    this.duplicateExpectedArtifact = false,
    this.equalBuildTimestamps = false,
    this.missingCurrentBundleJob = false,
    this.futureQueuedRun = false,
    this.futureQueuedAfterBundle = false,
    this.duplicateRunNumber = false,
    this.mismatchedCurrentRunNumber = false,
    this.invalidRunNumber = false,
  });

  final int currentRunId;
  final int currentAttempt;
  final bool failReleases;
  final bool malformedRuns;
  final bool priorAttemptTwo;
  final bool duplicateBuildRun;
  final bool untitledPriorRun;
  final bool zeroPageReleases;
  final bool malformedArtifact;
  final bool duplicateExpectedArtifact;
  final bool equalBuildTimestamps;
  final bool missingCurrentBundleJob;
  final bool futureQueuedRun;
  final bool futureQueuedAfterBundle;
  final bool duplicateRunNumber;
  final bool mismatchedCurrentRunNumber;
  final bool invalidRunNumber;
  final calls = <String>[];
  var preflightCalls = 0;
  String tagSha = _sourceSha;

  Future<ReleaseCommandResult> call(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final command = '$executable ${arguments.join(' ')}';
    calls.add(command);
    if (executable == 'git') {
      if (arguments.first == 'rev-parse') {
        final result = arguments.last.contains('release-preflight/tag')
            ? tagSha
            : _sourceSha;
        return ReleaseCommandResult(0, '$result\n');
      }
      if (arguments.first == 'show') {
        return const ReleaseCommandResult(0, 'version: 0.9.0+2026101401\n');
      }
      return const ReleaseCommandResult(0, '');
    }
    if (executable != 'gh' ||
        environment?['GH_TOKEN'] == null ||
        !arguments.contains('--hostname') ||
        arguments[arguments.indexOf('--hostname') + 1] != 'github.com') {
      return const ReleaseCommandResult(1, '', 'unexpected command');
    }
    final endpoint = arguments.last;
    if (endpoint == 'repos/Artypoul/Flashco/actions/runs/501' ||
        endpoint == 'repos/Artypoul/Flashco/actions/runs/900') {
      preflightCalls++;
      final id = endpoint.endsWith('/900') ? 900 : 501;
      return ReleaseCommandResult(
        0,
        jsonEncode({
          'id': id,
          'display_title': 'release-v0.9.0',
          'event': 'workflow_dispatch',
          'head_branch': 'main',
          'head_sha': _sourceSha,
          'path': '.github/workflows/release.yaml',
          'workflow_id': 901,
          'run_attempt': currentAttempt,
          'run_number': id == 900 ? 8 : 6,
        }),
      );
    }
    if (endpoint ==
        'repos/Artypoul/Flashco/actions/runs/501/attempts/1/jobs?per_page=100') {
      if (missingCurrentBundleJob) {
        return const ReleaseCommandResult(0, '[{"total_count":0,"jobs":[]}]');
      }
      return const ReleaseCommandResult(
        0,
        '[{"total_count":1,"jobs":[{"id":7012,"name":"bundle","status":"completed","conclusion":"success","run_attempt":1}]}]',
      );
    }
    if (endpoint.contains('/actions/workflows/385298741/runs?')) {
      if (malformedRuns) {
        return const ReleaseCommandResult(
          0,
          '[{"total_count":1,"workflow_runs":[]}]',
        );
      }
      final response = _fixture('github_build_runs_api.json');
      if (duplicateBuildRun) {
        final run = (response['workflow_runs'] as List).single;
        response['total_count'] = 2;
        (response['workflow_runs'] as List).add(run);
      }
      if (equalBuildTimestamps) {
        final higherRun = Map<String, Object?>.from(
          (response['workflow_runs'] as List).single as Map,
        )..['id'] = 38913914850;
        response['total_count'] = 2;
        (response['workflow_runs'] as List).add(higherRun);
      }
      return ReleaseCommandResult(0, jsonEncode([response]));
    }
    if (endpoint.contains('/actions/runs/38913914849/jobs?')) {
      return ReleaseCommandResult(
        0,
        jsonEncode([_fixture('github_build_jobs_api.json')]),
      );
    }
    if (endpoint.contains('/actions/runs/38913914850/jobs?')) {
      return ReleaseCommandResult(
        0,
        jsonEncode([_fixture('github_build_jobs_api.json')]),
      );
    }
    if (endpoint == 'repos/Artypoul/Flashco/releases?per_page=100') {
      if (failReleases) return const ReleaseCommandResult(1, '', 'HTTP 403');
      if (zeroPageReleases) return const ReleaseCommandResult(0, '[]');
      return const ReleaseCommandResult(0, '[[]]');
    }
    if (endpoint.contains('/actions/workflows/release.yaml/runs?')) {
      final current = _workflowRun(
        id: currentRunId,
        runNumber: currentRunId == 900 ? 8 : 6,
      );
      if (mismatchedCurrentRunNumber) current['run_number'] = 5;
      if (invalidRunNumber) current['run_number'] = 0;
      if (duplicateRunNumber) {
        final duplicate = _workflowRun(id: 500, runNumber: 6)
          ..['display_title'] = 'release-v0.8.0';
        return ReleaseCommandResult(
          0,
          jsonEncode([
            _runPage([current, duplicate]),
          ]),
        );
      }
      if (futureQueuedRun) {
        final future = _workflowRun(id: 502, runNumber: 7, headSha: _futureSha);
        return ReleaseCommandResult(
          0,
          jsonEncode([
            _runPage([current, future]),
          ]),
        );
      }
      if (futureQueuedAfterBundle) {
        final future = _workflowRun(id: 502, runNumber: 7, headSha: _futureSha);
        current['run_attempt'] = 2;
        return ReleaseCommandResult(
          0,
          jsonEncode([
            _runPage([current, future]),
          ]),
        );
      }
      if (priorAttemptTwo) {
        final earlier = _workflowRun(id: 700, runNumber: 7, runAttempt: 2);
        final current = _workflowRun(id: 900, runNumber: 8);
        return ReleaseCommandResult(
          0,
          jsonEncode([
            _runPage([earlier, current]),
          ]),
        );
      }
      if (untitledPriorRun) {
        final malformed = _workflowRun(id: 701, runNumber: 5)
          ..remove('display_title');
        return ReleaseCommandResult(
          0,
          jsonEncode([
            _runPage([malformed, current]),
          ]),
        );
      }
      return ReleaseCommandResult(
        0,
        jsonEncode([
          _runPage([current]),
        ]),
      );
    }
    final artifactRunMatch = RegExp(
      r'/runs/(\d+)/artifacts\?per_page=100$',
    ).firstMatch(endpoint);
    if (artifactRunMatch != null) {
      final runId = int.parse(artifactRunMatch.group(1)!);
      final artifactRecords =
          (runId == 700 || (runId == 501 && futureQueuedAfterBundle))
          ? <Map<String, Object?>>[
              {
                'id': 7011,
                'name': 'flashco-release-bundle-v0.9.0-run-$runId-attempt-1',
                'size_in_bytes': 300,
                'expired': false,
                'workflow_run': {'id': runId, 'head_sha': _sourceSha},
              },
            ]
          : <Map<String, Object?>>[];
      if (malformedArtifact && runId == 700) {
        artifactRecords.add({'id': 7013, 'name': 'unrelated'});
      }
      if (duplicateExpectedArtifact && runId == 700) {
        artifactRecords.addAll([
          {
            'id': 7014,
            'name': 'flashco-release-bundle-v0.9.0-run-$runId-attempt-2',
            'size_in_bytes': 300,
            'expired': false,
            'workflow_run': {'id': runId, 'head_sha': _sourceSha},
          },
          {
            'id': 7015,
            'name': 'flashco-release-bundle-v0.9.0-run-$runId-attempt-2',
            'size_in_bytes': 300,
            'expired': false,
            'workflow_run': {'id': runId, 'head_sha': _sourceSha},
          },
        ]);
      }
      return ReleaseCommandResult(
        0,
        jsonEncode([
          {'total_count': artifactRecords.length, 'artifacts': artifactRecords},
        ]),
      );
    }
    if (endpoint.endsWith('/runs/700/attempts/1/jobs?per_page=100') ||
        endpoint.endsWith('/runs/501/attempts/1/jobs?per_page=100')) {
      return const ReleaseCommandResult(
        0,
        '[{"total_count":1,"jobs":[{"id":7012,"name":"bundle","status":"completed","conclusion":"success","run_attempt":1}]}]',
      );
    }
    return const ReleaseCommandResult(1, '', 'unexpected endpoint');
  }
}

Map<String, Object?> _workflowRun({
  required int id,
  required int runNumber,
  String headSha = _sourceSha,
  int runAttempt = 1,
}) => {
  'id': id,
  'display_title': 'release-v0.9.0',
  'path': '.github/workflows/release.yaml',
  'event': 'workflow_dispatch',
  'head_branch': 'main',
  'head_sha': headSha,
  'workflow_id': 901,
  'run_attempt': runAttempt,
  'run_number': runNumber,
};

Map<String, Object?> _runPage(List<Map<String, Object?>> runs) => {
  'total_count': runs.length,
  'workflow_runs': runs,
};

Map<String, Object?> _fixture(String name) => Map<String, Object?>.from(
  jsonDecode(File('test/fixtures/release/$name').readAsStringSync()) as Map,
);

const _bundleTag = 'v1.2.3';
const _bundleVersion = '1.2.3';
const _bundleSha = 'cccccccccccccccccccccccccccccccccccccccc';
const _bundleSigner =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _releaseBody = '## Synthetic changelog body\n\nTest data only.\n';

class _BundleContext {
  const _BundleContext(this.directory, this.bundleDirectory, this.environment);

  final Directory directory;
  final Directory bundleDirectory;
  final Map<String, String> environment;
}

Future<_BundleContext> _newBundleContext({
  String recoveryAction = 'build',
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'flashco-cli-bundle-',
  );
  final bundleDirectory = Directory('${directory.path}/bundle')..createSync();
  final sdk = Directory('${directory.path}/sdk');
  Directory('${sdk.path}/cmdline-tools/latest/bin').createSync(recursive: true);
  Directory('${sdk.path}/build-tools/37.0.0').createSync(recursive: true);
  File('${sdk.path}/cmdline-tools/latest/bin/apkanalyzer').createSync();
  File('${sdk.path}/build-tools/37.0.0/apksigner').createSync();
  return _BundleContext(directory, bundleDirectory, {
    'GITHUB_REPOSITORY': 'Artypoul/Flashco',
    'GITHUB_RUN_ID': '42',
    'GITHUB_RUN_ATTEMPT': '1',
    'RELEASE_TAG': _bundleTag,
    'SOURCE_SHA': _bundleSha,
    'RELEASE_VERSION': _bundleVersion,
    'BUILD_NUMBER': '12',
    'RECOVERY_ACTION': recoveryAction,
    'ORIGINAL_RUN_ID': '42',
    'ORIGINAL_RUN_ATTEMPT': '1',
    'ANDROID_CERT_SHA256': _bundleSigner,
    'ANDROID_SDK_ROOT': sdk.path,
    'RELEASE_BUNDLE_DIR': bundleDirectory.path,
  });
}

Future<_BundleContext> _newPreflightBundleContext({
  String recoveryAction = 'build',
  String originalRunId = '501',
  String originalRunAttempt = '1',
}) async {
  final context = await _newBundleContext(recoveryAction: recoveryAction);
  context.environment.addAll(_environment());
  context.environment.addAll({
    'SOURCE_SHA': _sourceSha,
    'RELEASE_VERSION': '0.9.0',
    'BUILD_NUMBER': '2026101401',
    'ORIGINAL_RUN_ID': originalRunId,
    'ORIGINAL_RUN_ATTEMPT': originalRunAttempt,
    'RECOVERY_ACTION': recoveryAction,
    'ANDROID_CERT_SHA256': _fingerprint,
    'RELEASE_BUNDLE_DIR': context.bundleDirectory.path,
  });
  return context;
}

AndroidSdkCommandOutputs _syntheticSdkOutputs({
  String versionName = _bundleVersion,
  int versionCode = 12,
  String signer = _bundleSigner,
  String? abiPaths,
}) => AndroidSdkCommandOutputs(
  identity:
      'application-id: com.follow.flashco\n'
      'version-name: $versionName\n'
      'version-code: $versionCode\n'
      'debuggable: false\n',
  applicationXml:
      '<manifest><application android:debuggable="false"></application></manifest>',
  certificates:
      'V2 Signer: certificate DN: C=US, O=Flashco, CN=Flashco Release\n'
      'V2 Signer: certificate SHA-256 digest: $signer\n',
  abiPaths:
      abiPaths ??
      '/lib/armeabi-v7a/libx.so\n'
          '/lib/arm64-v8a/libx.so\n'
          '/lib/x86_64/libx.so\n',
);

AndroidSdkCommandOutputs _capturedDebugSdkOutputs() => AndroidSdkCommandOutputs(
  identity: File(
    'test/fixtures/release/sdk_apk_manifest_identity.txt',
  ).readAsStringSync(),
  applicationXml: File('test/fixtures/release/sdk_apk_manifest_application.txt')
      .readAsStringSync()
      .replaceFirst('android:debuggable="true"', 'android:debuggable="true">'),
  certificates: File(
    'test/fixtures/release/sdk_apksigner_certificate.txt',
  ).readAsStringSync(),
  abiPaths: File(
    'test/fixtures/release/sdk_apk_lib_paths.txt',
  ).readAsStringSync(),
);

class _BundleRunner {
  _BundleRunner(
    this.outputs, {
    this.apksignerExitCode = 0,
    this.afterApksigner,
    this.checkoutSha = _bundleSha,
    this.pubspec = 'version: 1.2.3+12\n',
  });

  final AndroidSdkCommandOutputs outputs;
  final int apksignerExitCode;
  final void Function(String apkPath)? afterApksigner;
  final String checkoutSha;
  final String pubspec;
  final calls = <List<String>>[];
  final androidApkPaths = <String>[];

  Future<ReleaseCommandResult> call(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    if (executable == 'git') {
      if (arguments.join(' ') == 'rev-parse HEAD') {
        return ReleaseCommandResult(0, '$checkoutSha\n');
      }
      if (arguments.join(' ') == 'show HEAD:pubspec.yaml') {
        return ReleaseCommandResult(0, pubspec);
      }
      if (arguments.first == 'status') {
        return const ReleaseCommandResult(0, '');
      }
      return const ReleaseCommandResult(1, '', 'unexpected git command');
    }
    if (executable == 'dart') {
      final outputPath = arguments[arguments.indexOf('--out') + 1];
      File(outputPath).writeAsStringSync(_releaseBody);
      return const ReleaseCommandResult(0, '');
    }
    if (executable.endsWith('apkanalyzer')) {
      final apkPath = arguments.last;
      androidApkPaths.add(apkPath);
      final result = switch (arguments.take(2).join(' ')) {
        'manifest application-id' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('application-id: '))
              .substring('application-id: '.length),
        'manifest version-name' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('version-name: '))
              .substring('version-name: '.length),
        'manifest version-code' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('version-code: '))
              .substring('version-code: '.length),
        'manifest debuggable' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('debuggable: '))
              .substring('debuggable: '.length),
        'manifest print' => outputs.applicationXml,
        'files list' => outputs.abiPaths,
        _ => '',
      };
      return ReleaseCommandResult(0, result);
    }
    if (executable.endsWith('apksigner')) {
      androidApkPaths.add(arguments.last);
      afterApksigner?.call(arguments.last);
      return ReleaseCommandResult(apksignerExitCode, outputs.certificates);
    }
    final apkPath = arguments.last;
    if (arguments.contains('application-id') ||
        arguments.contains('version-name') ||
        arguments.contains('version-code') ||
        arguments.contains('debuggable') ||
        arguments.contains('print') ||
        arguments.contains('list')) {
      androidApkPaths.add(apkPath);
      final result = switch (arguments.take(2).join(' ')) {
        'manifest application-id' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('application-id: '))
              .substring('application-id: '.length),
        'manifest version-name' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('version-name: '))
              .substring('version-name: '.length),
        'manifest version-code' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('version-code: '))
              .substring('version-code: '.length),
        'manifest debuggable' =>
          outputs.identity
              .split('\n')
              .firstWhere((line) => line.startsWith('debuggable: '))
              .substring('debuggable: '.length),
        'manifest print' => outputs.applicationXml,
        'files list' => outputs.abiPaths,
        _ => '',
      };
      return ReleaseCommandResult(0, result);
    }
    if (arguments.take(2).join(' ') == 'verify --print-certs') {
      androidApkPaths.add(apkPath);
      return ReleaseCommandResult(apksignerExitCode, outputs.certificates);
    }
    return const ReleaseCommandResult(1, '', 'unexpected command');
  }
}

class _PublishRunner {
  _PublishRunner({
    bool missingCurrentBundleJob = false,
    bool priorAttemptTwo = false,
    int bundleBuildNumber = 2026101401,
  }) : fixtureRunner = _FixtureRunner(
         missingCurrentBundleJob: missingCurrentBundleJob,
         priorAttemptTwo: priorAttemptTwo,
         currentRunId: priorAttemptTwo ? 900 : 501,
       ),
       bundleRunner = _BundleRunner(
         _syntheticSdkOutputs(
           versionName: '0.9.0',
           versionCode: bundleBuildNumber,
           signer: _fingerprint,
         ),
         checkoutSha: _sourceSha,
         pubspec: 'version: 0.9.0+2026101401\n',
       );

  final _FixtureRunner fixtureRunner;
  final _BundleRunner bundleRunner;

  Future<ReleaseCommandResult> call(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    if (executable == 'git' || executable == 'gh') {
      return fixtureRunner.call(
        executable,
        arguments,
        environment: environment,
      );
    }
    return bundleRunner.call(executable, arguments, environment: environment);
  }
}

class _CliPublishApi {
  _CliPublishApi({this.onLatestRead});

  final void Function()? onLatestRead;
  final requests = <ReleaseApiRequest>[];
  final assetBytes = <int, List<int>>{};
  Map<String, Object?>? draft;
  var nextAssetId = 800;

  Future<ReleaseApiResponse> execute(ReleaseApiRequest request) async {
    requests.add(request);
    if (request is GetReleaseByTagRequest) {
      return ReleaseApiResponse(
        statusCode: 404,
        headers: const {},
        body: await File(
          'test/fixtures/release/github_release_tag_not_found.json',
        ).readAsBytes(),
      );
    }
    if (request is ListReleasesRequest) {
      return _jsonResponse(200, [if (draft != null) draft]);
    }
    if (request is GetLatestReleaseRequest) {
      onLatestRead?.call();
      return _jsonResponse(200, {
        'id': 33,
        'tag_name': 'v0.8.0',
        'target_commitish': 'main',
        'draft': false,
        'prerelease': false,
        'body': 'Previous stable release',
        'assets': <Object?>[],
      });
    }
    if (request is CreateDraftReleaseRequest) {
      draft = {
        'id': 77,
        'tag_name': request.tag,
        'target_commitish': request.targetSha,
        'draft': request.draft,
        'prerelease': request.prerelease,
        'body': request.body,
        'assets': <Object?>[],
      };
      return _jsonResponse(201, draft);
    }
    if (request is UploadReleaseAssetRequest) {
      final assetId = nextAssetId++;
      assetBytes[assetId] = await request.file.readAsBytes();
      final asset = {
        'id': assetId,
        'name': request.name,
        'size': request.size,
        'state': 'uploaded',
      };
      (draft!['assets']! as List<Object?>).add(asset);
      return _jsonResponse(201, asset);
    }
    if (request is DownloadReleaseAssetRequest) {
      final bytes = assetBytes[request.assetId];
      return ReleaseApiResponse(
        statusCode: bytes == null ? 404 : 200,
        headers: const {},
        body: Uint8List.fromList(bytes ?? const []),
      );
    }
    throw StateError('Unexpected release API request.');
  }

  ReleaseApiResponse _jsonResponse(int status, Object? value) =>
      ReleaseApiResponse(
        statusCode: status,
        headers: const {},
        body: Uint8List.fromList(utf8.encode(jsonEncode(value))),
      );
}

Future<void> _writePayloads(Directory directory) async {
  File(
    '${directory.path}/Flashco-$_bundleVersion-android.apk',
  ).writeAsBytesSync([1, 2, 3]);
  File(
    '${directory.path}/Flashco-$_bundleVersion-windows-amd64-setup.exe',
  ).writeAsBytesSync([4, 5, 6]);
  File(
    '${directory.path}/Flashco-$_bundleVersion-windows-amd64.zip',
  ).writeAsBytesSync(_syntheticWindowsArchive());
}

List<int> _syntheticWindowsArchive() {
  final core = [1, 2, 3];
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('Flashco.exe', [1]))
    ..addFile(ArchiveFile.bytes('FlashcoCore.exe', core))
    ..addFile(
      ArchiveFile.bytes(
        'manifest.json',
        jsonEncode({'coreSha256': sha256.convert(core).toString()}).codeUnits,
      ),
    )
    ..addFile(ArchiveFile.bytes('FlashcoHelperService.exe', [1]))
    ..addFile(ArchiveFile.bytes('flutter_windows.dll', [1]))
    ..addFile(ArchiveFile.bytes('EnableLoopback.exe', [1]))
    ..addFile(ArchiveFile.bytes('msvcp140.dll', [1]))
    ..addFile(ArchiveFile.bytes('vcruntime140.dll', [1]))
    ..addFile(ArchiveFile.bytes('data/icudtl.dat', [1]))
    ..addFile(ArchiveFile.bytes('data/app.so', [1]))
    ..addFile(ArchiveFile.bytes('data/flutter_assets/AssetManifest.bin', [1]));
  return ZipEncoder().encode(archive);
}

Future<void> _writeSyntheticBundle(
  Directory directory, {
  int buildNumber = 12,
}) async {
  await _writePayloads(directory);
  final files = {
    'Flashco-$_bundleVersion-android.apk': File(
      '${directory.path}/Flashco-$_bundleVersion-android.apk',
    ),
    'Flashco-$_bundleVersion-windows-amd64-setup.exe': File(
      '${directory.path}/Flashco-$_bundleVersion-windows-amd64-setup.exe',
    ),
    'Flashco-$_bundleVersion-windows-amd64.zip': File(
      '${directory.path}/Flashco-$_bundleVersion-windows-amd64.zip',
    ),
  };
  final bundle = await buildReleaseBundle(
    tag: _bundleTag,
    commit: _bundleSha,
    workflowRunId: 42,
    version: _bundleVersion,
    buildNumber: buildNumber,
    expectedSignerSha256: _bundleSigner,
    androidOutputs: _syntheticSdkOutputs(versionCode: buildNumber),
    payloadFiles: files,
  );
  File(
    '${directory.path}/release-manifest.json',
  ).writeAsStringSync(bundle.manifestJson);
  File('${directory.path}/SHA256SUMS').writeAsStringSync(bundle.sha256Sums);
  File('${directory.path}/release.md').writeAsStringSync(_releaseBody);
}

Future<void> _writePreflightSyntheticBundle(
  Directory directory, {
  int originalRunId = 501,
  int buildNumber = 2026101401,
  List<int> apkBytes = const [1, 2, 3],
}) async {
  const version = '0.9.0';
  const apkName = 'Flashco-$version-android.apk';
  const exeName = 'Flashco-$version-windows-amd64-setup.exe';
  const zipName = 'Flashco-$version-windows-amd64.zip';
  File(path.join(directory.path, apkName)).writeAsBytesSync(apkBytes);
  File(path.join(directory.path, exeName)).writeAsBytesSync([4, 5, 6]);
  File(
    path.join(directory.path, zipName),
  ).writeAsBytesSync(_syntheticWindowsArchive());
  final bundle = await buildReleaseBundle(
    tag: _tag,
    commit: _sourceSha,
    workflowRunId: originalRunId,
    version: version,
    buildNumber: buildNumber,
    expectedSignerSha256: _fingerprint,
    androidOutputs: _syntheticSdkOutputs(
      versionName: version,
      versionCode: buildNumber,
      signer: _fingerprint,
    ),
    payloadFiles: {
      apkName: File(path.join(directory.path, apkName)),
      exeName: File(path.join(directory.path, exeName)),
      zipName: File(path.join(directory.path, zipName)),
    },
  );
  File(
    path.join(directory.path, 'release-manifest.json'),
  ).writeAsStringSync(bundle.manifestJson);
  File(
    path.join(directory.path, 'SHA256SUMS'),
  ).writeAsStringSync(bundle.sha256Sums);
  File(path.join(directory.path, 'release.md')).writeAsStringSync(_releaseBody);
}

Future<Set<String>> _names(Directory directory) async => directory
    .listSync(followLinks: false)
    .map((entity) => entity.uri.pathSegments.last)
    .toSet();

Future<Map<String, List<int>>> _bundleFileBytes(Directory directory) async {
  final names = await _names(directory);
  return {
    for (final name in names)
      name: File('${directory.path}/$name').readAsBytesSync(),
  };
}
