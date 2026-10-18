import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'release_preflight.dart';

final _commitPattern = RegExp(r'^[0-9a-fA-F]{40}$');
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _attributePattern = RegExp(
  r'''([A-Za-z_][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);
final _nativeLibraryPattern = RegExp(r'^/lib/([^/]+)/[^/]+\.so$');
const _requiredAndroidAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};
const _requiredWindowsRuntimeFiles = {
  'Flashco.exe',
  'FlashcoCore.exe',
  'FlashcoHelperService.exe',
  'manifest.json',
  'flutter_windows.dll',
  'EnableLoopback.exe',
  'msvcp140.dll',
  'vcruntime140.dll',
  'data/icudtl.dat',
  'data/app.so',
  'data/flutter_assets/AssetManifest.bin',
};
final _sensitivePathPartPattern = RegExp(
  r'(subscription|profile|backup|secret|credential|keystore)',
  caseSensitive: false,
);

class AndroidSdkCommandOutputs {
  const AndroidSdkCommandOutputs({
    required this.identity,
    required this.applicationXml,
    required this.certificates,
    required this.abiPaths,
  });

  final String identity;
  final String applicationXml;
  final String certificates;
  final String abiPaths;
}

class ReleaseBundle {
  const ReleaseBundle({
    required this.manifest,
    required this.manifestJson,
    required this.sha256Sums,
  });

  final Map<String, Object?> manifest;
  final String manifestJson;
  final String sha256Sums;
}

class VerifiedReleaseBundle {
  const VerifiedReleaseBundle({
    required this.manifest,
    required this.assetHashes,
    required this.assetSizes,
    required this.manifestSha256,
  });

  final Map<String, Object?> manifest;
  final Map<String, String> assetHashes;
  final Map<String, int> assetSizes;
  final String manifestSha256;
}

Map<String, Object?> parseAndroidSdkOutputs(AndroidSdkCommandOutputs outputs) {
  final identity = _parseIdentityLines(outputs.identity);
  final application = _parseApplicationElement(outputs.applicationXml);
  final signer = _parseSigner(outputs.certificates);
  final abis = _parseAbiPaths(outputs.abiPaths);

  final debuggable = _parseBoolean(identity['debuggable']!);
  final manifestDebuggable = _parseOptionalBoolean(
    application['android:debuggable'],
    defaultValue: false,
  );
  if (debuggable != manifestDebuggable) {
    throw const FormatException('Android debuggable metadata is inconsistent.');
  }
  if (signer.distinguishedName.toLowerCase().contains('cn=android debug')) {
    throw const FormatException('Android APK uses a debug certificate.');
  }

  final versionCode = int.tryParse(identity['version-code']!);
  if (versionCode == null) {
    throw const FormatException('Android version code output is invalid.');
  }
  return UnmodifiableMapView<String, Object?>({
    'packageName': identity['application-id']!,
    'versionName': identity['version-name']!,
    'versionCode': versionCode,
    'signerSha256': signer.sha256,
    'abis': abis,
    'debuggable': debuggable,
    'testOnly': _parseOptionalBoolean(
      application['android:testOnly'],
      defaultValue: false,
    ),
  });
}

Future<ReleaseBundle> buildReleaseBundle({
  required String tag,
  required String commit,
  required int workflowRunId,
  required String version,
  required int buildNumber,
  required String expectedSignerSha256,
  required AndroidSdkCommandOutputs androidOutputs,
  required Map<String, File> payloadFiles,
}) async {
  final identityErrors = validateReleaseIdentity(
    tag: tag,
    version: version,
    buildNumber: buildNumber,
  );
  if (identityErrors.isNotEmpty ||
      !_commitPattern.hasMatch(commit) ||
      workflowRunId <= 0) {
    throw const FormatException('Release identity is invalid.');
  }

  final metadata = parseAndroidSdkOutputs(androidOutputs);
  final androidErrors = validateAndroidIdentity(
    metadata: metadata,
    expectedSignerSha256: expectedSignerSha256,
    version: version,
    buildNumber: buildNumber,
  );
  if (androidErrors.isNotEmpty) {
    throw const FormatException('Android release identity is invalid.');
  }

  final expectedNames = _expectedAssetNames(version);
  if (!_sameStringSet(payloadFiles.keys.toSet(), expectedNames)) {
    throw const FormatException('Release payload allowlist is incomplete.');
  }
  final assets = <Map<String, Object?>>[];
  for (final name in expectedNames) {
    final file = payloadFiles[name]!;
    final size = await _payloadSize(file);
    final hash = await _fileSha256(file);
    assets.add({'name': name, 'size': size, 'sha256': hash});
  }

  await _verifyWindowsZip(payloadFiles[expectedNames.last]!);
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'tag': tag,
    'commit': commit,
    'workflowRunId': workflowRunId,
    'version': version,
    'buildNumber': buildNumber,
    'android': {
      'packageName': metadata['packageName'],
      'signerSha256': metadata['signerSha256'],
      'abis': metadata['abis'],
    },
    'assets': assets,
  };
  final manifestJson =
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
  final manifestSha256 = sha256.convert(utf8.encode(manifestJson)).toString();
  final checksums = <String, String>{
    for (final asset in assets)
      asset['name']! as String: asset['sha256']! as String,
    'release-manifest.json': manifestSha256,
  };
  final sha256Sums = _formatSha256Sums(checksums);

  await verifyReleaseBundle(
    tag: tag,
    commit: commit,
    workflowRunId: workflowRunId,
    expectedSignerSha256: expectedSignerSha256,
    androidOutputs: androidOutputs,
    payloadFiles: payloadFiles,
    manifestJson: manifestJson,
    sha256Sums: sha256Sums,
  );
  return ReleaseBundle(
    manifest: UnmodifiableMapView(manifest),
    manifestJson: manifestJson,
    sha256Sums: sha256Sums,
  );
}

Future<VerifiedReleaseBundle> verifyReleaseBundle({
  required String tag,
  required String commit,
  required int workflowRunId,
  required String expectedSignerSha256,
  required AndroidSdkCommandOutputs androidOutputs,
  required Map<String, File> payloadFiles,
  required String manifestJson,
  required String sha256Sums,
}) async {
  final Map<String, Object?> manifest;
  try {
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException();
    }
    manifest = Map<String, Object?>.from(decoded);
  } on Object {
    throw const FormatException('Release manifest is invalid.');
  }

  final version = _versionFromTag(tag);
  if (version == null ||
      manifest.keys.toSet().difference({
        'schemaVersion',
        'tag',
        'commit',
        'workflowRunId',
        'version',
        'buildNumber',
        'android',
        'assets',
      }).isNotEmpty ||
      manifest.length != 8 ||
      manifest['schemaVersion'] != 1 ||
      manifest['tag'] != tag ||
      manifest['commit'] != commit ||
      manifest['workflowRunId'] != workflowRunId ||
      manifest['version'] != version ||
      manifest['buildNumber'] is! int ||
      (manifest['buildNumber'] as int) <= 0 ||
      workflowRunId <= 0 ||
      !_commitPattern.hasMatch(commit)) {
    throw const FormatException('Release manifest identity is invalid.');
  }

  final buildNumber = manifest['buildNumber'] as int;
  final identityErrors = validateReleaseIdentity(
    tag: tag,
    version: version,
    buildNumber: buildNumber,
  );
  if (identityErrors.isNotEmpty) {
    throw const FormatException('Release manifest version is invalid.');
  }

  final metadata = parseAndroidSdkOutputs(androidOutputs);
  final androidErrors = validateAndroidIdentity(
    metadata: metadata,
    expectedSignerSha256: expectedSignerSha256,
    version: version,
    buildNumber: buildNumber,
  );
  final android = manifest['android'];
  if (androidErrors.isNotEmpty ||
      android is! Map ||
      android.keys.any((key) => key is! String) ||
      android.length != 3 ||
      android['packageName'] != metadata['packageName'] ||
      android['signerSha256'] != metadata['signerSha256'] ||
      !_sameStringSet(
        (android['abis'] is List)
            ? (android['abis'] as List).whereType<String>().toSet()
            : <String>{},
        _requiredAndroidAbis,
      ) ||
      android['abis'] is! List ||
      (android['abis'] as List).length != _requiredAndroidAbis.length) {
    throw const FormatException(
      'Release manifest Android identity is invalid.',
    );
  }

  final expectedNames = _expectedAssetNames(version);
  if (!_sameStringSet(payloadFiles.keys.toSet(), expectedNames)) {
    throw const FormatException('Release payload allowlist is incomplete.');
  }
  final declaredAssets = manifest['assets'];
  if (declaredAssets is! List ||
      declaredAssets.length != expectedNames.length) {
    throw const FormatException('Release manifest asset list is invalid.');
  }
  final declaredByName = <String, Map<String, Object?>>{};
  for (final value in declaredAssets) {
    if (value is! Map ||
        value.keys.any((key) => key is! String) ||
        value.length != 3 ||
        value['name'] is! String ||
        value['size'] is! int ||
        (value['size'] as int) <= 0 ||
        value['sha256'] is! String ||
        !_digestPattern.hasMatch(value['sha256'] as String)) {
      throw const FormatException('Release manifest asset is invalid.');
    }
    final name = value['name'] as String;
    if (!expectedNames.contains(name) || declaredByName.containsKey(name)) {
      throw const FormatException('Release manifest asset list is invalid.');
    }
    declaredByName[name] = Map<String, Object?>.from(value);
  }
  if (!_sameStringSet(declaredByName.keys.toSet(), expectedNames)) {
    throw const FormatException('Release manifest asset list is incomplete.');
  }

  final actualHashes = <String, String>{};
  final actualSizes = <String, int>{};
  for (final name in expectedNames) {
    final file = payloadFiles[name]!;
    final size = await _payloadSize(file);
    final hash = await _fileSha256(file);
    final declared = declaredByName[name]!;
    if (declared['size'] != size || declared['sha256'] != hash) {
      throw const FormatException('Release payload size or hash is invalid.');
    }
    actualSizes[name] = size;
    actualHashes[name] = hash;
  }
  await _verifyWindowsZip(payloadFiles[expectedNames.last]!);

  final manifestHash = sha256.convert(utf8.encode(manifestJson)).toString();
  final expectedChecksums = <String, String>{
    ...actualHashes,
    'release-manifest.json': manifestHash,
  };
  if (!_sameStringMap(_parseSha256Sums(sha256Sums), expectedChecksums)) {
    throw const FormatException('Release checksum manifest is invalid.');
  }
  return VerifiedReleaseBundle(
    manifest: UnmodifiableMapView(manifest),
    assetHashes: UnmodifiableMapView(actualHashes),
    assetSizes: UnmodifiableMapView(actualSizes),
    manifestSha256: manifestHash,
  );
}

Map<String, String> _parseIdentityLines(String output) {
  const expectedKeys = {
    'application-id',
    'version-name',
    'version-code',
    'debuggable',
  };
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(output.trim())) {
    final separator = line.indexOf(': ');
    if (separator <= 0) {
      throw const FormatException('Android identity output is malformed.');
    }
    final key = line.substring(0, separator);
    final value = line.substring(separator + 2).trim();
    if (!expectedKeys.contains(key) ||
        value.isEmpty ||
        values.containsKey(key)) {
      throw const FormatException('Android identity output is malformed.');
    }
    values[key] = value;
  }
  if (!_sameStringSet(values.keys.toSet(), expectedKeys)) {
    throw const FormatException('Android identity output is incomplete.');
  }
  _parseBoolean(values['debuggable']!);
  return values;
}

Map<String, String> _parseApplicationElement(String xml) {
  final applications = RegExp(
    r'<application\b([^>]*)>',
    dotAll: true,
  ).allMatches(xml).toList();
  final closingTags = RegExp(r'</application\s*>').allMatches(xml).toList();
  if (applications.length != 1 || closingTags.length != 1) {
    throw const FormatException('Android application manifest is malformed.');
  }
  final opening = applications.single;
  if (closingTags.single.start < opening.end) {
    throw const FormatException('Android application manifest is malformed.');
  }
  final attributesText = opening.group(1)!;
  final attributes = <String, String>{};
  var offset = 0;
  for (final match in _attributePattern.allMatches(attributesText)) {
    if (attributesText.substring(offset, match.start).trim().isNotEmpty) {
      throw const FormatException('Android application manifest is malformed.');
    }
    final key = match.group(1)!;
    final value = match.group(2) ?? match.group(3)!;
    if (attributes.containsKey(key)) {
      throw const FormatException('Android application manifest is malformed.');
    }
    attributes[key] = value;
    offset = match.end;
  }
  if (attributesText.substring(offset).trim().isNotEmpty) {
    throw const FormatException('Android application manifest is malformed.');
  }
  return attributes;
}

({String distinguishedName, String sha256}) _parseSigner(String output) {
  final distinguishedNames = <String>[];
  final digests = <String>[];
  for (final line in const LineSplitter().convert(output.trim())) {
    final dnIndex = line.indexOf('certificate DN:');
    if (dnIndex >= 0) {
      distinguishedNames.add(line.substring(dnIndex + 15).trim());
    }
    final digestIndex = line.indexOf('certificate SHA-256 digest:');
    if (digestIndex >= 0) {
      digests.add(line.substring(digestIndex + 27).trim().toLowerCase());
    }
  }
  if (distinguishedNames.length != 1 ||
      distinguishedNames.single.isEmpty ||
      digests.length != 1 ||
      !_digestPattern.hasMatch(digests.single)) {
    throw const FormatException(
      'Android signing certificate output is invalid.',
    );
  }
  return (distinguishedName: distinguishedNames.single, sha256: digests.single);
}

List<String> _parseAbiPaths(String output) {
  final abis = <String>{};
  for (final line in const LineSplitter().convert(output.trim())) {
    final match = _nativeLibraryPattern.firstMatch(line.trim());
    if (match == null) {
      throw const FormatException('Android native-library list is malformed.');
    }
    abis.add(match[1]!);
  }
  final sorted = abis.toList()..sort();
  if (!_sameStringSet(abis, _requiredAndroidAbis)) {
    throw const FormatException(
      'Android APK ABI set is incomplete or invalid.',
    );
  }
  return sorted;
}

bool _parseBoolean(String value) {
  if (value == 'true') return true;
  if (value == 'false') return false;
  throw const FormatException('Android boolean metadata is invalid.');
}

bool _parseOptionalBoolean(String? value, {required bool defaultValue}) =>
    value == null ? defaultValue : _parseBoolean(value);

Set<String> _expectedAssetNames(String version) => {
  'Flashco-$version-android.apk',
  'Flashco-$version-windows-amd64-setup.exe',
  'Flashco-$version-windows-amd64.zip',
};

bool _sameStringSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameStringMap(Map<String, String>? left, Map<String, String> right) =>
    left != null &&
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

Future<int> _payloadSize(File file) async {
  if (!await file.exists()) {
    throw const FormatException('Release payload is missing.');
  }
  final size = await file.length();
  if (size <= 0) {
    throw const FormatException('Release payload is empty.');
  }
  return size;
}

Future<String> _fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

String _formatSha256Sums(Map<String, String> hashes) {
  final names = hashes.keys.toList()..sort();
  return '${names.map((name) => '${hashes[name]}  $name').join('\n')}\n';
}

Map<String, String>? _parseSha256Sums(String contents) {
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
  return hashes.isEmpty ? null : hashes;
}

bool _isSensitiveZipPath(String name) {
  final normalized = name.replaceAll('\\', '/');
  final isDirectory = normalized.endsWith('/');
  final path = isDirectory
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  if (path.isEmpty || normalized.startsWith('/')) {
    return true;
  }
  final parts = path.split('/');
  for (final part in parts) {
    final lower = part.toLowerCase();
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part) ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part) ||
        _sensitivePathPartPattern.hasMatch(part) ||
        lower == 'local.properties' ||
        lower == 'env.json' ||
        lower.startsWith('.env') ||
        const {
          '.jks',
          '.keystore',
          '.p12',
          '.pfx',
          '.key',
          '.pem',
        }.any(lower.endsWith)) {
      return true;
    }
  }
  return false;
}

Future<void> _verifyWindowsZip(File file) async {
  final InputFileStream input;
  try {
    input = InputFileStream(file.path);
  } on Object {
    throw const FormatException('Windows portable archive cannot be read.');
  }
  final decoder = ZipDecoder();
  try {
    final archive = decoder.decodeStream(input);
    await _verifyDecodedWindowsZip(archive, decoder.directory.fileHeaders);
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Windows portable archive is invalid.');
  } finally {
    input.closeSync();
  }
}

Future<void> _verifyDecodedWindowsZip(
  Archive archive,
  List<ZipFileHeader> headers,
) async {
  try {
    final filesByPath = <String, ZipFileHeader>{};
    final foldedPaths = <String>{};
    for (final header in headers) {
      final name = header.filename.replaceAll('\\', '/');
      final entry = archive.find(header.filename);
      final file = header.file;
      if (entry == null || file == null || file.filename != header.filename) {
        throw const FormatException(
          'Windows portable archive has inconsistent filenames.',
        );
      }
      if (_isSensitiveZipPath(name) || entry.isSymbolicLink) {
        throw const FormatException(
          'Windows portable archive contains a prohibited entry.',
        );
      }
      final directoryName = name.endsWith('/');
      final canonicalName = directoryName
          ? name.substring(0, name.length - 1)
          : name;
      final foldedName = canonicalName.toLowerCase();
      if (!foldedPaths.add(foldedName)) {
        throw const FormatException(
          'Windows portable archive has duplicate entries.',
        );
      }
      final bytes = file.getStream().toUint8List();
      if (bytes.length != header.uncompressedSize ||
          getCrc32(bytes) != header.crc32) {
        throw const FormatException(
          'Windows portable archive contains a corrupt entry.',
        );
      }
      if (!directoryName) filesByPath[name] = header;
    }
    if (!_requiredWindowsRuntimeFiles.every(filesByPath.containsKey)) {
      throw const FormatException(
        'Windows portable archive is missing runtime files.',
      );
    }

    final manifestEntry = filesByPath['manifest.json']!.file!;
    final Map<String, Object?> embeddedManifest;
    try {
      final decoded = jsonDecode(
        utf8.decode(manifestEntry.getStream().toUint8List()),
      );
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw const FormatException();
      }
      embeddedManifest = Map<String, Object?>.from(decoded);
    } on Object {
      throw const FormatException('Windows core manifest is invalid.');
    }
    final coreHash = embeddedManifest['coreSha256'];
    if (embeddedManifest.length != 1 ||
        coreHash is! String ||
        !_digestPattern.hasMatch(coreHash)) {
      throw const FormatException('Windows core manifest fields are invalid.');
    }
    final actualCoreHash = sha256
        .convert(
          filesByPath['FlashcoCore.exe']!.file!.getStream().toUint8List(),
        )
        .toString();
    if (coreHash != actualCoreHash) {
      throw const FormatException(
        'Windows core manifest does not match its binary.',
      );
    }
  } finally {
    await Future.wait(
      headers.map((header) => header.file?.close() ?? Future.value()),
    );
  }
}

String? _versionFromTag(String tag) {
  final match = RegExp(
    r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  ).firstMatch(tag);
  if (match == null) return null;
  for (final group in [match[1], match[2], match[3]]) {
    if (int.tryParse(group!) == null) return null;
  }
  return tag.substring(1);
}
