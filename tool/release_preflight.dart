import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

const _requiredPackageName = 'com.follow.flashco';
const _requiredAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};
final _stableVersionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

List<String> validateReleaseIdentity({
  required String tag,
  required String version,
  required int buildNumber,
}) {
  final errors = <String>[];
  if (!_isStableVersion(version)) {
    errors.add('Version must be a stable X.Y.Z value.');
  }
  if (tag != 'v$version') {
    errors.add('Tag must match the stable version.');
  }
  if (buildNumber <= 0) {
    errors.add('Build number must be positive.');
  }
  return errors;
}

List<String> validatePublishedUpgrade({
  required String version,
  required int buildNumber,
  required String? publishedVersion,
  required int? publishedBuildNumber,
}) {
  final errors = <String>[];
  if (!_isStableVersion(version)) {
    errors.add('Version must be a stable X.Y.Z value.');
  }
  if (buildNumber <= 0) {
    errors.add('Build number must be positive.');
  }

  if (publishedVersion == null && publishedBuildNumber == null) {
    return errors;
  }
  if (publishedVersion == null || publishedBuildNumber == null) {
    errors.add('Published release history is incomplete.');
    return errors;
  }

  final currentParts = _parseStableVersion(version);
  final publishedParts = _parseStableVersion(publishedVersion);
  if (publishedParts == null || publishedBuildNumber <= 0) {
    errors.add('Published release history is invalid.');
    return errors;
  }
  if (currentParts != null &&
      _compareVersions(currentParts, publishedParts) <= 0) {
    errors.add('Version must be newer than published stable releases.');
  }
  if (buildNumber <= publishedBuildNumber) {
    errors.add('Build number must be greater than published stable releases.');
  }
  return errors;
}

List<String> validatePublicBuildDefines(Map<String, Object?> defines) {
  final errors = <String>[];
  if (defines['APP_ENV'] != 'stable') {
    errors.add('Public build environment must be stable.');
  }

  final subscription = defines['BOOTSTRAP_SUBSCRIPTION_URL'];
  if (subscription != null && subscription is! String) {
    errors.add('Public build subscription define must be a string.');
  } else if (subscription is String && subscription.trim().isNotEmpty) {
    errors.add('Public build must not include a bootstrap subscription.');
  }

  final safeMode = defines['SAFE_MODE'];
  if (safeMode == true ||
      (safeMode is String && safeMode.toLowerCase() == 'true')) {
    errors.add('Public build safe mode must be disabled.');
  } else if (safeMode != null && safeMode != false && safeMode is! String) {
    errors.add('Public build safe mode define must be a boolean or string.');
  } else if (safeMode is String &&
      safeMode.toLowerCase() != 'true' &&
      safeMode.toLowerCase() != 'false') {
    errors.add('Public build safe mode define is invalid.');
  }
  return errors;
}

List<String> validateAndroidIdentity({
  required Map<String, Object?> metadata,
  required String expectedSignerSha256,
  required String version,
  required int buildNumber,
}) {
  final errors = <String>[];
  const requiredTypes = <String, Type>{
    'packageName': String,
    'versionName': String,
    'versionCode': int,
    'signerSha256': String,
    'abis': List<String>,
    'debuggable': bool,
    'testOnly': bool,
  };
  for (final entry in requiredTypes.entries) {
    final value = metadata[entry.key];
    final validType = switch (entry.key) {
      'packageName' || 'versionName' || 'signerSha256' => value is String,
      'versionCode' => value is int,
      'abis' => value is List && value.every((abi) => abi is String),
      'debuggable' || 'testOnly' => value is bool,
      _ => false,
    };
    if (!metadata.containsKey(entry.key) || !validType) {
      errors.add('Android metadata field ${entry.key} is missing or invalid.');
    }
  }

  final packageName = metadata['packageName'];
  if (packageName is String && packageName != _requiredPackageName) {
    errors.add('Android package identity is not the public package.');
  }
  final versionName = metadata['versionName'];
  if (versionName is String && versionName != version) {
    errors.add('Android version name does not match the release.');
  }
  final versionCode = metadata['versionCode'];
  if (versionCode is int && versionCode != buildNumber) {
    errors.add('Android version code does not match the release.');
  }

  final signer = metadata['signerSha256'];
  final expectedSigner = _normalizeFingerprint(expectedSignerSha256);
  final actualSigner = signer is String ? _normalizeFingerprint(signer) : null;
  if (expectedSigner == null || actualSigner == null) {
    errors.add('Android signer fingerprint must be a SHA-256 value.');
  } else if (actualSigner != expectedSigner) {
    errors.add('Android signer does not match the approved certificate.');
  }

  final abis = metadata['abis'];
  if (abis is List && abis.every((abi) => abi is String)) {
    final abiValues = abis.cast<String>();
    if (abiValues.toSet().length != abiValues.length ||
        abiValues.toSet().difference(_requiredAbis).isNotEmpty ||
        _requiredAbis.difference(abiValues.toSet()).isNotEmpty) {
      errors.add('Android APK must contain exactly the required ABI set.');
    }
  }

  if (metadata['debuggable'] == true) {
    errors.add('Android APK must not be debuggable.');
  }
  if (metadata['testOnly'] == true) {
    errors.add('Android APK must not be test-only.');
  }
  return errors;
}

int runReleasePreflight(
  List<String> arguments, {
  void Function(String line)? writeOutput,
  void Function(String line)? writeError,
}) {
  final outputLine = writeOutput ?? stdout.writeln;
  final errorLine = writeError ?? stderr.writeln;
  final parser = ArgParser()..addOption('input', mandatory: true);

  final String inputPath;
  try {
    inputPath = parser.parse(arguments)['input'] as String;
  } on FormatException {
    errorLine('Usage: release_preflight.dart --input <json-file>');
    return 2;
  }

  final Map<String, Object?> input;
  try {
    final decoded = jsonDecode(File(inputPath).readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException();
    }
    input = Map<String, Object?>.from(decoded);
  } on Object {
    errorLine('Release preflight input is unreadable or invalid JSON.');
    return 2;
  }

  final errors = _validatePreflightInput(input);
  if (errors.isNotEmpty) {
    errorLine('Release preflight failed:');
    for (final error in errors) {
      errorLine('- $error');
    }
    return 1;
  }
  outputLine('Release preflight passed.');
  return 0;
}

void main(List<String> arguments) {
  exitCode = runReleasePreflight(arguments);
}

List<String> _validatePreflightInput(Map<String, Object?> input) {
  final errors = <String>[];
  final tag = input['tag'];
  final version = input['version'];
  final buildNumber = input['buildNumber'];
  final defines = input['defines'];
  final history = input['publishedHistory'];
  final expectedSigner = input['expectedSignerSha256'];
  final androidMetadata = input['androidMetadata'];

  if (tag is! String || version is! String || buildNumber is! int) {
    errors.add('Release identity fields are missing or invalid.');
  } else {
    errors.addAll(
      validateReleaseIdentity(
        tag: tag,
        version: version,
        buildNumber: buildNumber,
      ),
    );
  }
  if (defines is! Map || defines.keys.any((key) => key is! String)) {
    errors.add('Build defines are missing or invalid.');
  } else {
    errors.addAll(
      validatePublicBuildDefines(Map<String, Object?>.from(defines)),
    );
  }

  if (history is! Map || history.keys.any((key) => key is! String)) {
    errors.add('Published release history is missing or invalid.');
  } else if (history['complete'] != true) {
    errors.add('Published release history must be complete.');
  } else {
    // Orchestration sets complete only after a successful read of all stable releases.
    final publishedVersion = history['highestVersion'];
    final publishedBuildNumber = history['highestBuildNumber'];
    if ((publishedVersion != null && publishedVersion is! String) ||
        (publishedBuildNumber != null && publishedBuildNumber is! int)) {
      errors.add('Published release history is incomplete.');
    } else if (version is String && buildNumber is int) {
      errors.addAll(
        validatePublishedUpgrade(
          version: version,
          buildNumber: buildNumber,
          publishedVersion: publishedVersion as String?,
          publishedBuildNumber: publishedBuildNumber as int?,
        ),
      );
    }
  }

  if (expectedSigner is! String) {
    errors.add('Expected Android signer fingerprint is missing or invalid.');
  }
  if (androidMetadata is! Map ||
      androidMetadata.keys.any((key) => key is! String)) {
    errors.add('Android metadata is missing or invalid.');
  } else if (version is String &&
      buildNumber is int &&
      expectedSigner is String) {
    errors.addAll(
      validateAndroidIdentity(
        metadata: Map<String, Object?>.from(androidMetadata),
        expectedSignerSha256: expectedSigner,
        version: version,
        buildNumber: buildNumber,
      ),
    );
  }
  return errors;
}

bool _isStableVersion(String version) => _parseStableVersion(version) != null;

List<int>? _parseStableVersion(String version) {
  final match = _stableVersionPattern.firstMatch(version);
  if (match == null) {
    return null;
  }
  final parts = <int>[];
  for (final group in [match[1], match[2], match[3]]) {
    final part = int.tryParse(group!);
    if (part == null) {
      return null;
    }
    parts.add(part);
  }
  return parts;
}

int _compareVersions(List<int> left, List<int> right) {
  for (var index = 0; index < left.length; index++) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

String? _normalizeFingerprint(String fingerprint) {
  final normalized = fingerprint
      .replaceAll(':', '')
      .replaceAll(' ', '')
      .toLowerCase();
  return _sha256Pattern.hasMatch(normalized) ? normalized : null;
}
