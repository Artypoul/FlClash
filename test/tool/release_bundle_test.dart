import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_bundle.dart';
import '../../tool/release_preflight.dart';

final _releaseSigner = 'd' * 64;

void main() {
  test('parses captured Android SDK output but rejects its debug signer', () {
    final outputs = _capturedAndroidOutputs();

    expect(() => parseAndroidSdkOutputs(outputs), throwsFormatException);
  });

  test('rejects multiple Android signers', () {
    final outputs = _releaseAndroidOutputs();
    expect(
      () => parseAndroidSdkOutputs(
        AndroidSdkCommandOutputs(
          identity: outputs.identity,
          applicationXml: outputs.applicationXml,
          certificates: '${outputs.certificates}${outputs.certificates}',
          abiPaths: outputs.abiPaths,
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'builds a manifest and checksums from verified files and SDK output',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flashco-bundle-',
      );
      try {
        final files = await _writePayloads(directory.path);
        final bundle = await buildReleaseBundle(
          tag: 'v1.2.3',
          commit: 'a' * 40,
          workflowRunId: 42,
          version: '1.2.3',
          buildNumber: 12,
          expectedSignerSha256: _releaseSigner,
          androidOutputs: _releaseAndroidOutputs(),
          payloadFiles: files,
        );

        expect(bundle.manifest['schemaVersion'], 1);
        expect(bundle.manifest['workflowRunId'], 42);
        expect(bundle.manifest['commit'], 'a' * 40);
        expect(bundle.manifest['assets'], hasLength(3));
        expect(bundle.sha256Sums, contains('release-manifest.json'));
        expect(bundle.sha256Sums, isNot(contains('SHA256SUMS')));
        expect(
          await verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 42,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: bundle.sha256Sums,
          ),
          isA<VerifiedReleaseBundle>(),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('rejects a missing payload instead of using ambient files', () async {
    final directory = await Directory.systemTemp.createTemp('flashco-bundle-');
    try {
      final files = await _writePayloads(directory.path);
      files.remove('Flashco-1.2.3-windows-amd64.zip');

      await expectLater(
        buildReleaseBundle(
          tag: 'v1.2.3',
          commit: 'a' * 40,
          workflowRunId: 42,
          version: '1.2.3',
          buildNumber: 12,
          expectedSignerSha256: _releaseSigner,
          androidOutputs: _releaseAndroidOutputs(),
          payloadFiles: files,
        ),
        throwsFormatException,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'rejects local payload size or hash changes during bundle recovery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flashco-bundle-',
      );
      try {
        final files = await _writePayloads(directory.path);
        final bundle = await _build(files);
        final apk = files['Flashco-1.2.3-android.apk']!;

        await apk.writeAsBytes([...await apk.readAsBytes(), 0]);
        await expectLater(
          verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 42,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: bundle.sha256Sums,
          ),
          throwsFormatException,
        );

        await apk.writeAsBytes(_apkBytes);
        await apk.writeAsBytes([9, ..._apkBytes.skip(1)]);
        await expectLater(
          verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 42,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: bundle.sha256Sums,
          ),
          throwsFormatException,
        );

        await apk.writeAsBytes(_apkBytes);
        final changedExe = files['Flashco-1.2.3-windows-amd64-setup.exe']!;
        await changedExe.writeAsBytes('tampered executable'.codeUnits);
        await expectLater(
          verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 42,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: bundle.sha256Sums,
          ),
          throwsFormatException,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('rejects duplicate, missing, wrong-package, and debug APK metadata', () {
    final valid = _releaseAndroidOutputs();
    expect(
      parseAndroidSdkOutputs(
        AndroidSdkCommandOutputs(
          identity: valid.identity,
          applicationXml: valid.applicationXml,
          certificates: valid.certificates,
          abiPaths: '${valid.abiPaths.trimRight()}\n/lib/arm64-v8a/second.so',
        ),
      )['abis'],
      ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    );

    final invalidPackage = AndroidSdkCommandOutputs(
      identity: valid.identity.replaceFirst(
        'application-id: com.follow.flashco',
        'application-id: com.follow.flashco.dev',
      ),
      applicationXml: valid.applicationXml,
      certificates: valid.certificates,
      abiPaths: valid.abiPaths,
    );
    final metadata = parseAndroidSdkOutputs(invalidPackage);
    expect(
      validateAndroidIdentity(
        metadata: metadata,
        expectedSignerSha256: _releaseSigner,
        version: '1.2.3',
        buildNumber: 12,
      ),
      isNotEmpty,
    );

    final duplicatedMetadata = Map<String, Object?>.from(
      parseAndroidSdkOutputs(valid),
    )..['abis'] = ['arm64-v8a', 'arm64-v8a', 'x86_64'];
    expect(
      validateAndroidIdentity(
        metadata: duplicatedMetadata,
        expectedSignerSha256: _releaseSigner,
        version: '1.2.3',
        buildNumber: 12,
      ),
      isNotEmpty,
    );
    for (final abiPaths in [
      '/lib/arm64-v8a/one.so\n/lib/x86_64/one.so',
      '${valid.abiPaths.trimRight()}\n/lib/mips64/extra.so',
    ]) {
      expect(
        () => parseAndroidSdkOutputs(
          AndroidSdkCommandOutputs(
            identity: valid.identity,
            applicationXml: valid.applicationXml,
            certificates: valid.certificates,
            abiPaths: abiPaths,
          ),
        ),
        throwsFormatException,
      );
    }

    final missing = AndroidSdkCommandOutputs(
      identity: valid.identity.replaceFirst('version-code: 12', ''),
      applicationXml: valid.applicationXml,
      certificates: valid.certificates,
      abiPaths: valid.abiPaths,
    );
    expect(() => parseAndroidSdkOutputs(missing), throwsFormatException);
  });

  test('requires a valid application element and defaults absent testOnly', () {
    final outputs = _releaseAndroidOutputs();
    final metadata = parseAndroidSdkOutputs(outputs);
    expect(metadata['testOnly'], isFalse);
    expect(
      File(
        'test/fixtures/release/sdk_apk_manifest_testonly.txt',
      ).readAsStringSync(),
      startsWith('NO_MATCH:'),
    );

    final testOnly = outputs.applicationXml.replaceFirst(
      'android:debuggable="false"',
      'android:debuggable="false" android:testOnly="true"',
    );
    expect(
      parseAndroidSdkOutputs(
        AndroidSdkCommandOutputs(
          identity: outputs.identity,
          applicationXml: testOnly,
          certificates: outputs.certificates,
          abiPaths: outputs.abiPaths,
        ),
      )['testOnly'],
      isTrue,
    );
    expect(
      () => parseAndroidSdkOutputs(
        AndroidSdkCommandOutputs(
          identity: outputs.identity,
          applicationXml: '<application android:testOnly="true">',
          certificates: outputs.certificates,
          abiPaths: outputs.abiPaths,
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'recovery requires the original workflow run ID and schema identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flashco-bundle-',
      );
      try {
        final files = await _writePayloads(directory.path);
        final bundle = await _build(files);

        await expectLater(
          verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 43,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: bundle.sha256Sums,
          ),
          throwsFormatException,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('rejects extra checksum names and circular checksum rows', () async {
    final directory = await Directory.systemTemp.createTemp('flashco-bundle-');
    try {
      final files = await _writePayloads(directory.path);
      final bundle = await _build(files);

      for (final invalidChecksums in [
        '${bundle.sha256Sums.trimRight()}\n${'e' * 64}  backup.zip',
        '${bundle.sha256Sums}\n${'e' * 64}  SHA256SUMS',
      ]) {
        await expectLater(
          verifyReleaseBundle(
            tag: 'v1.2.3',
            commit: 'a' * 40,
            workflowRunId: 42,
            expectedSignerSha256: _releaseSigner,
            androidOutputs: _releaseAndroidOutputs(),
            payloadFiles: files,
            manifestJson: bundle.manifestJson,
            sha256Sums: invalidChecksums,
          ),
          throwsFormatException,
        );
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'rejects ZIPs missing runtime payloads or containing private filenames',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flashco-bundle-',
      );
      try {
        final files = await _writePayloads(directory.path);
        files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
          _windowsArchive(includeHelper: false),
        );
        await expectLater(_build(files), throwsFormatException);

        files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
          _windowsArchive(privateFile: 'data/profile.json'),
        );
        await expectLater(_build(files), throwsFormatException);

        files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
          _windowsArchive(coreManifestHash: 'e' * 64),
        );
        await expectLater(_build(files), throwsFormatException);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('rejects duplicate raw ZIP headers before Archive folds them', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flashco-bundle-duplicate-zip-',
    );
    try {
      final files = await _writePayloads(directory.path);
      for (final duplicateName in ['FlashcoCore.exe', 'flashcocore.exe']) {
        files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
          _duplicateCentralHeader(
            _windowsArchive(),
            'FlashcoCore.exe',
            duplicateName: duplicateName,
          ),
        );
        await expectLater(_build(files), throwsFormatException);
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects mismatched ZIP central and local filenames', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flashco-bundle-mismatched-zip-name-',
    );
    try {
      final files = await _writePayloads(directory.path);
      files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
        _mismatchLocalFileName(_windowsArchive(), 'Flashco.exe', 'Malware.exe'),
      );

      await expectLater(_build(files), throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects Windows-invalid ZIP path components', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flashco-bundle-windows-path-',
    );
    try {
      final files = await _writePayloads(directory.path);
      for (final invalidPath in [
        'Flashco.exe.',
        'Flashco.exe ',
        r'Flashco.exe::$DATA',
        'data//unexpected.bin',
        'data\\\\unexpected.bin',
        'data/CON.txt',
        'data/name?.txt',
      ]) {
        files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
          _windowsArchive(privateFile: invalidPath),
        );
        await expectLater(_build(files), throwsFormatException);
      }

      files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
        _windowsArchive(directoryEntry: 'data/'),
      );
      await _build(files);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects a corrupted non-core Windows runtime payload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flashco-bundle-runtime-crc-',
    );
    try {
      final files = await _writePayloads(directory.path);
      files['Flashco-1.2.3-windows-amd64.zip']!.writeAsBytesSync(
        _corruptLocalPayload(_windowsArchive(), 'flutter_windows.dll'),
      );

      await expectLater(_build(files), throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

const _apkBytes = [1, 2, 3, 4];

AndroidSdkCommandOutputs _capturedAndroidOutputs() => AndroidSdkCommandOutputs(
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

AndroidSdkCommandOutputs _releaseAndroidOutputs() {
  final captured = _capturedAndroidOutputs();
  return AndroidSdkCommandOutputs(
    identity: captured.identity
        .replaceFirst('com.follow.flashco.dev', 'com.follow.flashco')
        .replaceFirst('0.9.0', '1.2.3')
        .replaceFirst('2026101401', '12')
        .replaceFirst('debuggable: true', 'debuggable: false'),
    applicationXml: captured.applicationXml.replaceFirst(
      'android:debuggable="true"',
      'android:debuggable="false"',
    ),
    certificates: captured.certificates
        .replaceFirst('Android Debug', 'Flashco Release')
        .replaceFirst(
          '4499bcc38d8453d6547bc22d6f192b69dc1b0818b2cb6a272169913567ab93d6',
          _releaseSigner,
        ),
    abiPaths: captured.abiPaths,
  );
}

Future<Map<String, File>> _writePayloads(String directory) async {
  final apk = File('$directory/release.apk')..writeAsBytesSync(_apkBytes);
  final exe = File('$directory/release.exe')
    ..writeAsBytesSync('windows setup'.codeUnits);
  final zip = File('$directory/release.zip')
    ..writeAsBytesSync(_windowsArchive());
  return {
    'Flashco-1.2.3-android.apk': apk,
    'Flashco-1.2.3-windows-amd64-setup.exe': exe,
    'Flashco-1.2.3-windows-amd64.zip': zip,
  };
}

Future<ReleaseBundle> _build(Map<String, File> files) => buildReleaseBundle(
  tag: 'v1.2.3',
  commit: 'a' * 40,
  workflowRunId: 42,
  version: '1.2.3',
  buildNumber: 12,
  expectedSignerSha256: _releaseSigner,
  androidOutputs: _releaseAndroidOutputs(),
  payloadFiles: files,
);

List<int> _windowsArchive({
  bool includeHelper = true,
  String? privateFile,
  String? coreManifestHash,
  String? directoryEntry,
}) {
  final core = 'core'.codeUnits;
  final manifest = jsonEncode({
    'coreSha256': coreManifestHash ?? sha256.convert(core).toString(),
  });
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('Flashco.exe', [1]))
    ..addFile(ArchiveFile.bytes('FlashcoCore.exe', core))
    ..addFile(ArchiveFile.bytes('manifest.json', manifest.codeUnits))
    ..addFile(ArchiveFile.bytes('flutter_windows.dll', [1]))
    ..addFile(ArchiveFile.bytes('EnableLoopback.exe', [1]))
    ..addFile(ArchiveFile.bytes('msvcp140.dll', [1]))
    ..addFile(ArchiveFile.bytes('vcruntime140.dll', [1]))
    ..addFile(ArchiveFile.bytes('data/icudtl.dat', [1]))
    ..addFile(ArchiveFile.bytes('data/app.so', [1]))
    ..addFile(ArchiveFile.bytes('data/flutter_assets/AssetManifest.bin', [1]));
  if (includeHelper) {
    archive.addFile(ArchiveFile.bytes('FlashcoHelperService.exe', [1]));
  }
  if (privateFile != null) {
    archive.addFile(ArchiveFile.bytes(privateFile, [1]));
  }
  if (directoryEntry != null) {
    archive.addFile(ArchiveFile.directory(directoryEntry));
  }
  return ZipEncoder().encode(archive);
}

List<int> _duplicateCentralHeader(
  List<int> zip,
  String name, {
  required String duplicateName,
}) {
  final bytes = List<int>.from(zip);
  final eocd = _findSignature(bytes, 0x06054b50);
  final centralOffset = _readUint32(bytes, eocd + 16);
  final centralSize = _readUint32(bytes, eocd + 12);
  final entryCount = _readUint16(bytes, eocd + 10);
  var offset = centralOffset;
  int? duplicateOffset;
  int? alternateOffset;
  for (var index = 0; index < entryCount; index++) {
    final nameLength = _readUint16(bytes, offset + 28);
    final extraLength = _readUint16(bytes, offset + 30);
    final commentLength = _readUint16(bytes, offset + 32);
    final entryName = String.fromCharCodes(
      bytes.sublist(offset + 46, offset + 46 + nameLength),
    );
    if (entryName == name) duplicateOffset = offset;
    if (entryName == 'Flashco.exe') alternateOffset = offset;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  if (duplicateOffset == null || alternateOffset == null) {
    throw StateError('Test ZIP central records were not found.');
  }

  final duplicateNameLength = _readUint16(bytes, duplicateOffset + 28);
  final duplicateExtraLength = _readUint16(bytes, duplicateOffset + 30);
  final duplicateCommentLength = _readUint16(bytes, duplicateOffset + 32);
  final duplicateLength =
      46 + duplicateNameLength + duplicateExtraLength + duplicateCommentLength;
  final alternateLocalOffset = _readUint32(bytes, alternateOffset + 42);
  final alternateCrc = _readUint32(bytes, alternateOffset + 16);
  final alternateCompressedSize = _readUint32(bytes, alternateOffset + 20);
  final alternateUncompressedSize = _readUint32(bytes, alternateOffset + 24);
  final duplicate = bytes.sublist(
    duplicateOffset,
    duplicateOffset + duplicateLength,
  );
  final duplicateNameBytes = ascii.encode(duplicateName);
  if (duplicateNameBytes.length != duplicateNameLength) {
    throw StateError('Test duplicate name must preserve ZIP header length.');
  }
  duplicate.setRange(46, 46 + duplicateNameLength, duplicateNameBytes);
  _writeUint32(duplicate, 16, alternateCrc);
  _writeUint32(duplicate, 20, alternateCompressedSize);
  _writeUint32(duplicate, 24, alternateUncompressedSize);
  _writeUint32(duplicate, 42, alternateLocalOffset);

  bytes.insertAll(centralOffset + centralSize, duplicate);
  final newEocd = eocd + duplicate.length;
  _writeUint16(bytes, newEocd + 8, entryCount + 1);
  _writeUint16(bytes, newEocd + 10, entryCount + 1);
  _writeUint32(bytes, newEocd + 12, centralSize + duplicate.length);
  return bytes;
}

List<int> _corruptLocalPayload(List<int> zip, String name) {
  final bytes = List<int>.from(zip);
  final eocd = _findSignature(bytes, 0x06054b50);
  final centralOffset = _readUint32(bytes, eocd + 16);
  final entryCount = _readUint16(bytes, eocd + 10);
  var offset = centralOffset;
  for (var index = 0; index < entryCount; index++) {
    final nameLength = _readUint16(bytes, offset + 28);
    final extraLength = _readUint16(bytes, offset + 30);
    final commentLength = _readUint16(bytes, offset + 32);
    final entryName = String.fromCharCodes(
      bytes.sublist(offset + 46, offset + 46 + nameLength),
    );
    if (entryName == name) {
      final localOffset = _readUint32(bytes, offset + 42);
      final localNameLength = _readUint16(bytes, localOffset + 26);
      final localExtraLength = _readUint16(bytes, localOffset + 28);
      final dataOffset = localOffset + 30 + localNameLength + localExtraLength;
      bytes[dataOffset] ^= 0xff;
      return bytes;
    }
    offset += 46 + nameLength + extraLength + commentLength;
  }
  throw StateError('Test ZIP payload was not found.');
}

List<int> _mismatchLocalFileName(
  List<int> zip,
  String centralName,
  String localName,
) {
  final bytes = List<int>.from(zip);
  final eocd = _findSignature(bytes, 0x06054b50);
  final centralOffset = _readUint32(bytes, eocd + 16);
  final entryCount = _readUint16(bytes, eocd + 10);
  var offset = centralOffset;
  for (var index = 0; index < entryCount; index++) {
    final nameLength = _readUint16(bytes, offset + 28);
    final extraLength = _readUint16(bytes, offset + 30);
    final commentLength = _readUint16(bytes, offset + 32);
    final entryName = String.fromCharCodes(
      bytes.sublist(offset + 46, offset + 46 + nameLength),
    );
    if (entryName == centralName) {
      final localOffset = _readUint32(bytes, offset + 42);
      final localNameLength = _readUint16(bytes, localOffset + 26);
      if (ascii.encode(localName).length != localNameLength) {
        throw StateError('Test local name must preserve ZIP header length.');
      }
      bytes.setRange(
        localOffset + 30,
        localOffset + 30 + localNameLength,
        ascii.encode(localName),
      );
      return bytes;
    }
    offset += 46 + nameLength + extraLength + commentLength;
  }
  throw StateError('Test ZIP central record was not found.');
}

int _findSignature(List<int> bytes, int signature) {
  for (var offset = bytes.length - 4; offset >= 0; offset--) {
    if (_readUint32(bytes, offset) == signature) return offset;
  }
  throw StateError('Test ZIP signature was not found.');
}

int _readUint16(List<int> bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8;

int _readUint32(List<int> bytes, int offset) =>
    bytes[offset] |
    bytes[offset + 1] << 8 |
    bytes[offset + 2] << 16 |
    bytes[offset + 3] << 24;

void _writeUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = value >> 8 & 0xff;
}

void _writeUint32(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = value >> 8 & 0xff;
  bytes[offset + 2] = value >> 16 & 0xff;
  bytes[offset + 3] = value >> 24 & 0xff;
}
