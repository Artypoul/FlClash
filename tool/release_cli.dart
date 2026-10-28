import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'release_bundle.dart';
import 'release_github.dart';
import 'release_pipeline.dart';
import 'release_preflight.dart';
import 'release_publisher.dart';

final _nativeApkPathPattern = RegExp(r'^/lib/[^/]+/[^/]+\.so$');

const _repository = 'Artypoul/Flashco';
const _releaseWorkflowPath = '.github/workflows/release.yaml';
const _buildWorkflowId = '385298741';
final _shaPattern = RegExp(r'^[0-9a-f]{40}$');
final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');
final _stableTagPattern = RegExp(
  r'^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$',
);

typedef ReleaseCommandRunner =
    Future<ReleaseCommandResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

class ReleaseCommandResult {
  const ReleaseCommandResult(this.exitCode, this.stdout, [this.stderr = '']);

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _FileContentIdentity {
  const _FileContentIdentity(this.sha256, this.size);

  final String sha256;
  final int size;
}

Future<_FileContentIdentity> _fileContentIdentity(File file) async {
  final bytes = await file.readAsBytes();
  return _FileContentIdentity(sha256.convert(bytes).toString(), bytes.length);
}

Future<ReleaseCommandResult> _processRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: true,
    runInShell: false,
  );
  return ReleaseCommandResult(
    result.exitCode,
    result.stdout.toString(),
    result.stderr.toString(),
  );
}

class ReleaseCli {
  ReleaseCli({
    required Map<String, String> environment,
    ReleaseCommandRunner? runner,
    ReleaseApiExecutor? releaseApiExecutor,
  }) : _environment = Map.unmodifiable(environment),
       _runner = runner ?? _processRunner,
       _releaseApiExecutor = releaseApiExecutor;

  final Map<String, String> _environment;
  final ReleaseCommandRunner _runner;
  final ReleaseApiExecutor? _releaseApiExecutor;

  Future<Map<String, String>> _bundle({bool verifyExisting = false}) async {
    final context = _readBundleContext(_environment);
    await _verifyBundleCheckout(context);
    final bundleDirectory = Directory(
      _environment['RELEASE_BUNDLE_DIR'] ?? 'build/release-bundle',
    );
    if (!bundleDirectory.existsSync()) {
      throw const ReleasePreflightException(
        'Release bundle directory is missing.',
      );
    }
    final payloadFiles = await _readPayloadFiles(
      bundleDirectory,
      version: context.version,
      allowMetadata: verifyExisting || context.recoveryAction == 'reuse',
    );
    final apkName = 'Flashco-${context.version}-android.apk';
    final apkFile = payloadFiles[apkName]!;
    final sdkInputIdentity = await _fileContentIdentity(apkFile);
    final androidOutputs = await _readAndroidSdkOutputs(apkFile);
    await _requireSameFileContent(apkFile, sdkInputIdentity);
    final releaseBody = await _renderReleaseBody(context.tag);
    await _requireSameFileContent(apkFile, sdkInputIdentity);
    final manifestFile = File(
      path.join(bundleDirectory.path, 'release-manifest.json'),
    );
    final sumsFile = File(path.join(bundleDirectory.path, 'SHA256SUMS'));
    final bodyFile = File(path.join(bundleDirectory.path, 'release.md'));

    if (context.recoveryAction == 'build' && !verifyExisting) {
      final bundle = await buildReleaseBundle(
        tag: context.tag,
        commit: context.sourceSha,
        workflowRunId: context.originalRunId,
        version: context.version,
        buildNumber: context.buildNumber,
        expectedSignerSha256: context.expectedSigner,
        androidOutputs: androidOutputs,
        payloadFiles: payloadFiles,
      );
      _writeNewFile(manifestFile, bundle.manifestJson);
      _writeNewFile(sumsFile, bundle.sha256Sums);
      _writeNewFile(bodyFile, releaseBody);
    } else {
      final savedBody = await bodyFile.readAsString();
      if (savedBody != releaseBody) {
        throw const FormatException(
          'Saved release body does not match the source changelog.',
        );
      }
    }

    final verified = await verifyReleaseBundle(
      tag: context.tag,
      commit: context.sourceSha,
      workflowRunId: context.originalRunId,
      expectedSignerSha256: context.expectedSigner,
      androidOutputs: androidOutputs,
      payloadFiles: payloadFiles,
      manifestJson: await manifestFile.readAsString(),
      sha256Sums: await sumsFile.readAsString(),
    );
    if (verified.assetHashes[apkName] != sdkInputIdentity.sha256 ||
        verified.assetSizes[apkName] != sdkInputIdentity.size) {
      throw const FormatException(
        'Android package bytes changed during release bundle verification.',
      );
    }
    if (verified.manifest['version'] != context.version ||
        verified.manifest['buildNumber'] != context.buildNumber) {
      throw const FormatException(
        'Saved release manifest does not match the selected source version.',
      );
    }
    return {
      'bundle_verified': 'true',
      'release_bundle_dir': bundleDirectory.absolute.path,
      'manifest_sha256': verified.manifestSha256,
      'original_run_id': '${context.originalRunId}',
      'original_run_attempt': '${context.originalRunAttempt}',
      'bundle_artifact_name': _bundleArtifactName(
        context.tag,
        context.originalRunId,
        context.originalRunAttempt,
      ),
    };
  }

  Future<void> _requireSameFileContent(
    File file,
    _FileContentIdentity expected,
  ) async {
    final actual = await _fileContentIdentity(file);
    if (actual.sha256 != expected.sha256 || actual.size != expected.size) {
      throw const FormatException(
        'Android package changed during SDK verification.',
      );
    }
  }

  Future<Map<String, String>> _publish() async {
    final context = _readBundleContext(_environment);
    final initialPreflight = await _preflight();
    _verifyPreflightSelection(initialPreflight, context);
    await _verifyCurrentBundleJob(context, initialPreflight);
    final bundle = await _bundle(verifyExisting: true);
    if (bundle['bundle_verified'] != 'true') {
      throw const ReleasePreflightException(
        'Saved release bundle did not pass verification.',
      );
    }
    _verifyPreflightSelection(initialPreflight, context);
    final directory = Directory(bundle['release_bundle_dir']!);
    final assets = <String, File>{
      'Flashco-${context.version}-android.apk': File(
        path.join(directory.path, 'Flashco-${context.version}-android.apk'),
      ),
      'Flashco-${context.version}-windows-amd64-setup.exe': File(
        path.join(
          directory.path,
          'Flashco-${context.version}-windows-amd64-setup.exe',
        ),
      ),
      'Flashco-${context.version}-windows-amd64.zip': File(
        path.join(
          directory.path,
          'Flashco-${context.version}-windows-amd64.zip',
        ),
      ),
      'release-manifest.json': File(
        path.join(directory.path, 'release-manifest.json'),
      ),
      'SHA256SUMS': File(path.join(directory.path, 'SHA256SUMS')),
    };
    final token = _environment['GH_TOKEN']!;
    final executor =
        _releaseApiExecutor ?? createGhReleaseApiExecutor(token: token);
    final result = await publishDraftRelease(
      tag: context.tag,
      sourceSha: context.sourceSha,
      originalRunId: context.originalRunId,
      assets: assets,
      releaseBody: await File(
        path.join(directory.path, 'release.md'),
      ).readAsString(),
      execute: executor,
      revalidate: () async {
        final freshPreflight = await _preflight();
        _verifyPreflightSelection(freshPreflight, context);
        final freshBundle = await _bundle(verifyExisting: true);
        if (freshBundle['bundle_verified'] != 'true' ||
            freshBundle['manifest_sha256'] != bundle['manifest_sha256']) {
          throw const ReleasePreflightException(
            'Saved release bundle changed after initial verification.',
          );
        }
      },
    );
    return {
      'draft_release_id': '${result.releaseId}',
      'draft_release_completed': 'true',
    };
  }

  void _verifyPreflightSelection(
    Map<String, String> preflight,
    _BundleContext context,
  ) {
    if (preflight['source_sha'] != context.sourceSha ||
        preflight['release_version'] != context.version ||
        preflight['build_number'] != '${context.buildNumber}' ||
        preflight['recovery_action'] != context.recoveryAction ||
        preflight['original_run_id'] != '${context.originalRunId}' ||
        preflight['original_run_attempt'] != '${context.originalRunAttempt}' ||
        preflight['bundle_artifact_name'] !=
            _bundleArtifactName(
              context.tag,
              context.originalRunId,
              context.originalRunAttempt,
            )) {
      throw const ReleasePreflightException(
        'Fresh release preflight does not match the verified bundle.',
      );
    }
  }

  Future<void> _verifyCurrentBundleJob(
    _BundleContext context,
    Map<String, String> preflight,
  ) async {
    if (context.recoveryAction != 'build') return;
    final currentRunId = int.parse(_environment['GITHUB_RUN_ID']!);
    final currentAttempt = int.parse(_environment['GITHUB_RUN_ATTEMPT']!);
    if (context.originalRunId != currentRunId ||
        context.originalRunAttempt != currentAttempt ||
        preflight['recovery_action'] != 'build') {
      throw const ReleasePreflightException(
        'Current bundle job does not match the selected release attempt.',
      );
    }
    final response = await _ghPaginated(
      'repos/$_repository/actions/runs/$currentRunId/attempts/$currentAttempt/jobs?per_page=100',
      {'GH_TOKEN': _environment['GH_TOKEN']!},
    );
    final jobs = _flattenPaginatedList(response, 'jobs', 'current bundle job');
    if (!_hasCompletedBundleJob(jobs, currentAttempt)) {
      throw const ReleasePreflightException(
        'The selected run has no successful completed bundle job.',
      );
    }
  }

  Future<void> _verifyBundleCheckout(_BundleContext context) async {
    final head = (await _git(['rev-parse', 'HEAD'])).trim().toLowerCase();
    if (head != context.sourceSha) {
      throw const ReleasePreflightException(
        'Bundle checkout does not match the selected source commit.',
      );
    }
    final committedPubspec = await _git(['show', 'HEAD:pubspec.yaml']);
    final (version, buildNumber) = _readPubspecVersion(committedPubspec);
    if (version != context.version || buildNumber != context.buildNumber) {
      throw const ReleasePreflightException(
        'Bundle checkout version does not match release preflight.',
      );
    }
    final status = await _runner('git', [
      'status',
      '--porcelain',
      '--untracked-files=no',
    ]);
    if (status.exitCode != 0 || status.stdout.trim().isNotEmpty) {
      throw const ReleasePreflightException(
        'Bundle checkout contains modified tracked source files.',
      );
    }
  }

  Future<AndroidSdkCommandOutputs> _readAndroidSdkOutputs(File apk) async {
    final sdkRoot = _androidSdkRoot(_environment);
    final analyzer = File(
      path.join(sdkRoot, 'cmdline-tools', 'latest', 'bin', 'apkanalyzer'),
    );
    final buildToolsDirectory = Directory(path.join(sdkRoot, 'build-tools'));
    if (!analyzer.existsSync() || !buildToolsDirectory.existsSync()) {
      throw const ReleasePreflightException(
        'Required Android SDK tools are missing.',
      );
    }
    final signer = _latestApksigner(buildToolsDirectory);
    final apkPath = apk.absolute.path;
    Future<String> analyzerOutput(List<String> arguments) async {
      final result = await _runner(analyzer.path, [...arguments, apkPath]);
      if (result.exitCode != 0) {
        throw const ReleasePreflightException(
          'Android SDK metadata could not be read from the staged APK.',
        );
      }
      return result.stdout.trim();
    }

    final applicationId = await analyzerOutput(['manifest', 'application-id']);
    final versionName = await analyzerOutput(['manifest', 'version-name']);
    final versionCode = await analyzerOutput(['manifest', 'version-code']);
    final debuggable = await analyzerOutput(['manifest', 'debuggable']);
    final applicationXml = await analyzerOutput(['manifest', 'print']);
    final allPaths = await analyzerOutput(['files', 'list']);
    final abiPaths = const LineSplitter()
        .convert(allPaths)
        .map((line) => line.trim())
        .where((line) => _nativeApkPathPattern.hasMatch(line))
        .join('\n');
    final signerResult = await _runner(signer.path, [
      'verify',
      '--print-certs',
      apkPath,
    ]);
    if (signerResult.exitCode != 0) {
      throw const ReleasePreflightException(
        'Android APK signature verification failed.',
      );
    }
    return AndroidSdkCommandOutputs(
      identity:
          'application-id: $applicationId\n'
          'version-name: $versionName\n'
          'version-code: $versionCode\n'
          'debuggable: $debuggable\n',
      applicationXml: applicationXml,
      certificates: signerResult.stdout,
      abiPaths: abiPaths,
    );
  }

  Future<String> _renderReleaseBody(String tag) async {
    final directory = await Directory.systemTemp.createTemp(
      'flashco-release-body-',
    );
    final output = File(path.join(directory.path, 'release.md'));
    try {
      final result = await _runner('dart', [
        'run',
        'tool/changelog.dart',
        'render',
        'release',
        '--tag',
        tag,
        '--out',
        output.path,
      ]);
      if (result.exitCode != 0 || !output.existsSync()) {
        throw const ReleasePreflightException(
          'Release changelog could not be rendered for the selected tag.',
        );
      }
      return await output.readAsString();
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<ReleaseCliResult> run(List<String> arguments) async {
    if (arguments.length != 1 ||
        !const {'preflight', 'bundle', 'publish'}.contains(arguments.single)) {
      return const ReleaseCliResult(
        2,
        error:
            'Usage: dart run tool/release_cli.dart <preflight|bundle|publish>',
      );
    }
    if (arguments.single == 'bundle') {
      try {
        final output = await _bundle();
        final outputPath = _environment['GITHUB_OUTPUT'];
        if (outputPath != null && outputPath.isNotEmpty) {
          await _appendOutputs(outputPath, output);
        }
        return ReleaseCliResult(0, output: output);
      } on ReleasePreflightException catch (error) {
        return ReleaseCliResult(1, error: error.message);
      } on FormatException catch (error) {
        return ReleaseCliResult(1, error: error.message);
      } on Object {
        return const ReleaseCliResult(
          1,
          error:
              'Release bundle failed because required files or evidence were invalid.',
        );
      }
    }
    if (arguments.single == 'publish') {
      try {
        final output = await _publish();
        final outputPath = _environment['GITHUB_OUTPUT'];
        if (outputPath != null && outputPath.isNotEmpty) {
          await _appendOutputs(outputPath, output);
        }
        return ReleaseCliResult(0, output: output);
      } on ReleasePreflightException catch (error) {
        return ReleaseCliResult(1, error: error.message);
      } on ReleasePublishException catch (error) {
        return ReleaseCliResult(1, error: error.message);
      } on FormatException catch (error) {
        return ReleaseCliResult(1, error: error.message);
      } on Object {
        return const ReleaseCliResult(
          1,
          error:
              'Release publish stopped because verification or GitHub state was invalid.',
        );
      }
    }
    if (arguments.single != 'preflight') {
      return ReleaseCliResult(
        2,
        error:
            'The ${arguments.single} command is not available in this stage.',
      );
    }
    try {
      final output = await _preflight();
      final outputPath = _environment['GITHUB_OUTPUT'];
      if (outputPath != null && outputPath.isNotEmpty) {
        await _appendOutputs(outputPath, output);
      }
      return ReleaseCliResult(0, output: output);
    } on ReleasePreflightException catch (error) {
      return ReleaseCliResult(1, error: error.message);
    } on Object {
      return const ReleaseCliResult(
        1,
        error:
            'Release preflight failed because required evidence was invalid or unavailable.',
      );
    }
  }

  Future<Map<String, String>> _preflight() async {
    final required = <String>[
      'GH_TOKEN',
      'GITHUB_EVENT_NAME',
      'GITHUB_REF',
      'GITHUB_SHA',
      'GITHUB_RUN_ID',
      'GITHUB_RUN_ATTEMPT',
      'GITHUB_REPOSITORY',
      'GITHUB_WORKFLOW_REF',
      'GITHUB_WORKFLOW_SHA',
      'RELEASE_TAG',
      'ANDROID_CERT_SHA256',
    ];
    if (required.any((key) => (_environment[key] ?? '').isEmpty)) {
      throw const ReleasePreflightException(
        'Release preflight environment is incomplete.',
      );
    }
    final env = _environment;
    final tag = env['RELEASE_TAG']!;
    final currentRunId = int.tryParse(env['GITHUB_RUN_ID']!);
    final currentAttempt = int.tryParse(env['GITHUB_RUN_ATTEMPT']!);
    final workflowSha = env['GITHUB_WORKFLOW_SHA']!.toLowerCase();
    final dispatchSha = env['GITHUB_SHA']!.toLowerCase();
    final fingerprint = env['ANDROID_CERT_SHA256']!
        .replaceAll(':', '')
        .replaceAll(' ', '')
        .toLowerCase();
    if (env['GITHUB_REPOSITORY'] != _repository ||
        env['GITHUB_EVENT_NAME'] != 'workflow_dispatch' ||
        env['GITHUB_REF'] != 'refs/heads/main' ||
        env['GITHUB_WORKFLOW_REF'] !=
            '$_repository/$_releaseWorkflowPath@refs/heads/main' ||
        !_shaPattern.hasMatch(dispatchSha) ||
        !_shaPattern.hasMatch(workflowSha) ||
        currentRunId == null ||
        currentRunId <= 0 ||
        currentAttempt == null ||
        currentAttempt <= 0 ||
        !_stableTagPattern.hasMatch(tag) ||
        !_fingerprintPattern.hasMatch(fingerprint)) {
      throw const ReleasePreflightException(
        'Release dispatch identity is invalid.',
      );
    }

    const mainRef = 'refs/release-preflight/main';
    const tagRef = 'refs/release-preflight/tag';
    await _git(['fetch', '--no-tags', 'origin', 'refs/heads/main:$mainRef']);
    await _git(['fetch', '--no-tags', 'origin', 'refs/tags/$tag:$tagRef']);
    final sourceSha = (await _git([
      'rev-parse',
      '$tagRef^{commit}',
    ])).trim().toLowerCase();
    final mainSha = (await _git([
      'rev-parse',
      '$mainRef^{commit}',
    ])).trim().toLowerCase();
    if (!_shaPattern.hasMatch(sourceSha) || !_shaPattern.hasMatch(mainSha)) {
      throw const ReleasePreflightException(
        'Release tag does not resolve to a full commit on main.',
      );
    }
    await _git(['merge-base', '--is-ancestor', workflowSha, mainRef]);
    await _git(['merge-base', '--is-ancestor', dispatchSha, mainRef]);
    await _git(['merge-base', '--is-ancestor', sourceSha, mainRef]);
    final pubspec = await _git(['show', '$sourceSha:pubspec.yaml']);
    final identity = _readPubspecVersion(pubspec);
    final version = identity.$1;
    final buildNumber = identity.$2;
    final identityErrors = validateReleaseSource(
      workflowRef: env['GITHUB_REF']!,
      tag: tag,
      tagSha: sourceSha,
      sourceSha: sourceSha,
      sourceReachableFromMain: true,
      version: version,
      buildNumber: buildNumber,
    );
    if (identityErrors.isNotEmpty) {
      throw const ReleasePreflightException(
        'Release tag and source version do not match.',
      );
    }

    final apiEnv = {'GH_TOKEN': env['GH_TOKEN']!};
    final currentRun = await _ghObject(
      'repos/$_repository/actions/runs/$currentRunId',
      apiEnv,
    );
    if (currentRun['id'] != currentRunId ||
        currentRun['workflow_id'] is! int ||
        (currentRun['workflow_id'] as int) <= 0 ||
        currentRun['path'] != _releaseWorkflowPath ||
        currentRun['event'] != 'workflow_dispatch' ||
        currentRun['head_branch'] != 'main' ||
        currentRun['head_sha'] != dispatchSha ||
        currentRun['display_title'] != 'release-$tag' ||
        currentRun['run_number'] is! int ||
        (currentRun['run_number'] as int) <= 0 ||
        currentRun['run_attempt'] != currentAttempt) {
      throw const ReleasePreflightException(
        'Current release workflow provenance is invalid.',
      );
    }
    final currentWorkflowId = currentRun['workflow_id'] as int;
    final currentRunNumber = currentRun['run_number'] as int;
    final buildRunsResponse = await _ghPaginated(
      'repos/$_repository/actions/workflows/$_buildWorkflowId/runs?head_sha=$sourceSha&per_page=100',
      apiEnv,
    );
    final buildRuns = _mapBuildRuns(buildRunsResponse);
    if (buildRuns.isEmpty) {
      throw const ReleasePreflightException(
        'No build workflow run exists for the release source.',
      );
    }
    final latest = _newestBuildRun(buildRuns);
    final runId = latest['databaseId']! as int;
    final jobsResponse = await _ghPaginated(
      'repos/$_repository/actions/runs/$runId/jobs?per_page=100',
      apiEnv,
    );
    final latestDetails = <String, Object?>{
      ...latest,
      'jobs': _mapJobs(jobsResponse),
    };
    final ciErrors = validateLatestBuildCi(
      completeRunList: true,
      sourceSha: sourceSha,
      runs: buildRuns,
      latestRun: latestDetails,
    );
    if (ciErrors.isNotEmpty) {
      throw const ReleasePreflightException(
        'The latest build checks for this source are incomplete or unsuccessful.',
      );
    }

    final releasesResponse = await _ghPaginated(
      'repos/$_repository/releases?per_page=100',
      apiEnv,
    );
    final releases = _flattenReleasePages(releasesResponse);
    if (releases.any(
      (release) =>
          release is Map &&
          release['tag_name'] == tag &&
          release['draft'] != true,
    )) {
      throw const ReleasePreflightException(
        'This release tag is already published.',
      );
    }
    final manifestsByTag = <String, Map<String, Object?>>{};
    for (final release in releases) {
      if (release is! Map ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        continue;
      }
      final stableTag = release['tag_name'];
      final assets = release['assets'];
      if (stableTag is! String || assets is! List) {
        throw const ReleasePreflightException(
          'Published release history contains an invalid release.',
        );
      }
      final manifestAssets = assets.where(
        (asset) => asset is Map && asset['name'] == 'release-manifest.json',
      );
      if (manifestAssets.length != 1 ||
          (manifestAssets.single as Map)['id'] is! int ||
          ((manifestAssets.single as Map)['id'] as int) <= 0) {
        throw const ReleasePreflightException(
          'Published release history is missing a unique manifest asset.',
        );
      }
      final manifestId = (manifestAssets.single as Map)['id'] as int;
      final manifestResult = await _runner('gh', [
        'api',
        '--hostname',
        'github.com',
        '-H',
        'Accept: application/octet-stream',
        'repos/$_repository/releases/assets/$manifestId',
      ], environment: apiEnv);
      if (manifestResult.exitCode != 0) {
        throw const ReleasePreflightException(
          'A published release manifest could not be read.',
        );
      }
      try {
        final decodedManifest = jsonDecode(manifestResult.stdout);
        if (decodedManifest is! Map ||
            decodedManifest.keys.any((key) => key is! String)) {
          throw const FormatException();
        }
        manifestsByTag[stableTag] = Map<String, Object?>.from(decodedManifest);
      } on FormatException {
        throw const ReleasePreflightException(
          'A published release manifest is invalid.',
        );
      }
    }
    final publishedHistory = summarizePublishedHistory(
      complete: true,
      releases: releases,
      manifestsByTag: manifestsByTag,
    );
    if (publishedHistory.errors.isNotEmpty) {
      throw const ReleasePreflightException(
        'Published release history is invalid or incomplete.',
      );
    }
    final upgradeErrors = validatePublishedUpgrade(
      version: version,
      buildNumber: buildNumber,
      publishedVersion: publishedHistory.highestVersion,
      publishedBuildNumber: publishedHistory.highestBuildNumber,
    );
    if (upgradeErrors.isNotEmpty) {
      throw const ReleasePreflightException(
        'The source version does not advance published release history.',
      );
    }

    final priorRunsResponse = await _ghPaginated(
      'repos/$_repository/actions/workflows/release.yaml/runs?event=workflow_dispatch&branch=main&per_page=100',
      apiEnv,
    );
    final priorRuns = _mapWorkflowRuns(
      priorRunsResponse,
      tag,
      currentRunId: currentRunId,
      currentRunNumber: currentRunNumber,
    );
    if (priorRuns.any((run) => run['workflow_id'] != currentWorkflowId)) {
      throw const ReleasePreflightException(
        'A prior release run belongs to a different workflow.',
      );
    }
    for (final run in priorRuns) {
      await _git([
        'merge-base',
        '--is-ancestor',
        run['head_sha'] as String,
        mainRef,
      ]);
    }
    final draftsExist = releases.any(
      (release) =>
          release is Map &&
          release['tag_name'] == tag &&
          release['draft'] == true,
    );
    final previousRuns = priorRuns
        .where((run) => run['id'] != currentRunId)
        .toList();
    final isRerun = currentAttempt > 1;
    if (draftsExist || isRerun || previousRuns.isNotEmpty) {
      final candidates = <Map<String, Object?>>[];
      for (final prior in priorRuns) {
        final priorId = prior['id'] as int;
        final latestAttempt = prior['run_attempt'] as int;
        final artifacts = _readArtifactInventory(
          _flattenPaginatedList(
            await _ghPaginated(
              'repos/$_repository/actions/runs/$priorId/artifacts?per_page=100',
              apiEnv,
            ),
            'artifacts',
            'artifact inventory',
          ),
          runId: priorId,
        );
        for (var attempt = 1; attempt <= latestAttempt; attempt++) {
          if (priorId == currentRunId && attempt >= currentAttempt) {
            continue;
          }
          final matching = artifacts
              .where(
                (value) =>
                    value['name'] == _bundleArtifactName(tag, priorId, attempt),
              )
              .toList();
          if (matching.length > 1) {
            throw const ReleasePreflightException(
              'A prior bundle artifact is ambiguous.',
            );
          }
          if (matching.length == 1) {
            final artifact = matching.single;
            final workflowRun = artifact['workflow_run'] as Map;
            if (artifact['expired'] != false ||
                (artifact['size_in_bytes'] as int) <= 0 ||
                workflowRun['head_sha'] != prior['head_sha']) {
              throw const ReleasePreflightException(
                'A prior bundle artifact is expired or has conflicting provenance.',
              );
            }
            final jobs = _flattenPaginatedList(
              await _ghPaginated(
                'repos/$_repository/actions/runs/$priorId/attempts/$attempt/jobs?per_page=100',
                apiEnv,
              ),
              'jobs',
              'bundle job history',
            );
            if (!_hasCompletedBundleJob(jobs, attempt)) {
              throw const ReleasePreflightException(
                'A prior bundle artifact has no completed bundle job.',
              );
            }
            candidates.add({
              'run': prior,
              'artifact': artifact,
              'attempt': attempt,
            });
          }
        }
      }
      if (candidates.length != 1 || candidates.single['run'] == null) {
        throw const ReleasePreflightException(
          'A previous release attempt exists but its original bundle cannot be identified safely.',
        );
      }
      final candidateRun = candidates.single['run'] as Map<String, Object?>;
      final candidateAttempt = candidates.single['attempt'] as int;
      return {
        'source_sha': sourceSha,
        'release_version': version,
        'build_number': '$buildNumber',
        'recovery_action': 'reuse',
        'original_run_id': '${candidateRun['id']}',
        'original_run_attempt': '$candidateAttempt',
        'bundle_artifact_name': _bundleArtifactName(
          tag,
          candidateRun['id'] as int,
          candidateAttempt,
        ),
      };
    }
    return {
      'source_sha': sourceSha,
      'release_version': version,
      'build_number': '$buildNumber',
      'recovery_action': 'build',
      'original_run_id': '$currentRunId',
      'original_run_attempt': '$currentAttempt',
      'bundle_artifact_name': _bundleArtifactName(
        tag,
        currentRunId,
        currentAttempt,
      ),
    };
  }

  Future<String> _git(List<String> args) async {
    final result = await _runner('git', args);
    if (result.exitCode != 0) {
      throw const ReleasePreflightException(
        'Trusted source evidence could not be read.',
      );
    }
    return result.stdout;
  }

  Future<List<Object?>> _ghPaginated(
    String endpoint,
    Map<String, String> environment,
  ) async {
    final result = await _runner('gh', [
      'api',
      '--hostname',
      'github.com',
      '--paginate',
      '--slurp',
      endpoint,
    ], environment: environment);
    if (result.exitCode != 0) {
      throw const ReleasePreflightException(
        'A required GitHub API read failed.',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(result.stdout);
    } on FormatException {
      throw const ReleasePreflightException(
        'A GitHub API response was invalid.',
      );
    }
    if (decoded is! List || decoded.isEmpty) {
      throw const ReleasePreflightException(
        'A GitHub API response was incomplete.',
      );
    }
    return decoded;
  }

  Future<Map<String, Object?>> _ghObject(
    String endpoint,
    Map<String, String> environment,
  ) async {
    final result = await _runner('gh', [
      'api',
      '--hostname',
      'github.com',
      endpoint,
    ], environment: environment);
    if (result.exitCode != 0) {
      throw const ReleasePreflightException(
        'A required GitHub API read failed.',
      );
    }
    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw const FormatException();
      }
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const ReleasePreflightException(
        'A GitHub API response was invalid.',
      );
    }
  }
}

class ReleaseCliResult {
  const ReleaseCliResult(this.exitCode, {this.output = const {}, this.error});

  final int exitCode;
  final Map<String, String> output;
  final String? error;
}

class ReleasePreflightException implements Exception {
  const ReleasePreflightException(this.message);

  final String message;
}

class _BundleContext {
  const _BundleContext({
    required this.tag,
    required this.sourceSha,
    required this.version,
    required this.buildNumber,
    required this.recoveryAction,
    required this.originalRunId,
    required this.originalRunAttempt,
    required this.expectedSigner,
  });

  final String tag;
  final String sourceSha;
  final String version;
  final int buildNumber;
  final String recoveryAction;
  final int originalRunId;
  final int originalRunAttempt;
  final String expectedSigner;
}

_BundleContext _readBundleContext(Map<String, String> environment) {
  const signingSecretNames = {
    'ANDROID_KEYSTORE_BASE64',
    'ANDROID_STORE_PASSWORD',
    'ANDROID_KEY_ALIAS',
    'ANDROID_KEY_PASSWORD',
  };
  if (signingSecretNames.any(environment.containsKey)) {
    throw const ReleasePreflightException(
      'Signing secrets must not be available to bundle assembly.',
    );
  }
  final tag = environment['RELEASE_TAG'];
  final sourceSha = environment['SOURCE_SHA']?.toLowerCase();
  final version = environment['RELEASE_VERSION'];
  final buildNumber = int.tryParse(environment['BUILD_NUMBER'] ?? '');
  final currentRunId = int.tryParse(environment['GITHUB_RUN_ID'] ?? '');
  final currentAttempt = int.tryParse(environment['GITHUB_RUN_ATTEMPT'] ?? '');
  final originalRunId = int.tryParse(environment['ORIGINAL_RUN_ID'] ?? '');
  final originalRunAttempt = int.tryParse(
    environment['ORIGINAL_RUN_ATTEMPT'] ?? '',
  );
  final recoveryAction = environment['RECOVERY_ACTION'];
  final expectedSigner = environment['ANDROID_CERT_SHA256']
      ?.replaceAll(':', '')
      .replaceAll(' ', '')
      .toLowerCase();
  if (environment['GITHUB_REPOSITORY'] != _repository ||
      tag == null ||
      !_stableTagPattern.hasMatch(tag) ||
      sourceSha == null ||
      !_shaPattern.hasMatch(sourceSha) ||
      version == null ||
      tag != 'v$version' ||
      buildNumber == null ||
      buildNumber <= 0 ||
      currentRunId == null ||
      currentRunId <= 0 ||
      currentAttempt == null ||
      currentAttempt <= 0 ||
      originalRunId == null ||
      originalRunId <= 0 ||
      originalRunAttempt == null ||
      originalRunAttempt <= 0 ||
      recoveryAction == null ||
      !const {'build', 'reuse'}.contains(recoveryAction) ||
      expectedSigner == null ||
      !_fingerprintPattern.hasMatch(expectedSigner) ||
      (recoveryAction == 'build' &&
          (currentRunId != originalRunId ||
              currentAttempt != originalRunAttempt))) {
    throw const ReleasePreflightException(
      'Release bundle identity or recovery inputs are invalid.',
    );
  }
  return _BundleContext(
    tag: tag,
    sourceSha: sourceSha,
    version: version,
    buildNumber: buildNumber,
    recoveryAction: recoveryAction,
    originalRunId: originalRunId,
    originalRunAttempt: originalRunAttempt,
    expectedSigner: expectedSigner,
  );
}

Future<Map<String, File>> _readPayloadFiles(
  Directory directory, {
  required String version,
  required bool allowMetadata,
}) async {
  final expectedPayloadNames = {
    'Flashco-$version-android.apk',
    'Flashco-$version-windows-amd64-setup.exe',
    'Flashco-$version-windows-amd64.zip',
  };
  final expectedNames = allowMetadata
      ? {
          ...expectedPayloadNames,
          'release-manifest.json',
          'SHA256SUMS',
          'release.md',
        }
      : expectedPayloadNames;
  final files = <String, File>{};
  await for (final entity in directory.list(followLinks: false)) {
    final name = path.basename(entity.path);
    if (!expectedNames.contains(name) ||
        FileSystemEntity.typeSync(entity.path, followLinks: false) !=
            FileSystemEntityType.file ||
        files.containsKey(name)) {
      throw const ReleasePreflightException(
        'Release bundle directory contains unexpected entries.',
      );
    }
    files[name] = File(entity.path);
  }
  if (files.keys.toSet().difference(expectedNames).isNotEmpty ||
      expectedNames.difference(files.keys.toSet()).isNotEmpty) {
    throw ReleasePreflightException(
      'Release bundle directory has a missing or unexpected file: '
      'expected ${expectedNames.toList()..sort()}, '
      'found ${files.keys.toList()..sort()}.',
    );
  }
  return {for (final name in expectedPayloadNames) name: files[name]!};
}

String _androidSdkRoot(Map<String, String> environment) {
  final home = environment['ANDROID_HOME'];
  final root = environment['ANDROID_SDK_ROOT'];
  if (home != null &&
      home.isNotEmpty &&
      root != null &&
      root.isNotEmpty &&
      path.normalize(home) != path.normalize(root)) {
    throw const ReleasePreflightException(
      'Android SDK root variables disagree.',
    );
  }
  final value = (root?.isNotEmpty == true ? root : home)?.trim();
  if (value == null || value.isEmpty || !Directory(value).existsSync()) {
    throw const ReleasePreflightException('Android SDK root is unavailable.');
  }
  return value;
}

File _latestApksigner(Directory buildToolsDirectory) {
  final versions =
      buildToolsDirectory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where(
            (directory) => RegExp(
              r'^[0-9]+(?:\.[0-9]+)*$',
            ).hasMatch(path.basename(directory.path)),
          )
          .toList()
        ..sort(
          (left, right) => _compareNumericVersions(
            path.basename(left.path),
            path.basename(right.path),
          ),
        );
  for (final version in versions.reversed) {
    final signer = File(path.join(version.path, 'apksigner'));
    if (signer.existsSync()) return signer;
  }
  throw const ReleasePreflightException(
    'Android SDK apksigner is unavailable.',
  );
}

int _compareNumericVersions(String left, String right) {
  final leftParts = left.split('.').map(int.parse).toList();
  final rightParts = right.split('.').map(int.parse).toList();
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    final comparison = leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return 0;
}

void _writeNewFile(File file, String contents) {
  file.createSync(exclusive: true);
  file.writeAsStringSync(contents, flush: true);
}

Future<void> _appendOutputs(String path, Map<String, String> output) async {
  final file = File(path);
  final lines = output.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('\n');
  await file.writeAsString('$lines\n', mode: FileMode.append, flush: true);
}

(String, int) _readPubspecVersion(String contents) {
  final match = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) {
    throw const ReleasePreflightException(
      'The source version declaration is invalid.',
    );
  }
  final buildNumber = int.tryParse(match[2]!);
  if (buildNumber == null) {
    throw const ReleasePreflightException(
      'The source build number is invalid.',
    );
  }
  return (match[1]!, buildNumber);
}

List<Map<String, Object?>> _flattenPaginatedList(
  List<Object?> pages,
  String key,
  String label,
) {
  final result = <Map<String, Object?>>[];
  final ids = <int>{};
  int? totalCount;
  for (final value in pages) {
    if (value is! Map || value.keys.any((item) => item is! String)) {
      throw ReleasePreflightException('The $label response is invalid.');
    }
    final page = Map<String, Object?>.from(value);
    final count = page['total_count'];
    final values = page[key];
    if (count is! int ||
        values is! List ||
        (totalCount != null && totalCount != count)) {
      throw ReleasePreflightException('The $label response is incomplete.');
    }
    totalCount = count;
    for (final value in values) {
      if (value is! Map ||
          value.keys.any((item) => item is! String) ||
          value['id'] is! int ||
          (value['id'] as int) <= 0 ||
          !ids.add(value['id'] as int)) {
        throw ReleasePreflightException('The $label response is invalid.');
      }
      result.add(Map<String, Object?>.from(value));
    }
  }
  if (result.length != totalCount) {
    throw ReleasePreflightException('The $label response is incomplete.');
  }
  return result;
}

List<Object?> _flattenReleasePages(List<Object?> pages) {
  if (pages.isEmpty) {
    throw const ReleasePreflightException(
      'The release history response is incomplete.',
    );
  }
  final releases = <Object?>[];
  final ids = <int>{};
  for (final page in pages) {
    if (page is! List) {
      throw const ReleasePreflightException(
        'The release history response is invalid.',
      );
    }
    for (final value in page) {
      if (value is! Map ||
          value['id'] is! int ||
          (value['id'] as int) <= 0 ||
          !ids.add(value['id'] as int)) {
        throw const ReleasePreflightException(
          'The release history response is invalid.',
        );
      }
      releases.add(value);
    }
  }
  return releases;
}

List<Map<String, Object?>> _mapBuildRuns(List<Object?> pages) {
  final records = _flattenPaginatedList(
    pages,
    'workflow_runs',
    'build run list',
  );
  return records.map((run) {
    if (run['id'] is! int ||
        run['head_sha'] is! String ||
        run['name'] != 'build' ||
        run['status'] is! String ||
        run['conclusion'] is! String ||
        run['created_at'] is! String) {
      throw const ReleasePreflightException(
        'The build run list contains an invalid record.',
      );
    }
    return <String, Object?>{
      'databaseId': run['id'],
      'headSha': run['head_sha'],
      'workflowName': run['name'],
      'status': run['status'],
      'conclusion': run['conclusion'],
      'createdAt': run['created_at'],
    };
  }).toList();
}

Map<String, Object?> _newestBuildRun(List<Map<String, Object?>> runs) {
  final matching = runs.toList()
    ..sort((left, right) {
      final leftCreatedAt = DateTime.tryParse(left['createdAt'] as String);
      final rightCreatedAt = DateTime.tryParse(right['createdAt'] as String);
      if (leftCreatedAt == null || rightCreatedAt == null) {
        return (right['databaseId'] as int).compareTo(
          left['databaseId'] as int,
        );
      }
      final byDate = rightCreatedAt.compareTo(leftCreatedAt);
      return byDate != 0
          ? byDate
          : (right['databaseId'] as int).compareTo(left['databaseId'] as int);
    });
  return matching.first;
}

List<Map<String, Object?>> _readArtifactInventory(
  List<Map<String, Object?>> artifacts, {
  required int runId,
}) {
  for (final artifact in artifacts) {
    final workflowRun = artifact['workflow_run'];
    if (artifact['name'] is! String ||
        (artifact['name'] as String).isEmpty ||
        artifact['size_in_bytes'] is! int ||
        (artifact['size_in_bytes'] as int) < 0 ||
        artifact['expired'] is! bool ||
        workflowRun is! Map ||
        workflowRun.keys.any((key) => key is! String) ||
        workflowRun['id'] != runId ||
        workflowRun['head_sha'] is! String ||
        !_shaPattern.hasMatch(workflowRun['head_sha'] as String)) {
      throw const ReleasePreflightException(
        'The Actions artifact inventory is invalid or incomplete.',
      );
    }
  }
  return artifacts;
}

List<Map<String, Object?>> _mapJobs(List<Object?> pages) {
  final jobs = _flattenPaginatedList(pages, 'jobs', 'build job list');
  return jobs.map((job) {
    if (job['name'] is! String ||
        job['status'] is! String ||
        job['conclusion'] is! String) {
      throw const ReleasePreflightException(
        'The build job list contains an invalid record.',
      );
    }
    return <String, Object?>{
      'name': job['name'],
      'status': job['status'],
      'conclusion': job['conclusion'],
    };
  }).toList();
}

List<Map<String, Object?>> _mapWorkflowRuns(
  List<Object?> pages,
  String tag, {
  required int currentRunId,
  required int currentRunNumber,
}) {
  final runs = _flattenPaginatedList(
    pages,
    'workflow_runs',
    'release run list',
  );
  final expectedTitle = 'release-$tag';
  final runNumbers = <int>{};
  final currentRuns = <Map<String, Object?>>[];
  for (final run in runs) {
    if (run['id'] is! int ||
        (run['id'] as int) <= 0 ||
        run['display_title'] is! String ||
        run['path'] != _releaseWorkflowPath ||
        run['event'] != 'workflow_dispatch' ||
        run['head_branch'] != 'main' ||
        run['head_sha'] is! String ||
        !_shaPattern.hasMatch(run['head_sha'] as String) ||
        run['run_attempt'] is! int ||
        (run['run_attempt'] as int) <= 0 ||
        run['workflow_id'] is! int ||
        (run['workflow_id'] as int) <= 0 ||
        run['run_number'] is! int ||
        (run['run_number'] as int) <= 0) {
      throw const ReleasePreflightException(
        'A prior release workflow has invalid provenance.',
      );
    }
    final runNumber = run['run_number'] as int;
    if (!runNumbers.add(runNumber)) {
      throw const ReleasePreflightException(
        'Release workflow run numbers are ambiguous.',
      );
    }
    if (run['id'] == currentRunId) currentRuns.add(run);
  }
  if (currentRuns.length != 1 ||
      currentRuns.single['run_number'] != currentRunNumber ||
      currentRuns.single['display_title'] != expectedTitle) {
    throw const ReleasePreflightException(
      'Current release run is inconsistent with the complete run list.',
    );
  }
  return runs
      .where(
        (run) =>
            run['display_title'] == expectedTitle &&
            (run['run_number'] as int) <= currentRunNumber,
      )
      .map((run) {
        return <String, Object?>{
          'id': run['id'],
          'run_number': run['run_number'],
          'head_sha': run['head_sha'],
          'run_attempt': run['run_attempt'],
          'workflow_id': run['workflow_id'],
          'path': run['path'],
          'event': run['event'],
          'head_branch': run['head_branch'],
        };
      })
      .toList();
}

bool _hasCompletedBundleJob(List<Map<String, Object?>> jobs, int attempt) {
  final matching = jobs.where((job) => job['name'] == 'bundle').toList();
  return matching.length == 1 &&
      matching.single['conclusion'] == 'success' &&
      matching.single['status'] == 'completed' &&
      matching.single['run_attempt'] == attempt;
}

String _bundleArtifactName(String tag, int runId, int attempt) =>
    'flashco-release-bundle-$tag-run-$runId-attempt-$attempt';

Future<void> main(List<String> arguments) async {
  final result = await ReleaseCli(
    environment: Platform.environment,
  ).run(arguments);
  if (result.error != null) {
    stderr.writeln(result.error);
  } else {
    stdout.writeln('Release preflight passed.');
  }
  if (result.exitCode == 0 && Platform.environment['GITHUB_OUTPUT'] == null) {
    for (final entry in result.output.entries) {
      stdout.writeln('${entry.key}=${entry.value}');
    }
  }
  exitCode = result.exitCode;
}
