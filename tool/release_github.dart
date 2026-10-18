import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'release_publisher.dart';

typedef GhProcessRunner =
    Future<GhProcessResult> Function(
      String executable,
      List<String> arguments, {
      required Map<String, String> environment,
      Uint8List? stdinBytes,
    });

class GhProcessResult {
  const GhProcessResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final Uint8List stdout;
  final Uint8List stderr;
}

class ReleaseGitHubApiException implements Exception {
  const ReleaseGitHubApiException(this.message);

  final String message;

  @override
  String toString() => 'ReleaseGitHubApiException: $message';
}

ReleaseApiExecutor createGhReleaseApiExecutor({
  required String token,
  GhProcessRunner? runner,
}) {
  if (token.trim().isEmpty || token.contains('\n') || token.contains('\r')) {
    throw const ReleaseGitHubApiException(
      'GitHub authentication is unavailable.',
    );
  }
  final processRunner = runner ?? _runGh;
  return (request) async {
    final call = await _createCall(request);
    if (request case UploadReleaseAssetRequest(:final beforeUpload)) {
      try {
        await beforeUpload();
      } on Object {
        throw const ReleaseGitHubApiException(
          'Release draft changed before asset upload.',
        );
      }
    }
    final GhProcessResult result;
    try {
      result = await processRunner(
        'gh',
        call.arguments,
        environment: {'GH_TOKEN': token},
        stdinBytes: call.stdinBytes,
      );
    } on Object {
      throw const ReleaseGitHubApiException(
        'GitHub API request could not be started or completed.',
      );
    }
    if (result.exitCode != 0 && !_containsResponseHeaders(result.stdout)) {
      throw const ReleaseGitHubApiException(
        'GitHub API request failed before a response was received.',
      );
    }
    final response = _parseResponse(result.stdout);
    if (result.exitCode != 0 &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      throw const ReleaseGitHubApiException(
        'GitHub API request outcome is uncertain.',
      );
    }
    return response;
  };
}

Future<_GhCall> _createCall(ReleaseApiRequest request) async {
  const apiRoot = 'repos/$flashcoReleaseRepository/releases';
  final arguments = <String>['api', '--hostname', 'github.com', '--include'];
  if (request is! DownloadReleaseAssetRequest) {
    arguments.addAll(['-H', 'Accept: application/vnd.github+json']);
  }
  Uint8List? stdinBytes;
  switch (request) {
    case ListReleasesRequest(:final page, :final perPage):
      if (page < 1 || perPage < 1 || perPage > 100) {
        throw const ReleaseGitHubApiException('Invalid release page request.');
      }
      arguments.add('$apiRoot?per_page=$perPage&page=$page');
    case GetReleaseByTagRequest(:final tag):
      if (!_stableTagPattern.hasMatch(tag)) {
        throw const ReleaseGitHubApiException('Invalid release tag request.');
      }
      arguments.add('$apiRoot/tags/${Uri.encodeComponent(tag)}');
    case GetLatestReleaseRequest():
      arguments.add('$apiRoot/latest');
    case DownloadReleaseAssetRequest(:final assetId):
      if (assetId < 1) {
        throw const ReleaseGitHubApiException('Invalid release asset request.');
      }
      arguments
        ..addAll(['-H', 'Accept: application/octet-stream'])
        ..add('$apiRoot/assets/$assetId');
    case CreateDraftReleaseRequest(:final tag, :final targetSha, :final body):
      final normalizedSha = targetSha.toLowerCase();
      if (!_stableTagPattern.hasMatch(tag) ||
          !_commitShaPattern.hasMatch(normalizedSha) ||
          body.contains('\u0000')) {
        throw const ReleaseGitHubApiException('Invalid draft release request.');
      }
      final payload = utf8.encode(
        jsonEncode({
          'tag_name': tag,
          'target_commitish': normalizedSha,
          'name': tag,
          'body': body,
          'draft': true,
          'prerelease': false,
        }),
      );
      arguments
        ..addAll([
          '--method',
          'POST',
          '-H',
          'Content-Type: application/json',
          '--input',
          '-',
        ])
        ..add(apiRoot);
      stdinBytes = Uint8List.fromList(payload);
    case UploadReleaseAssetRequest(
      :final releaseId,
      :final name,
      :final file,
      :final size,
      :final sha256,
    ):
      if (releaseId < 1 ||
          !_assetNamePattern.hasMatch(name) ||
          size <= 0 ||
          !_shaPattern.hasMatch(sha256)) {
        throw const ReleaseGitHubApiException(
          'Invalid release asset upload request.',
        );
      }
      if (!await file.exists() || await file.length() != size) {
        throw const ReleaseGitHubApiException(
          'Release asset changed before upload.',
        );
      }
      final digest = await _sha256Digest(file);
      if (digest != sha256) {
        throw const ReleaseGitHubApiException(
          'Release asset changed before upload.',
        );
      }
      final uploadUrl =
          'https://uploads.github.com/$apiRoot/$releaseId/assets'
          '?name=${Uri.encodeComponent(name)}';
      arguments
        ..addAll([
          '--method',
          'POST',
          '-H',
          'Content-Type: application/octet-stream',
          '--input',
          file.path,
        ])
        ..add(uploadUrl);
  }
  return _GhCall(arguments, stdinBytes);
}

Future<String> _sha256Digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<GhProcessResult> _runGh(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  Uint8List? stdinBytes,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: true,
    runInShell: false,
  );
  final stdout = _collectBytes(process.stdout);
  final stderr = _collectBytes(process.stderr);
  if (stdinBytes != null) {
    await process.stdin.addStream(Stream.value(stdinBytes));
  }
  await process.stdin.close();
  final exitCode = await process.exitCode;
  return GhProcessResult(exitCode, await stdout, await stderr);
}

Future<Uint8List> _collectBytes(Stream<List<int>> stream) async =>
    Uint8List.fromList(await stream.expand((chunk) => chunk).toList());

ReleaseApiResponse _parseResponse(Uint8List output) {
  final separator = _findHeaderSeparator(output);
  if (separator < 0) {
    throw const ReleaseGitHubApiException(
      'GitHub API response headers were missing or malformed.',
    );
  }
  final headerText = latin1.decode(output.sublist(0, separator));
  final lines = headerText.split(RegExp(r'\r?\n'));
  final statusMatch = RegExp(
    r'^HTTP/\S+\s+(\d{3})(?:\s+.*)?$',
  ).firstMatch(lines.first);
  if (statusMatch == null) {
    throw const ReleaseGitHubApiException(
      'GitHub API response status was malformed.',
    );
  }
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) {
      throw const ReleaseGitHubApiException(
        'GitHub API response headers were malformed.',
      );
    }
    final name = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    headers.update(
      name,
      (existing) => '$existing, $value',
      ifAbsent: () => value,
    );
  }
  final bodyStart = separator + _headerSeparatorLength(output, separator);
  return ReleaseApiResponse(
    statusCode: int.parse(statusMatch[1]!),
    headers: Map.unmodifiable(headers),
    body: Uint8List.fromList(output.sublist(bodyStart)),
  );
}

bool _containsResponseHeaders(Uint8List output) =>
    _findHeaderSeparator(output) >= 0;

int _findHeaderSeparator(Uint8List bytes) {
  for (var index = 0; index < bytes.length - 1; index++) {
    if (bytes[index] == 10 && bytes[index + 1] == 10) {
      return index;
    }
    if (index <= bytes.length - 4 &&
        bytes[index] == 13 &&
        bytes[index + 1] == 10 &&
        bytes[index + 2] == 13 &&
        bytes[index + 3] == 10) {
      return index;
    }
  }
  return -1;
}

int _headerSeparatorLength(Uint8List bytes, int separator) =>
    bytes[separator] == 13 ? 4 : 2;

final _stableTagPattern = RegExp(
  r'^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$',
);
final _shaPattern = RegExp(r'^[0-9a-f]{64}$');
final _commitShaPattern = RegExp(r'^[0-9a-f]{40}$');
final _assetNamePattern = RegExp(r'^[A-Za-z0-9._ -]+$');

class _GhCall {
  const _GhCall(this.arguments, this.stdinBytes);

  final List<String> arguments;
  final Uint8List? stdinBytes;
}
