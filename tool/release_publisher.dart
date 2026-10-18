import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const flashcoReleaseRepository = 'Artypoul/Flashco';

String releaseProvenanceMarker(
  String tag,
  String sourceSha,
  int originalRunId,
) {
  final normalizedSha = sourceSha.toLowerCase();
  if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(normalizedSha) ||
      originalRunId <= 0) {
    throw const ReleasePublishException('Invalid release provenance identity.');
  }
  return '<!-- flashco-release-provenance tag="$tag" '
      'source-sha="$normalizedSha" workflow-run-id="$originalRunId" -->';
}

sealed class ReleaseApiRequest {
  const ReleaseApiRequest();
}

final class ListReleasesRequest extends ReleaseApiRequest {
  const ListReleasesRequest({required this.page, this.perPage = 100});

  final int page;
  final int perPage;
}

final class GetReleaseByTagRequest extends ReleaseApiRequest {
  const GetReleaseByTagRequest(this.tag);

  final String tag;
}

final class GetLatestReleaseRequest extends ReleaseApiRequest {
  const GetLatestReleaseRequest();
}

final class DownloadReleaseAssetRequest extends ReleaseApiRequest {
  const DownloadReleaseAssetRequest(this.assetId);

  final int assetId;
}

final class CreateDraftReleaseRequest extends ReleaseApiRequest {
  const CreateDraftReleaseRequest({
    required this.tag,
    required this.targetSha,
    required this.body,
  });

  final String tag;
  final String targetSha;
  final String body;
  bool get draft => true;
  bool get prerelease => false;
}

final class UploadReleaseAssetRequest extends ReleaseApiRequest {
  const UploadReleaseAssetRequest({
    required this.releaseId,
    required this.name,
    required this.file,
    required this.size,
    required this.sha256,
    required this.beforeUpload,
  });

  final int releaseId;
  final String name;
  final File file;
  final int size;
  final String sha256;
  final Future<void> Function() beforeUpload;
}

class ReleaseApiResponse {
  const ReleaseApiResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
}

typedef ReleaseApiExecutor =
    Future<ReleaseApiResponse> Function(ReleaseApiRequest request);

class ReleasePublishException implements Exception {
  const ReleasePublishException(this.message);

  final String message;

  @override
  String toString() => 'ReleasePublishException: $message';
}

class ReleasePublishResult {
  const ReleasePublishResult({
    required this.releaseId,
    required this.created,
    required this.assetSha256s,
  });

  final int releaseId;
  final bool created;
  final Map<String, String> assetSha256s;
}

Future<ReleasePublishResult> publishDraftRelease({
  required String tag,
  required String sourceSha,
  required int originalRunId,
  required Map<String, File> assets,
  required String releaseBody,
  required ReleaseApiExecutor execute,
  required Future<void> Function() revalidate,
}) async {
  final normalizedSha = sourceSha.toLowerCase();
  final marker = releaseProvenanceMarker(tag, normalizedSha, originalRunId);
  final body = '$releaseBody\n\n$marker';
  if (releaseBody.contains('<!-- flashco-release-provenance')) {
    throw const ReleasePublishException(
      'The verified release body already contains a provenance marker.',
    );
  }
  late final Map<String, _LocalAsset> localAssets;
  try {
    localAssets = await _inspectBundle(
      assets: assets,
      tag: tag,
      sourceSha: normalizedSha,
      originalRunId: originalRunId,
    );
  } on ReleasePublishException {
    rethrow;
  } on Object {
    throw const ReleasePublishException(
      'Local release bundle verification failed.',
    );
  }
  final identity = _ReleaseIdentity(
    tag: tag,
    body: body,
    allowedNames: localAssets.keys.toSet(),
  );

  try {
    final published = await _readReleaseByTag(execute, tag);
    if (published != null) {
      throw const ReleasePublishException(
        'A release already exists for this tag; published tags are immutable.',
      );
    }

    final inventory = await _listReleases(execute);
    final matching = inventory.where((release) => release.tag == tag).toList();
    if (matching.length > 1) {
      throw const ReleasePublishException(
        'GitHub returned more than one release for the requested tag.',
      );
    }
    var draft = matching.isEmpty ? null : matching.single;
    if (draft != null) _validateDraft(draft, identity);

    final initialLatest = _LatestIdentity.fromRelease(
      await _readLatestRelease(execute),
    );
    var created = false;
    if (draft == null) {
      await _runRevalidation(revalidate);
      final response = await _writeAndReadbackOnFailure(
        execute: execute,
        request: CreateDraftReleaseRequest(
          tag: tag,
          targetSha: normalizedSha,
          body: body,
        ),
        expectedStatus: 201,
        identity: identity,
      );
      try {
        draft = _parseRelease(_decodeObject(response.body));
        _validateDraft(draft, identity);
        if (draft.assets.isNotEmpty) {
          throw const ReleasePublishException(
            'A newly created draft unexpectedly contains release assets.',
          );
        }
      } on Object {
        await _readbackAfterUncertainWrite(execute, identity);
        rethrow;
      }
      created = true;
    }

    final draftId = draft.id;
    await _verifyRemoteAssets(execute, draft, localAssets);
    final verifiedNames = draft.assetsByName.keys.toSet();
    final missing = localAssets.keys
        .where((name) => !draft!.assetsByName.containsKey(name))
        .toList();
    var firstWriteValidated = created;
    for (final name in missing) {
      final beforeUpload = await _readCurrentDraft(execute, identity, draftId);
      await _verifyNewRemoteAssets(
        execute,
        beforeUpload,
        localAssets,
        verifiedNames,
      );
      final alreadyAdded = beforeUpload.assetsByName.containsKey(name);
      if (alreadyAdded) {
        verifiedNames.add(name);
        draft = beforeUpload;
        continue;
      }
      final localAsset = localAssets[name]!;
      final now = await _inspectFile(localAsset.name, localAsset.file);
      if (now.size != localAsset.size || now.sha256 != localAsset.sha256) {
        throw const ReleasePublishException(
          'A local asset changed after validation.',
        );
      }
      if (!firstWriteValidated) {
        await _runRevalidation(revalidate);
        firstWriteValidated = true;
      }
      final finalGuard = await _readCurrentDraft(execute, identity, draftId);
      if (!_sameStringSet(
        finalGuard.assetsByName.keys.toSet(),
        verifiedNames,
      )) {
        throw const ReleasePublishException(
          'Draft assets changed during preflight; stopped before upload.',
        );
      }
      if (finalGuard.assetsByName.containsKey(name)) {
        throw const ReleasePublishException(
          'The asset appeared during preflight; stopped before duplicate upload.',
        );
      }
      draft = finalGuard;
      await _writeAndReadbackOnFailure(
        execute: execute,
        request: UploadReleaseAssetRequest(
          releaseId: draftId,
          name: localAsset.name,
          file: localAsset.file,
          size: localAsset.size,
          sha256: localAsset.sha256,
          beforeUpload: () async {
            final immediatelyCurrent = await _readCurrentDraft(
              execute,
              identity,
              draftId,
            );
            if (!_sameStringSet(
                  immediatelyCurrent.assetsByName.keys.toSet(),
                  verifiedNames,
                ) ||
                immediatelyCurrent.assetsByName.containsKey(name)) {
              throw const ReleasePublishException(
                'Draft state changed before asset upload.',
              );
            }
          },
        ),
        expectedStatus: 201,
        identity: identity,
      );
      draft = await _readCurrentDraft(execute, identity, draftId);
      final uploaded = draft.assetsByName[name];
      if (uploaded == null ||
          uploaded.size != localAsset.size ||
          uploaded.state != 'uploaded') {
        await _readbackAfterUncertainWrite(execute, identity);
        throw const ReleasePublishException(
          'GitHub did not confirm the uploaded asset.',
        );
      }
      await _verifyRemoteAsset(execute, uploaded, localAsset);
      verifiedNames.add(name);
    }

    if (!firstWriteValidated) await _runRevalidation(revalidate);

    final finalDraft = await _readCurrentDraft(execute, identity, draftId);
    await _verifyRemoteAssets(execute, finalDraft, localAssets);
    if (finalDraft.assetsByName.length != localAssets.length) {
      throw const ReleasePublishException(
        'The final draft contains an unexpected release asset.',
      );
    }
    final finalLatest = _LatestIdentity.fromRelease(
      await _readLatestRelease(execute),
    );
    if (initialLatest != finalLatest) {
      throw const ReleasePublishException(
        'The latest published release changed during draft preparation.',
      );
    }
    return ReleasePublishResult(
      releaseId: draftId,
      created: created,
      assetSha256s: Map.unmodifiable(
        localAssets.map((name, asset) => MapEntry(name, asset.sha256)),
      ),
    );
  } on ReleasePublishException {
    rethrow;
  } on Object {
    throw const ReleasePublishException('Release preparation stopped safely.');
  }
}

Future<Map<String, _LocalAsset>> _inspectBundle({
  required Map<String, File> assets,
  required String tag,
  required String sourceSha,
  required int originalRunId,
}) async {
  const metadataNames = {'release-manifest.json', 'SHA256SUMS'};
  if (assets.length != 5 || !assets.keys.toSet().containsAll(metadataNames)) {
    throw const ReleasePublishException(
      'The release bundle must contain exactly five named assets.',
    );
  }
  final binaryNames = assets.keys.where(
    (name) =>
        name.toLowerCase().endsWith('.apk') ||
        name.toLowerCase().endsWith('.exe') ||
        name.toLowerCase().endsWith('.zip'),
  );
  if (binaryNames.length != 3 ||
      binaryNames.where((name) => name.toLowerCase().endsWith('.apk')).length !=
          1 ||
      binaryNames.where((name) => name.toLowerCase().endsWith('.exe')).length !=
          1 ||
      binaryNames.where((name) => name.toLowerCase().endsWith('.zip')).length !=
          1 ||
      assets.keys.any(
        (name) =>
            name.isEmpty ||
            name.contains('/') ||
            name.contains('\\') ||
            name == '.' ||
            name == '..',
      )) {
    throw const ReleasePublishException(
      'The release bundle has invalid or ambiguous asset names.',
    );
  }

  final inspected = <String, _LocalAsset>{};
  for (final entry in assets.entries) {
    inspected[entry.key] = await _inspectFile(entry.key, entry.value);
  }
  final manifestBytes = await assets['release-manifest.json']!.readAsBytes();
  final manifest = _decodeObject(manifestBytes);
  if (manifest['schemaVersion'] != 1 ||
      manifest['tag'] != tag ||
      manifest['commit'] != sourceSha ||
      manifest['workflowRunId'] != originalRunId ||
      manifest['assets'] is! List) {
    throw const ReleasePublishException(
      'The release manifest does not match the requested bundle identity.',
    );
  }
  final manifestAssets = manifest['assets']! as List<Object?>;
  if (manifestAssets.length != 3) {
    throw const ReleasePublishException(
      'The release manifest must list exactly the APK, EXE, and ZIP.',
    );
  }
  final manifestNames = <String>{};
  for (final value in manifestAssets) {
    if (value is! Map<String, Object?>) {
      throw const ReleasePublishException('Malformed manifest asset entry.');
    }
    final name = value['name'];
    final size = value['size'];
    final digest = value['sha256'];
    if (name is! String) {
      throw const ReleasePublishException('Malformed manifest asset name.');
    }
    final local = inspected[name];
    if (local == null ||
        !binaryNames.contains(name) ||
        size != local.size ||
        digest != local.sha256 ||
        !manifestNames.add(name)) {
      throw const ReleasePublishException(
        'Manifest asset names, sizes, and hashes must match the local files.',
      );
    }
  }
  if (!binaryNames.toSet().containsAll(manifestNames) ||
      manifestNames.length != 3) {
    throw const ReleasePublishException(
      'The manifest does not enumerate the local APK, EXE, and ZIP exactly.',
    );
  }

  final sums = await assets['SHA256SUMS']!.readAsString();
  final sumEntries = <String, String>{};
  for (final line in const LineSplitter().convert(sums)) {
    final match = RegExp(
      r'^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || sumEntries.containsKey(match[2])) {
      throw const ReleasePublishException('Malformed SHA256SUMS file.');
    }
    sumEntries[match[2]!] = match[1]!;
  }
  final checksumNames = <String>{...binaryNames, 'release-manifest.json'};
  if (sumEntries.length != checksumNames.length ||
      !sumEntries.keys.toSet().containsAll(checksumNames) ||
      sumEntries.entries.any(
        (entry) => inspected[entry.key]!.sha256 != entry.value,
      )) {
    throw const ReleasePublishException(
      'SHA256SUMS does not exactly match the release bundle.',
    );
  }
  return Map.unmodifiable(inspected);
}

Future<_LocalAsset> _inspectFile(String name, File file) async {
  if (!await file.exists()) {
    throw const ReleasePublishException('A release asset is missing.');
  }
  final size = await file.length();
  final digest = await sha256.bind(file.openRead()).first;
  return _LocalAsset(
    name: name,
    file: file,
    size: size,
    sha256: digest.toString(),
  );
}

Future<_Release?> _readReleaseByTag(
  ReleaseApiExecutor execute,
  String tag,
) async {
  final response = await execute(GetReleaseByTagRequest(tag));
  if (response.statusCode == 404 && _isStructuredNotFound(response.body)) {
    return null;
  }
  if (response.statusCode != 200) {
    throw const ReleasePublishException(
      'Cannot establish release state for the requested tag.',
    );
  }
  final release = _parseRelease(_decodeObject(response.body));
  if (release.tag != tag || release.draft) {
    throw const ReleasePublishException(
      'The tag lookup returned an unexpected or draft release.',
    );
  }
  return release;
}

Future<List<_Release>> _listReleases(ReleaseApiExecutor execute) async {
  final releases = <_Release>[];
  final releaseIds = <int>{};
  final assetIds = <int>{};
  var page = 1;
  for (var pagesRead = 0; pagesRead < 1000; pagesRead++) {
    final response = await execute(ListReleasesRequest(page: page));
    if (response.statusCode != 200) {
      throw const ReleasePublishException(
        'Cannot read complete release history.',
      );
    }
    final decoded = _decodeJson(response.body);
    if (decoded is! List<Object?>) {
      throw const ReleasePublishException('Malformed GitHub releases page.');
    }
    final pageReleases = <_Release>[];
    for (final item in decoded) {
      if (item is! Map<String, Object?>) {
        throw const ReleasePublishException('Malformed GitHub release entry.');
      }
      final release = _parseRelease(item);
      if (!releaseIds.add(release.id)) {
        throw const ReleasePublishException(
          'GitHub release pagination returned a duplicate release ID.',
        );
      }
      for (final asset in release.assets) {
        if (!assetIds.add(asset.id)) {
          throw const ReleasePublishException(
            'GitHub release pagination returned a duplicate asset ID.',
          );
        }
      }
      pageReleases.add(release);
    }
    releases.addAll(pageReleases);
    final nextPage = _nextPage(response.headers, page);
    if (nextPage == null) {
      if (_header(response.headers, 'link') == null &&
          pageReleases.length == 100) {
        page++;
        continue;
      }
      return releases;
    }
    page = nextPage;
  }
  throw const ReleasePublishException(
    'Release pagination exceeded safety limit.',
  );
}

Future<_Release?> _readLatestRelease(ReleaseApiExecutor execute) async {
  final response = await execute(const GetLatestReleaseRequest());
  if (response.statusCode == 404 && _isStructuredNotFound(response.body)) {
    return null;
  }
  if (response.statusCode != 200) {
    throw const ReleasePublishException(
      'Cannot establish the latest published release.',
    );
  }
  final release = _parseRelease(_decodeObject(response.body));
  if (release.draft || release.prerelease) {
    throw const ReleasePublishException(
      'GitHub latest endpoint returned a draft or prerelease.',
    );
  }
  return release;
}

Future<_Release> _readCurrentDraft(
  ReleaseApiExecutor execute,
  _ReleaseIdentity identity,
  int expectedReleaseId,
) async {
  final tagLookup = await _readReleaseByTag(execute, identity.tag);
  if (tagLookup != null) {
    throw const ReleasePublishException(
      'The requested draft became a published release.',
    );
  }
  final releases = await _listReleases(execute);
  final matching = releases
      .where((release) => release.tag == identity.tag)
      .toList();
  if (matching.length != 1) {
    throw const ReleasePublishException(
      'The requested draft is missing or ambiguous in current release history.',
    );
  }
  final draft = matching.single;
  if (draft.id != expectedReleaseId) {
    throw const ReleasePublishException('The draft release ID changed.');
  }
  _validateDraft(draft, identity);
  return draft;
}

Future<void> _verifyRemoteAssets(
  ReleaseApiExecutor execute,
  _Release release,
  Map<String, _LocalAsset> localAssets,
) async {
  if (release.assetsByName.keys.any((name) => !localAssets.containsKey(name))) {
    throw const ReleasePublishException(
      'The draft contains an asset not present in the verified local bundle.',
    );
  }
  for (final remote in release.assets) {
    final local = localAssets[remote.name]!;
    await _verifyRemoteAsset(execute, remote, local);
  }
}

Future<void> _verifyNewRemoteAssets(
  ReleaseApiExecutor execute,
  _Release release,
  Map<String, _LocalAsset> localAssets,
  Set<String> verifiedNames,
) async {
  if (release.assetsByName.keys.any((name) => !localAssets.containsKey(name))) {
    throw const ReleasePublishException(
      'The draft contains an asset not present in the verified local bundle.',
    );
  }
  for (final remote in release.assets) {
    if (verifiedNames.contains(remote.name)) continue;
    await _verifyRemoteAsset(execute, remote, localAssets[remote.name]!);
    verifiedNames.add(remote.name);
  }
}

Future<void> _verifyRemoteAsset(
  ReleaseApiExecutor execute,
  _RemoteAsset remote,
  _LocalAsset local,
) async {
  if (remote.size != local.size || remote.state != 'uploaded') {
    throw const ReleasePublishException(
      'Remote asset metadata does not match the verified bundle.',
    );
  }
  final response = await execute(DownloadReleaseAssetRequest(remote.id));
  if (response.statusCode != 200) {
    throw const ReleasePublishException(
      'Cannot download a remote asset for byte verification.',
    );
  }
  final actualHash = sha256.convert(response.body).toString();
  if (response.body.length != local.size || actualHash != local.sha256) {
    throw const ReleasePublishException(
      'Downloaded remote asset bytes do not match the verified bundle.',
    );
  }
}

Future<ReleaseApiResponse> _writeAndReadbackOnFailure({
  required ReleaseApiExecutor execute,
  required ReleaseApiRequest request,
  required int expectedStatus,
  required _ReleaseIdentity identity,
}) async {
  ReleaseApiResponse? response;
  try {
    response = await execute(request);
    if (response.statusCode == expectedStatus) return response;
  } on Object {
    // A transport exception is an unknown write outcome; readback cannot authorize retry.
  }
  await _readbackAfterUncertainWrite(execute, identity);
  throw const ReleasePublishException(
    'Write outcome is uncertain or rejected; stopped after readback.',
  );
}

Future<void> _readbackAfterUncertainWrite(
  ReleaseApiExecutor execute,
  _ReleaseIdentity identity,
) async {
  try {
    await _readReleaseByTag(execute, identity.tag);
    await _listReleases(execute);
  } on Object {
    // The original write outcome remains unknown; readback cannot authorize retry.
  }
}

Future<void> _runRevalidation(Future<void> Function() revalidate) async {
  try {
    await revalidate();
  } on Object {
    throw const ReleasePublishException('Fresh release revalidation failed.');
  }
}

void _validateDraft(_Release draft, _ReleaseIdentity identity) {
  if (!draft.draft ||
      draft.prerelease ||
      draft.tag != identity.tag ||
      draft.targetCommitish.isEmpty ||
      draft.body != identity.body) {
    throw const ReleasePublishException(
      'Existing draft identity, status, target metadata, or provenance body differs.',
    );
  }
  if (draft.assetsByName.length != draft.assets.length) {
    throw const ReleasePublishException(
      'Draft contains duplicate asset names.',
    );
  }
  if (draft.assets.any(
    (asset) => !identity.allowedNames.contains(asset.name),
  )) {
    throw const ReleasePublishException(
      'Draft contains an unknown asset name.',
    );
  }
}

_Release _parseRelease(Map<String, Object?> json) {
  final id = json['id'];
  final tag = json['tag_name'];
  final target = json['target_commitish'];
  final draft = json['draft'];
  final prerelease = json['prerelease'];
  final body = json['body'];
  final assetsJson = json['assets'];
  if (id is! int ||
      id <= 0 ||
      tag is! String ||
      tag.isEmpty ||
      target is! String ||
      target.trim().isEmpty ||
      draft is! bool ||
      prerelease is! bool ||
      (body != null && body is! String) ||
      assetsJson is! List<Object?>) {
    throw const ReleasePublishException('Malformed GitHub release schema.');
  }
  final assets = <_RemoteAsset>[];
  final ids = <int>{};
  final names = <String>{};
  for (final item in assetsJson) {
    if (item is! Map<String, Object?>) {
      throw const ReleasePublishException('Malformed GitHub release asset.');
    }
    final assetId = item['id'];
    final name = item['name'];
    final size = item['size'];
    final state = item['state'];
    if (assetId is! int ||
        assetId <= 0 ||
        name is! String ||
        name.isEmpty ||
        size is! int ||
        size < 0 ||
        state is! String ||
        !ids.add(assetId) ||
        !names.add(name)) {
      throw const ReleasePublishException(
        'Malformed or duplicate GitHub asset.',
      );
    }
    assets.add(_RemoteAsset(id: assetId, name: name, size: size, state: state));
  }
  return _Release(
    id: id,
    tag: tag,
    targetCommitish: target,
    draft: draft,
    prerelease: prerelease,
    body: body as String? ?? '',
    assets: List.unmodifiable(assets),
  );
}

int? _nextPage(Map<String, String> headers, int currentPage) {
  final link = _header(headers, 'link');
  if (link == null) return null;
  final nextLinks = <Uri>[];
  for (final section in link.split(',')) {
    final match = RegExp(
      r'^\s*<([^>]+)>\s*;\s*rel="?([^";]+)"?\s*$',
    ).firstMatch(section);
    if (match == null) {
      throw const ReleasePublishException(
        'Malformed GitHub pagination Link header.',
      );
    }
    if (match[2]!.split(' ').contains('next')) {
      nextLinks.add(Uri.tryParse(match[1]!) ?? Uri());
    }
  }
  if (nextLinks.isEmpty) return null;
  if (nextLinks.length != 1) {
    throw const ReleasePublishException(
      'Ambiguous GitHub pagination Link header.',
    );
  }
  final uri = nextLinks.single;
  final page = int.tryParse(uri.queryParameters['page'] ?? '');
  if (uri.scheme != 'https' ||
      uri.host != 'api.github.com' ||
      uri.path != '/repos/Artypoul/Flashco/releases' ||
      uri.queryParameters['per_page'] != '100' ||
      page != currentPage + 1) {
    throw const ReleasePublishException('Unexpected GitHub pagination target.');
  }
  return page;
}

String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}

bool _sameStringSet(Set<String> first, Set<String> second) =>
    first.length == second.length && first.containsAll(second);

bool _isStructuredNotFound(Uint8List body) {
  try {
    final json = _decodeObject(body);
    final status = json['status'];
    final documentationUrl = json['documentation_url'];
    return json['message'] == 'Not Found' &&
        (status == '404' || status == 404) &&
        documentationUrl is String &&
        documentationUrl.startsWith(
          'https://docs.github.com/rest/releases/releases#',
        );
  } on Object {
    return false;
  }
}

Object? _decodeJson(Uint8List bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } on Object {
    throw const ReleasePublishException('Malformed GitHub JSON response.');
  }
}

Map<String, Object?> _decodeObject(Uint8List bytes) {
  final decoded = _decodeJson(bytes);
  if (decoded is! Map<String, Object?>) {
    throw const ReleasePublishException('Expected a GitHub JSON object.');
  }
  return decoded;
}

class _ReleaseIdentity {
  _ReleaseIdentity({
    required this.tag,
    required this.body,
    required this.allowedNames,
  });

  final String tag;
  final String body;
  final Set<String> allowedNames;
}

class _LocalAsset {
  const _LocalAsset({
    required this.name,
    required this.file,
    required this.size,
    required this.sha256,
  });

  final String name;
  final File file;
  final int size;
  final String sha256;
}

class _RemoteAsset {
  const _RemoteAsset({
    required this.id,
    required this.name,
    required this.size,
    required this.state,
  });

  final int id;
  final String name;
  final int size;
  final String state;
}

class _Release {
  _Release({
    required this.id,
    required this.tag,
    required this.targetCommitish,
    required this.draft,
    required this.prerelease,
    required this.body,
    required this.assets,
  });

  final int id;
  final String tag;
  final String targetCommitish;
  final bool draft;
  final bool prerelease;
  final String body;
  final List<_RemoteAsset> assets;
  Map<String, _RemoteAsset> get assetsByName =>
      Map.unmodifiable({for (final asset in assets) asset.name: asset});
}

class _LatestIdentity {
  const _LatestIdentity({required this.id, required this.tag});

  factory _LatestIdentity.fromRelease(_Release? release) => release == null
      ? const _LatestIdentity(id: 0, tag: '')
      : _LatestIdentity(id: release.id, tag: release.tag);

  final int id;
  final String tag;

  @override
  bool operator ==(Object other) =>
      other is _LatestIdentity && other.id == id && other.tag == tag;

  @override
  int get hashCode => Object.hash(id, tag);
}
