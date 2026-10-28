import 'dart:collection';
import 'dart:convert';

import 'release_preflight.dart';

const requiredBuildChecks = <String>{
  'Dart',
  'Plugins',
  'Desktop linux',
  'Desktop windows',
  'Desktop macos',
  'Go core',
  'Android unit tests',
  'Rust',
  'Windows helper test',
};

final _fullShaPattern = RegExp(r'^[0-9a-fA-F]{40}$');
final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
final _tagPattern = RegExp(
  r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);

List<String> validateReleaseSource({
  required String workflowRef,
  required String tag,
  required String tagSha,
  required String sourceSha,
  required bool sourceReachableFromMain,
  required String version,
  required int buildNumber,
}) {
  final errors = <String>[];
  if (workflowRef != 'refs/heads/main') {
    errors.add('Release workflow must be dispatched from main.');
  }
  if (!_tagPattern.hasMatch(tag)) {
    errors.add('Release tag must be a stable vX.Y.Z tag.');
  }
  if (!_fullShaPattern.hasMatch(tagSha) ||
      !_fullShaPattern.hasMatch(sourceSha)) {
    errors.add('Release source must resolve to a full commit SHA.');
  } else if (tagSha.toLowerCase() != sourceSha.toLowerCase()) {
    errors.add('Release tag moved after source resolution.');
  }
  if (!sourceReachableFromMain) {
    errors.add('Release source commit is not reachable from main.');
  }
  if (tag != 'v$version') {
    errors.add('Release tag does not match the source version.');
  }
  errors.addAll(
    validateReleaseIdentity(
      tag: tag,
      version: version,
      buildNumber: buildNumber,
    ),
  );
  return errors.toSet().toList(growable: false);
}

List<String> validateLatestBuildCi({
  required bool completeRunList,
  required String sourceSha,
  required List<Map<String, Object?>> runs,
  required Map<String, Object?> latestRun,
}) {
  final errors = <String>[];
  if (!completeRunList) {
    errors.add('Build workflow run history is incomplete.');
  }
  if (!_fullShaPattern.hasMatch(sourceSha)) {
    errors.add('Build checks require a full source commit SHA.');
    return errors;
  }

  final matchingRuns = <Map<String, Object?>>[];
  for (final run in runs) {
    final headSha = run['headSha'];
    if (headSha is! String || !_fullShaPattern.hasMatch(headSha)) {
      errors.add('Build run history contains an invalid head SHA.');
      continue;
    }
    if (run['workflowName'] != 'build') {
      errors.add('Build run list contains a different workflow.');
    }
    if (headSha == sourceSha) {
      if (run['databaseId'] is! int ||
          run['createdAt'] is! String ||
          DateTime.tryParse(run['createdAt'] as String) == null) {
        errors.add('Build run history is missing ordering metadata.');
      }
      matchingRuns.add(run);
    }
  }
  if (matchingRuns.isEmpty) {
    errors.add('No build workflow run exists for the release source.');
    return errors;
  }

  matchingRuns.sort(_compareRunsNewestFirst);
  final selectedRun = matchingRuns.first;
  final selectedRunId = selectedRun['databaseId'];
  if (selectedRunId is! int || latestRun['databaseId'] != selectedRunId) {
    errors.add('Build job details are not from the latest run for this SHA.');
  }
  if (selectedRun['status'] != 'completed' ||
      selectedRun['conclusion'] != 'success') {
    errors.add('Latest build workflow run for this SHA did not succeed.');
  }
  if (latestRun['headSha'] != sourceSha ||
      latestRun['workflowName'] != 'build' ||
      latestRun['status'] != 'completed' ||
      latestRun['conclusion'] != 'success') {
    errors.add('Latest build workflow run details do not confirm success.');
  }

  final jobsValue = latestRun['jobs'];
  if (jobsValue is! List) {
    errors.add('Latest build workflow run has no job list.');
    return errors;
  }
  final jobsByName = <String, List<Map<String, Object?>>>{};
  for (final value in jobsValue) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      errors.add('Latest build workflow run has an invalid job record.');
      continue;
    }
    final job = Map<String, Object?>.from(value);
    final name = job['name'];
    if (name is! String) {
      errors.add('Latest build workflow run has an unnamed job.');
      continue;
    }
    jobsByName.putIfAbsent(name, () => []).add(job);
  }
  for (final requiredCheck in requiredBuildChecks) {
    final matchingJobs = jobsByName[requiredCheck];
    if (matchingJobs == null || matchingJobs.length != 1) {
      errors.add('Required build check is missing or duplicated.');
    } else if (matchingJobs.single['status'] != 'completed' ||
        matchingJobs.single['conclusion'] != 'success') {
      errors.add('A required build check did not succeed.');
    }
  }
  return errors.toSet().toList(growable: false);
}

PublishedHistorySummary summarizePublishedHistory({
  required bool complete,
  required List<Object?> releases,
  Map<String, Map<String, Object?>> manifestsByTag = const {},
}) {
  final errors = <String>[];
  if (!complete) {
    errors.add('Published release history is incomplete.');
    return PublishedHistorySummary(errors: errors);
  }

  String? highestVersion;
  int? highestBuildNumber;
  for (final value in releases) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      errors.add('Published release record is invalid.');
      continue;
    }
    final release = Map<String, Object?>.from(value);
    if (release['draft'] == true || release['prerelease'] == true) {
      continue;
    }
    final tag = release['tag_name'];
    if (tag is! String) {
      errors.add('Published stable release has no tag.');
      continue;
    }
    final version = _versionFromTag(tag);
    if (version == null) {
      errors.add('Published release has an invalid stable tag.');
      continue;
    }
    final releaseAssets = release['assets'];
    if (releaseAssets is! List ||
        releaseAssets
                .where(
                  (asset) =>
                      asset is Map && asset['name'] == 'release-manifest.json',
                )
                .length !=
            1) {
      errors.add('Published stable release manifest asset is missing.');
      continue;
    }
    final manifest = manifestsByTag[tag];
    if (manifest == null) {
      errors.add('Published stable release manifest is missing.');
      continue;
    }
    final manifestErrors = _validatePublishedManifest(
      manifest,
      tag: tag,
      version: version,
    );
    if (manifestErrors.isNotEmpty) {
      errors.addAll(manifestErrors);
      continue;
    }
    final buildNumber = manifest['buildNumber'] as int;
    if (highestVersion == null ||
        _compareVersions(version, highestVersion) > 0) {
      highestVersion = version;
    }
    if (highestBuildNumber == null || buildNumber > highestBuildNumber) {
      highestBuildNumber = buildNumber;
    }
  }
  return PublishedHistorySummary(
    highestVersion: errors.isEmpty ? highestVersion : null,
    highestBuildNumber: errors.isEmpty ? highestBuildNumber : null,
    errors: errors.toSet().toList(growable: false),
  );
}

List<String> _validatePublishedManifest(
  Map<String, Object?> manifest, {
  required String tag,
  required String version,
}) {
  final errors = <String>[];
  if (manifest['schemaVersion'] != 1 ||
      manifest['tag'] != tag ||
      manifest['version'] != version ||
      manifest['commit'] is! String ||
      !_fullShaPattern.hasMatch(manifest['commit'] as String) ||
      manifest['workflowRunId'] is! int ||
      (manifest['workflowRunId'] as int) <= 0 ||
      manifest['buildNumber'] is! int ||
      (manifest['buildNumber'] as int) <= 0) {
    errors.add('Published stable release manifest is invalid.');
  }
  final android = manifest['android'];
  if (android is! Map ||
      android['packageName'] != 'com.follow.flashco' ||
      android['signerSha256'] is! String ||
      !_hashPattern.hasMatch(android['signerSha256'] as String) ||
      android['abis'] is! List ||
      (android['abis'] as List).length != 3 ||
      (android['abis'] as List).toSet().length != 3 ||
      (android['abis'] as List).toSet().difference({
        'armeabi-v7a',
        'arm64-v8a',
        'x86_64',
      }).isNotEmpty) {
    errors.add('Published stable release Android manifest is invalid.');
  }
  final assets = manifest['assets'];
  final expectedAssetNames = <String>{
    'Flashco-$version-android.apk',
    'Flashco-$version-windows-amd64-setup.exe',
    'Flashco-$version-windows-amd64.zip',
  };
  final assetNames = <String>{};
  if (assets is! List || assets.length != expectedAssetNames.length) {
    errors.add('Published stable release asset manifest is invalid.');
  } else {
    for (final asset in assets) {
      if (asset is! Map ||
          asset['name'] is! String ||
          asset['size'] is! int ||
          (asset['size'] as int) <= 0 ||
          asset['sha256'] is! String ||
          !_hashPattern.hasMatch(asset['sha256'] as String)) {
        errors.add('Published stable release asset manifest is invalid.');
        continue;
      }
      assetNames.add(asset['name'] as String);
    }
    if (assetNames.length != assets.length ||
        assetNames.difference(expectedAssetNames).isNotEmpty ||
        expectedAssetNames.difference(assetNames).isNotEmpty) {
      errors.add('Published stable release asset manifest is invalid.');
    }
  }
  return errors;
}

String? _versionFromTag(String tag) {
  final match = _tagPattern.firstMatch(tag);
  if (match == null) {
    return null;
  }
  if ([
    match[1],
    match[2],
    match[3],
  ].any((part) => int.tryParse(part!) == null)) {
    return null;
  }
  return tag.substring(1);
}

int _compareVersions(String left, String right) {
  final leftParts = left.split('.').map(int.parse).toList(growable: false);
  final rightParts = right.split('.').map(int.parse).toList(growable: false);
  for (var index = 0; index < leftParts.length; index++) {
    final result = leftParts[index].compareTo(rightParts[index]);
    if (result != 0) {
      return result;
    }
  }
  return 0;
}

int _compareRunsNewestFirst(
  Map<String, Object?> left,
  Map<String, Object?> right,
) {
  final leftValue = left['createdAt'];
  final rightValue = right['createdAt'];
  final leftCreatedAt = leftValue is String
      ? DateTime.tryParse(leftValue)
      : null;
  final rightCreatedAt = rightValue is String
      ? DateTime.tryParse(rightValue)
      : null;
  if (leftCreatedAt == null || rightCreatedAt == null) {
    return _runId(right).compareTo(_runId(left));
  }
  final byDate = rightCreatedAt.compareTo(leftCreatedAt);
  return byDate != 0 ? byDate : _runId(right).compareTo(_runId(left));
}

int _runId(Map<String, Object?> run) =>
    run['databaseId'] is int ? run['databaseId'] as int : 0;

class PublishedHistorySummary {
  PublishedHistorySummary({
    this.highestVersion,
    this.highestBuildNumber,
    required List<String> errors,
  }) : errors = List.unmodifiable(errors);

  final String? highestVersion;
  final int? highestBuildNumber;
  final List<String> errors;
}

class WorkflowArtifactInventory {
  const WorkflowArtifactInventory({
    required this.totalCount,
    required this.artifacts,
  });

  final int totalCount;
  final List<Map<String, Object?>> artifacts;
}

WorkflowArtifactInventory readWorkflowArtifactInventory(
  Map<String, Object?> response,
) {
  final totalCount = response['total_count'];
  final artifactsValue = response['artifacts'];
  if (totalCount is! int || artifactsValue is! List) {
    throw const FormatException('Actions artifact response is invalid.');
  }
  final artifacts = <Map<String, Object?>>[];
  final artifactIds = <int>{};
  for (final value in artifactsValue) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Actions artifact record is invalid.');
    }
    final artifact = Map<String, Object?>.from(value);
    if (artifact['id'] is! int ||
        artifact['name'] is! String ||
        artifact['size_in_bytes'] is! int ||
        (artifact['size_in_bytes'] as int) < 0 ||
        artifact['expired'] is! bool ||
        !_isWorkflowRunIdentity(artifact['workflow_run'])) {
      throw const FormatException('Actions artifact record is invalid.');
    }
    if (!artifactIds.add(artifact['id'] as int)) {
      throw const FormatException(
        'Actions artifact response has duplicate IDs.',
      );
    }
    artifacts.add(artifact);
  }
  if (totalCount < 0 || artifacts.length != totalCount) {
    throw const FormatException('Actions artifact response is incomplete.');
  }
  return WorkflowArtifactInventory(
    totalCount: totalCount,
    artifacts: List.unmodifiable(artifacts),
  );
}

bool _isWorkflowRunIdentity(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    return false;
  }
  return value['id'] is int &&
      value['head_sha'] is String &&
      _fullShaPattern.hasMatch(value['head_sha'] as String);
}

enum BundleRecoveryAction { build, reuse, stop }

class BundleRecoveryDecision {
  const BundleRecoveryDecision({
    required this.action,
    this.workflowRunId,
    required this.reason,
  });

  final BundleRecoveryAction action;
  final int? workflowRunId;
  final String reason;
}

class ReleaseBundleCandidate {
  const ReleaseBundleCandidate({
    required this.artifactRunId,
    required this.expired,
    required this.manifest,
    required this.observedAssetHashes,
    required this.manifestSha256,
    required this.sha256Sums,
  });

  final int artifactRunId;
  final bool expired;
  final Map<String, Object?> manifest;
  final Map<String, String> observedAssetHashes;
  final String manifestSha256;
  final String sha256Sums;
}

BundleRecoveryDecision decidePriorBundleRecovery({
  required String tag,
  required String sourceSha,
  required bool priorAttemptExists,
  required List<ReleaseBundleCandidate> candidates,
}) {
  if (!priorAttemptExists && candidates.isEmpty) {
    return const BundleRecoveryDecision(
      action: BundleRecoveryAction.build,
      reason: 'No earlier attempt or saved bundle exists.',
    );
  }
  if (!priorAttemptExists || candidates.length != 1) {
    return const BundleRecoveryDecision(
      action: BundleRecoveryAction.stop,
      reason: 'Prior bundle state is missing or ambiguous.',
    );
  }

  final candidate = candidates.single;
  final errors = _validateBundleCandidate(
    candidate,
    tag: tag,
    sourceSha: sourceSha,
  );
  if (errors.isNotEmpty) {
    return const BundleRecoveryDecision(
      action: BundleRecoveryAction.stop,
      reason: 'Saved bundle failed identity or integrity checks.',
    );
  }
  return BundleRecoveryDecision(
    action: BundleRecoveryAction.reuse,
    workflowRunId: candidate.artifactRunId,
    reason: 'The original complete bundle matches this tag and source SHA.',
  );
}

List<String> _validateBundleCandidate(
  ReleaseBundleCandidate candidate, {
  required String tag,
  required String sourceSha,
}) {
  final errors = <String>[];
  if (candidate.artifactRunId <= 0 ||
      candidate.expired ||
      !_fullShaPattern.hasMatch(sourceSha)) {
    errors.add('Saved Actions artifact is unavailable.');
  }
  final manifest = candidate.manifest;
  final version = _versionFromTag(tag);
  if (version == null ||
      manifest['schemaVersion'] != 1 ||
      manifest['tag'] != tag ||
      manifest['commit'] != sourceSha ||
      manifest['version'] != version ||
      manifest['workflowRunId'] != candidate.artifactRunId ||
      manifest['buildNumber'] is! int ||
      (manifest['buildNumber'] as int) <= 0) {
    errors.add('Saved release manifest does not match this attempt.');
  }

  final android = manifest['android'];
  if (android is! Map ||
      android['packageName'] != 'com.follow.flashco' ||
      android['signerSha256'] is! String ||
      !_hashPattern.hasMatch(android['signerSha256'] as String) ||
      android['abis'] is! List ||
      (android['abis'] as List).length != 3 ||
      (android['abis'] as List).toSet().difference({
        'armeabi-v7a',
        'arm64-v8a',
        'x86_64',
      }).isNotEmpty ||
      (android['abis'] as List).toSet().length != 3) {
    errors.add('Saved release manifest has invalid Android metadata.');
  }

  final assetsValue = manifest['assets'];
  final expectedNames = <String>{
    'Flashco-$version-android.apk',
    'Flashco-$version-windows-amd64-setup.exe',
    'Flashco-$version-windows-amd64.zip',
  };
  if (assetsValue is! List || assetsValue.length != expectedNames.length) {
    errors.add('Saved release manifest has an invalid asset list.');
  } else {
    final declaredHashes = <String, String>{};
    for (final value in assetsValue) {
      if (value is! Map ||
          value['name'] is! String ||
          value['size'] is! int ||
          (value['size'] as int) <= 0 ||
          value['sha256'] is! String ||
          !_hashPattern.hasMatch(value['sha256'] as String)) {
        errors.add('Saved release manifest contains an invalid asset.');
        continue;
      }
      declaredHashes[value['name'] as String] = value['sha256'] as String;
    }
    if (declaredHashes.keys.toSet().difference(expectedNames).isNotEmpty ||
        expectedNames.difference(declaredHashes.keys.toSet()).isNotEmpty ||
        !mapEquals(declaredHashes, candidate.observedAssetHashes)) {
      errors.add('Saved release asset hashes do not match the manifest.');
    }
  }

  if (!_hashPattern.hasMatch(candidate.manifestSha256)) {
    errors.add('Saved release manifest hash is invalid.');
  }
  final checksumHashes = parseSha256Sums(candidate.sha256Sums);
  final expectedChecksumNames = {...expectedNames, 'release-manifest.json'};
  final expectedChecksumHashes = {
    ...candidate.observedAssetHashes,
    'release-manifest.json': candidate.manifestSha256,
  };
  if (checksumHashes == null ||
      checksumHashes.keys
          .toSet()
          .difference(expectedChecksumNames)
          .isNotEmpty ||
      expectedChecksumNames
          .difference(checksumHashes.keys.toSet())
          .isNotEmpty ||
      !mapEquals(checksumHashes, expectedChecksumHashes)) {
    errors.add('Saved SHA256SUMS does not match the verified bundle.');
  }
  return errors;
}

Map<String, String>? parseSha256Sums(String contents) {
  final hashes = <String, String>{};
  for (final line in const LineSplitter().convert(contents.trim())) {
    final match = RegExp(
      r'^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || hashes.containsKey(match[2])) {
      return null;
    }
    hashes[match[2]!] = match[1]!;
  }
  return hashes.isEmpty ? null : UnmodifiableMapView(hashes);
}

bool mapEquals(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) {
    return false;
  }
  return left.entries.every((entry) => right[entry.key] == entry.value);
}
