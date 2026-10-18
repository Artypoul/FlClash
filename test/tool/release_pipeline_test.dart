import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_pipeline.dart';

void main() {
  group('validateReleaseSource', () {
    test(
      'accepts a stable tag resolving to a main commit from main dispatch',
      () {
        expect(
          validateReleaseSource(
            workflowRef: 'refs/heads/main',
            tag: 'v1.2.3',
            tagSha: 'a' * 40,
            sourceSha: 'a' * 40,
            sourceReachableFromMain: true,
            version: '1.2.3',
            buildNumber: 12,
          ),
          isEmpty,
        );
      },
    );

    test('rejects non-main dispatch, moved tags, and unreachable commits', () {
      expect(
        validateReleaseSource(
          workflowRef: 'refs/heads/feature',
          tag: 'v1.2.3',
          tagSha: 'a' * 40,
          sourceSha: 'a' * 40,
          sourceReachableFromMain: true,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateReleaseSource(
          workflowRef: 'refs/heads/main',
          tag: 'v1.2.3',
          tagSha: 'a' * 40,
          sourceSha: 'b' * 40,
          sourceReachableFromMain: true,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        validateReleaseSource(
          workflowRef: 'refs/heads/main',
          tag: 'v1.2.3',
          tagSha: 'a' * 40,
          sourceSha: 'a' * 40,
          sourceReachableFromMain: false,
          version: '1.2.3',
          buildNumber: 12,
        ),
        isNotEmpty,
      );
    });

    test('rejects oversized external version components without throwing', () {
      final version = '${List.filled(100, '9').join()}.0.0';

      expect(
        validateReleaseSource(
          workflowRef: 'refs/heads/main',
          tag: 'v$version',
          tagSha: 'a' * 40,
          sourceSha: 'a' * 40,
          sourceReachableFromMain: true,
          version: version,
          buildNumber: 12,
        ),
        isNotEmpty,
      );
      expect(
        summarizePublishedHistory(
          complete: true,
          releases: [_release('v$version')],
        ).errors,
        isNotEmpty,
      );
    });
  });

  group('validateLatestBuildCi', () {
    test('accepts the latest successful run and its nine required checks', () {
      final runs =
          _readJson('test/fixtures/release/github_run_list.json') as List;
      final run =
          _readJson('test/fixtures/release/github_run_view.json')
              as Map<String, Object?>;

      expect(
        validateLatestBuildCi(
          completeRunList: true,
          sourceSha: '83089903cc33bbfb720af5e7ec37ba58cef5474e',
          runs: runs.cast<Map<String, Object?>>(),
          latestRun: run,
        ),
        isEmpty,
      );
    });

    test('rejects an incomplete list, a newer failure, or a missing check', () {
      final runs =
          (_readJson('test/fixtures/release/github_run_list.json') as List)
              .cast<Map<String, Object?>>();
      final run = Map<String, Object?>.from(
        _readJson('test/fixtures/release/github_run_view.json')
            as Map<String, Object?>,
      );
      final jobs = (run['jobs'] as List).cast<Map<String, Object?>>();

      expect(
        validateLatestBuildCi(
          completeRunList: false,
          sourceSha: '83089903cc33bbfb720af5e7ec37ba58cef5474e',
          runs: runs,
          latestRun: run,
        ),
        isNotEmpty,
      );

      final newerFailure = {
        ...runs.single,
        'databaseId': 38913914850,
        'createdAt': '2026-10-16T14:30:00Z',
        'status': 'completed',
        'conclusion': 'failure',
      };
      expect(
        validateLatestBuildCi(
          completeRunList: true,
          sourceSha: '83089903cc33bbfb720af5e7ec37ba58cef5474e',
          runs: [...runs, newerFailure],
          latestRun: run,
        ),
        isNotEmpty,
      );

      final unknownShaNewerRun = {
        ...runs.single,
        'databaseId': 38913914851,
        'headSha': null,
        'createdAt': '2026-10-16T14:31:00Z',
        'status': 'queued',
        'conclusion': null,
      };
      expect(
        validateLatestBuildCi(
          completeRunList: true,
          sourceSha: '83089903cc33bbfb720af5e7ec37ba58cef5474e',
          runs: [...runs, unknownShaNewerRun],
          latestRun: run,
        ),
        isNotEmpty,
      );

      final missingCheck = Map<String, Object?>.from(run)
        ..['jobs'] = jobs.where((job) => job['name'] != 'Dart').toList();
      expect(
        validateLatestBuildCi(
          completeRunList: true,
          sourceSha: '83089903cc33bbfb720af5e7ec37ba58cef5474e',
          runs: runs,
          latestRun: missingCheck,
        ),
        isNotEmpty,
      );
    });
  });

  group('summarizePublishedHistory', () {
    test(
      'accepts the captured empty history only after complete pagination',
      () {
        final releases =
            _readJson('test/fixtures/release/github_releases_own.json') as List;

        expect(
          summarizePublishedHistory(complete: true, releases: releases),
          isA<PublishedHistorySummary>()
              .having((summary) => summary.highestVersion, 'version', isNull)
              .having(
                (summary) => summary.highestBuildNumber,
                'build number',
                isNull,
              ),
        );
        expect(
          summarizePublishedHistory(complete: false, releases: releases).errors,
          isNotEmpty,
        );
      },
    );

    test(
      'reads maxima from published tags and matching schema-one manifests',
      () {
        final releases = [_release('v1.2.0'), _release('v1.1.9')];
        final manifests = {
          'v1.2.0': _manifest('v1.2.0', '1.2.0', 80),
          'v1.1.9': _manifest('v1.1.9', '1.1.9', 99),
        };

        final summary = summarizePublishedHistory(
          complete: true,
          releases: releases,
          manifestsByTag: manifests,
        );

        expect(summary.errors, isEmpty);
        expect(summary.highestVersion, '1.2.0');
        expect(summary.highestBuildNumber, 99);
      },
    );

    test(
      'rejects missing, mismatched, or malformed stable release manifests',
      () {
        final releases = [_release('v1.2.0')];

        expect(
          summarizePublishedHistory(complete: true, releases: releases).errors,
          isNotEmpty,
        );
        expect(
          summarizePublishedHistory(
            complete: true,
            releases: releases,
            manifestsByTag: {'v1.2.0': _manifest('v1.2.1', '1.2.1', 80)},
          ).errors,
          isNotEmpty,
        );
        final incomplete = _manifest('v1.2.0', '1.2.0', 80)..remove('assets');
        expect(
          summarizePublishedHistory(
            complete: true,
            releases: releases,
            manifestsByTag: {'v1.2.0': incomplete},
          ).errors,
          isNotEmpty,
        );

        final duplicateAbis = _manifest('v1.2.0', '1.2.0', 80)
          ..['android'] = {
            'packageName': 'com.follow.flashco',
            'signerSha256': 'a' * 64,
            'abis': ['arm64-v8a', 'arm64-v8a', 'x86_64'],
          };
        expect(
          summarizePublishedHistory(
            complete: true,
            releases: releases,
            manifestsByTag: {'v1.2.0': duplicateAbis},
          ).errors,
          isNotEmpty,
        );
      },
    );

    test(
      'uses the donor fixture release shape without treating it as own history',
      () {
        final donor =
            _readJson('test/fixtures/release/github_release_donor.json')
                as List;

        expect(donor, hasLength(1));
        expect((donor.single as Map)['assets'], hasLength(16));
        expect(
          summarizePublishedHistory(complete: true, releases: donor).errors,
          isNotEmpty,
        );
      },
    );
  });

  group('readWorkflowArtifactInventory', () {
    test('reads the real empty artifact-list response shape', () {
      final response =
          _readJson('test/fixtures/release/github_run_artifacts.json')
              as Map<String, Object?>;

      final inventory = readWorkflowArtifactInventory(response);

      expect(inventory.totalCount, 0);
      expect(inventory.artifacts, isEmpty);
    });

    test('reads real artifact fields and original workflow run identity', () {
      final response =
          _readJson('test/fixtures/release/github_donor_run_artifacts.json')
              as Map<String, Object?>;

      final inventory = readWorkflowArtifactInventory(response);

      expect(inventory.totalCount, 7);
      expect(inventory.artifacts, hasLength(7));
      expect(inventory.artifacts.first['name'], 'artifact-windows-arm64');
      expect(inventory.artifacts.first['expired'], isFalse);
      expect(inventory.artifacts.first['size_in_bytes'], 102750989);
      expect(
        (inventory.artifacts.first['workflow_run'] as Map)['id'],
        38494931447,
      );
    });

    test('rejects an inconsistent artifact count or malformed record', () {
      expect(
        () =>
            readWorkflowArtifactInventory({'total_count': 1, 'artifacts': []}),
        throwsFormatException,
      );
      expect(
        () => readWorkflowArtifactInventory({
          'total_count': 1,
          'artifacts': [
            {
              'id': 1,
              'name': 'bundle',
              'size_in_bytes': 100,
              'expired': false,
              'workflow_run': {'id': 4, 'head_sha': 'invalid'},
            },
          ],
        }),
        throwsFormatException,
      );

      final artifact = {
        'id': 1,
        'name': 'bundle',
        'size_in_bytes': 100,
        'expired': false,
        'workflow_run': {'id': 4, 'head_sha': 'a' * 40},
      };
      expect(
        () => readWorkflowArtifactInventory({
          'total_count': 2,
          'artifacts': [artifact, artifact],
        }),
        throwsFormatException,
      );
    });
  });

  group('decidePriorBundleRecovery', () {
    test(
      'starts a new build only when there is no earlier attempt or bundle',
      () {
        expect(
          decidePriorBundleRecovery(
            tag: 'v1.2.3',
            sourceSha: 'a' * 40,
            priorAttemptExists: false,
            candidates: const [],
          ).action,
          BundleRecoveryAction.build,
        );
      },
    );

    test(
      'reuses the one complete integrity-checked bundle from its original run',
      () {
        final candidate = _candidate(
          runId: 42,
          tag: 'v1.2.3',
          sourceSha: 'a' * 40,
        );

        final decision = decidePriorBundleRecovery(
          tag: 'v1.2.3',
          sourceSha: 'a' * 40,
          priorAttemptExists: true,
          candidates: [candidate],
        );

        expect(decision.action, BundleRecoveryAction.reuse);
        expect(decision.workflowRunId, 42);
      },
    );

    test(
      'fails closed when a previous attempt has no matching complete bundle',
      () {
        final candidate = _candidate(
          runId: 42,
          tag: 'v1.2.3',
          sourceSha: 'b' * 40,
        );

        expect(
          decidePriorBundleRecovery(
            tag: 'v1.2.3',
            sourceSha: 'a' * 40,
            priorAttemptExists: true,
            candidates: [candidate],
          ).action,
          BundleRecoveryAction.stop,
        );
        expect(
          decidePriorBundleRecovery(
            tag: 'v1.2.3',
            sourceSha: 'a' * 40,
            priorAttemptExists: true,
            candidates: const [],
          ).action,
          BundleRecoveryAction.stop,
        );
      },
    );

    test('fails closed for expired, corrupt, or ambiguous bundles', () {
      final valid = _candidate(runId: 42, tag: 'v1.2.3', sourceSha: 'a' * 40);
      final expired = _candidate(
        runId: 42,
        tag: 'v1.2.3',
        sourceSha: 'a' * 40,
        expired: true,
      );
      final corrupt = _candidate(
        runId: 42,
        tag: 'v1.2.3',
        sourceSha: 'a' * 40,
        corruptChecksums: true,
      );

      for (final candidates in [
        [expired],
        [corrupt],
        [valid, valid],
      ]) {
        expect(
          decidePriorBundleRecovery(
            tag: 'v1.2.3',
            sourceSha: 'a' * 40,
            priorAttemptExists: true,
            candidates: candidates,
          ).action,
          BundleRecoveryAction.stop,
        );
      }
    });
  });
}

Object? _readJson(String path) => jsonDecode(File(path).readAsStringSync());

Map<String, Object?> _release(String tag) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': [
    {'name': 'release-manifest.json'},
  ],
};

Map<String, Object?> _manifest(String tag, String version, int buildNumber) => {
  'schemaVersion': 1,
  'tag': tag,
  'commit': 'a' * 40,
  'workflowRunId': 1,
  'version': version,
  'buildNumber': buildNumber,
  'android': {
    'packageName': 'com.follow.flashco',
    'signerSha256': 'f' * 64,
    'abis': ['armeabi-v7a', 'arm64-v8a', 'x86_64'],
  },
  'assets': [
    {'name': 'Flashco-$version-android.apk', 'size': 10, 'sha256': 'a' * 64},
    {
      'name': 'Flashco-$version-windows-amd64-setup.exe',
      'size': 11,
      'sha256': 'b' * 64,
    },
    {
      'name': 'Flashco-$version-windows-amd64.zip',
      'size': 12,
      'sha256': 'c' * 64,
    },
  ],
};

ReleaseBundleCandidate _candidate({
  required int runId,
  required String tag,
  required String sourceSha,
  bool expired = false,
  bool corruptChecksums = false,
}) {
  const apk = 'Flashco-1.2.3-android.apk';
  const exe = 'Flashco-1.2.3-windows-amd64-setup.exe';
  const zip = 'Flashco-1.2.3-windows-amd64.zip';
  final assetHashes = {apk: 'a' * 64, exe: 'b' * 64, zip: 'c' * 64};
  final manifest = {
    ..._manifest(tag, '1.2.3', 12),
    'workflowRunId': runId,
    'commit': sourceSha,
    'android': {
      'packageName': 'com.follow.flashco',
      'signerSha256': 'f' * 64,
      'abis': ['armeabi-v7a', 'arm64-v8a', 'x86_64'],
    },
    'assets': [
      {'name': apk, 'size': 10, 'sha256': assetHashes[apk]},
      {'name': exe, 'size': 11, 'sha256': assetHashes[exe]},
      {'name': zip, 'size': 12, 'sha256': assetHashes[zip]},
    ],
  };
  final manifestHash = 'd' * 64;
  final sums = [
    '${assetHashes[apk]}  $apk',
    '${assetHashes[exe]}  $exe',
    '${assetHashes[zip]}  $zip',
    '$manifestHash  release-manifest.json',
  ].join('\n');

  return ReleaseBundleCandidate(
    artifactRunId: runId,
    expired: expired,
    manifest: manifest,
    observedAssetHashes: assetHashes,
    manifestSha256: manifestHash,
    sha256Sums: corruptChecksums ? '$sums\n${'e' * 64}  extra.zip' : sums,
  );
}
