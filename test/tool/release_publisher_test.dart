import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../tool/release_publisher.dart';

const _tag = 'v1.2.3';
const _sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _runId = 123456789;
const _releaseBody = 'Release notes from the verified bundle.';
const _apk = 'Flashco-1.2.3-arm64-v8a.apk';
const _exe = 'Flashco-1.2.3-windows-x64-setup.exe';
const _zip = 'Flashco-1.2.3-windows-x64-portable.zip';

void main() {
  group('publishDraftRelease', () {
    late Directory directory;
    late Map<String, File> files;
    late Uint8List tagNotFoundFixture;
    late List<Map<String, Object?>> donorReleases;

    setUpAll(() async {
      tagNotFoundFixture = await File(
        'test/fixtures/release/github_release_tag_not_found.json',
      ).readAsBytes();
      donorReleases =
          (jsonDecode(
                    await File(
                      'test/fixtures/release/github_release_donor.json',
                    ).readAsString(),
                  )
                  as List<Object?>)
              .cast<Map<String, Object?>>();
    });

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('flashco-publisher-');
      files = await _makeBundle(directory);
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'creates a provenance-bound draft and uploads five verified assets',
      () async {
        final api = _FakeApi(notFoundBody: tagNotFoundFixture);
        var revalidations = 0;

        final result = await publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async => revalidations++,
        );

        expect(result.created, isTrue);
        expect(result.releaseId, 77);
        expect(result.assetSha256s, hasLength(5));
        expect(revalidations, 1);
        expect(
          api.requests.whereType<CreateDraftReleaseRequest>(),
          hasLength(1),
        );
        expect(
          api.requests.whereType<UploadReleaseAssetRequest>(),
          hasLength(5),
        );
        final create = api.requests
            .whereType<CreateDraftReleaseRequest>()
            .single;
        expect(create.targetSha, _sourceSha);
        expect(create.draft, isTrue);
        expect(create.prerelease, isFalse);
        expect(
          create.body,
          '$_releaseBody\n\n${releaseProvenanceMarker(_tag, _sourceSha, _runId)}',
        );
        expect(api.latestCalls, 2);
      },
    );

    test('parses the real release donor without confusing its tag', () async {
      final api = _FakeApi(
        notFoundBody: tagNotFoundFixture,
        unrelatedReleases: donorReleases,
      );

      final result = await publishDraftRelease(
        tag: _tag,
        sourceSha: _sourceSha,
        originalRunId: _runId,
        assets: files,
        releaseBody: _releaseBody,
        execute: api.execute,
        revalidate: () async {},
      );

      expect(result.created, isTrue);
      expect(api.requests.whereType<CreateDraftReleaseRequest>(), hasLength(1));
    });

    test('follows complete release pagination before create', () async {
      final releases = List<Map<String, Object?>>.generate(
        100,
        (index) => <String, Object?>{
          'id': 1000 + index,
          'tag_name': 'v0.0.$index',
          'target_commitish': 'main',
          'draft': false,
          'prerelease': false,
          'body': '',
          'assets': <Object?>[],
        },
      );
      final api = _FakeApi(
        notFoundBody: tagNotFoundFixture,
        unrelatedReleases: releases,
        paginated: true,
      );

      final result = await publishDraftRelease(
        tag: _tag,
        sourceSha: _sourceSha,
        originalRunId: _runId,
        assets: files,
        releaseBody: _releaseBody,
        execute: api.execute,
        revalidate: () async {},
      );

      expect(result.created, isTrue);
      expect(api.pageTwoCalls, greaterThan(0));
    });

    test('rejects incomplete local bundle before making API calls', () async {
      final api = _FakeApi();

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: Map.of(files)..remove(_zip),
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async {},
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests, isEmpty);
    });

    test('does not create when fresh revalidation rejects moved tag', () async {
      final api = _FakeApi();

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async => throw StateError('tag moved'),
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
      expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
    });

    test('uploads only missing assets to a matching existing draft', () async {
      final api = _FakeApi(initialDraftAssetCount: 4);

      final result = await publishDraftRelease(
        tag: _tag,
        sourceSha: _sourceSha,
        originalRunId: _runId,
        assets: files,
        releaseBody: _releaseBody,
        execute: api.execute,
        revalidate: () async {},
      );

      expect(result.created, isFalse);
      expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
      expect(api.requests.whereType<UploadReleaseAssetRequest>(), hasLength(1));
      expect(result.assetSha256s, hasLength(5));
    });

    test('revalidates before accepting an already complete draft', () async {
      final api = _FakeApi(initialDraftAssetCount: 5);
      var revalidated = false;

      final result = await publishDraftRelease(
        tag: _tag,
        sourceSha: _sourceSha,
        originalRunId: _runId,
        assets: files,
        releaseBody: _releaseBody,
        execute: api.execute,
        revalidate: () async => revalidated = true,
      );

      expect(result.created, isFalse);
      expect(revalidated, isTrue);
      expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
    });

    test('blocks an existing asset whose downloaded bytes differ', () async {
      final api = _FakeApi(
        initialDraftAssetCount: 1,
        corruptFirstDownload: true,
      );

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async {},
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
    });

    test('does not treat authorization errors as not-found', () async {
      final api = _FakeApi(tagStatus: 403);

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async {},
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
    });

    test('does not interpret an unstructured 404 as absence', () async {
      final api = _FakeApi(
        notFoundBody: Uint8List.fromList(
          utf8.encode('{"message":"Not Found"}'),
        ),
      );

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async {},
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests.whereType<CreateDraftReleaseRequest>(), isEmpty);
    });

    test('stops after an upload failure and performs readback only', () async {
      final api = _FakeApi(failUploadAt: 1);

      await expectLater(
        publishDraftRelease(
          tag: _tag,
          sourceSha: _sourceSha,
          originalRunId: _runId,
          assets: files,
          releaseBody: _releaseBody,
          execute: api.execute,
          revalidate: () async {},
        ),
        throwsA(isA<ReleasePublishException>()),
      );
      expect(api.requests.whereType<UploadReleaseAssetRequest>(), hasLength(1));
      expect(api.requests.last, isA<ListReleasesRequest>());
    });

    test(
      'fails final verification if latest published release changed',
      () async {
        final api = _FakeApi(changeLatestAfterFirstRead: true);

        await expectLater(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: api.execute,
            revalidate: () async {},
          ),
          throwsA(isA<ReleasePublishException>()),
        );
        expect(
          api.requests.whereType<UploadReleaseAssetRequest>(),
          hasLength(5),
        );
        expect(api.latestCalls, 2);
      },
    );

    test(
      'does not expose executor, callback, or local parser failures',
      () async {
        const sentinel = 'SENTINEL-CREDENTIAL-DO-NOT-LEAK';
        final readError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: (request) async => throw StateError(sentinel),
            revalidate: () async {},
          ),
        );
        expect(readError, isA<ReleasePublishException>());
        expect(readError.toString(), isNot(contains(sentinel)));

        final parseApi = _FakeApi();
        final parserError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: (request) async {
              if (request is GetReleaseByTagRequest) {
                return ReleaseApiResponse(
                  statusCode: 200,
                  headers: const {},
                  body: Uint8List.fromList(utf8.encode(sentinel)),
                );
              }
              return parseApi.execute(request);
            },
            revalidate: () async {},
          ),
        );
        expect(parserError, isA<ReleasePublishException>());
        expect(parserError.toString(), isNot(contains(sentinel)));

        final callbackApi = _FakeApi();
        final callbackError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: callbackApi.execute,
            revalidate: () async => throw StateError(sentinel),
          ),
        );
        expect(callbackError, isA<ReleasePublishException>());
        expect(callbackError.toString(), isNot(contains(sentinel)));

        final writeApi = _FakeApi();
        final writeError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: (request) async {
              if (request is CreateDraftReleaseRequest) {
                throw StateError(sentinel);
              }
              return writeApi.execute(request);
            },
            revalidate: () async {},
          ),
        );
        expect(writeError, isA<ReleasePublishException>());
        expect(writeError.toString(), isNot(contains(sentinel)));

        await files['release-manifest.json']!.writeAsString(sentinel);
        final localError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: callbackApi.execute,
            revalidate: () async {},
          ),
        );
        expect(localError, isA<ReleasePublishException>());
        expect(localError.toString(), isNot(contains(sentinel)));

        final missingFileError = await _captureError(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: Map<String, File>.of(files)
              ..[_apk] = File(
                '${directory.path}${Platform.pathSeparator}$sentinel',
              ),
            releaseBody: _releaseBody,
            execute: callbackApi.execute,
            revalidate: () async {},
          ),
        );
        expect(missingFileError, isA<ReleasePublishException>());
        expect(missingFileError.toString(), isNot(contains(sentinel)));
      },
    );

    test(
      'does not upload if the matching draft becomes published in revalidation',
      () async {
        final api = _FakeApi(initialDraftAssetCount: 4);

        await expectLater(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: api.execute,
            revalidate: () async => api.publishMatchingDraft(),
          ),
          throwsA(isA<ReleasePublishException>()),
        );
        expect(api.requests.whereType<UploadReleaseAssetRequest>(), isEmpty);
      },
    );

    test(
      'rechecks draft after adapter-side asset hashing before POST',
      () async {
        final api = _FakeApi(
          initialDraftAssetCount: 4,
          publishBeforeUploadCallback: true,
        );

        await expectLater(
          publishDraftRelease(
            tag: _tag,
            sourceSha: _sourceSha,
            originalRunId: _runId,
            assets: files,
            releaseBody: _releaseBody,
            execute: api.execute,
            revalidate: () async {},
          ),
          throwsA(isA<ReleasePublishException>()),
        );
        expect(
          api.requests.whereType<UploadReleaseAssetRequest>(),
          hasLength(1),
        );
        expect(api.postCount, 0);
      },
    );
  });

  test('provenance marker has a stable sanitized format', () {
    expect(
      releaseProvenanceMarker(_tag, _sourceSha, _runId),
      '<!-- flashco-release-provenance tag="$_tag" '
      'source-sha="$_sourceSha" workflow-run-id="$_runId" -->',
    );
  });
}

Future<Map<String, File>> _makeBundle(Directory directory) async {
  final bytes = <String, List<int>>{
    _apk: [1, 2, 3, 4],
    _exe: [5, 6, 7],
    _zip: [8, 9, 10, 11],
  };
  final manifest = <String, Object>{
    'schemaVersion': 1,
    'tag': _tag,
    'commit': _sourceSha,
    'workflowRunId': _runId,
    'version': '1.2.3',
    'buildNumber': 321,
    'android': <String, Object>{
      'packageName': 'com.example.flashco',
      'signerSha256': 'b' * 64,
      'abis': <String>['arm64-v8a'],
    },
    'assets': bytes.entries
        .map(
          (entry) => <String, Object>{
            'name': entry.key,
            'size': entry.value.length,
            'sha256': sha256.convert(entry.value).toString(),
          },
        )
        .toList(),
  };
  bytes['release-manifest.json'] = utf8.encode(jsonEncode(manifest));
  bytes['SHA256SUMS'] = utf8.encode(
    '${bytes.entries.map((entry) => '${sha256.convert(entry.value)}  ${entry.key}').join('\n')}\n',
  );
  final result = <String, File>{};
  for (final entry in bytes.entries) {
    final file = File('${directory.path}${Platform.pathSeparator}${entry.key}');
    await file.writeAsBytes(entry.value);
    result[entry.key] = file;
  }
  _bundleBytes
    ..clear()
    ..addAll(
      bytes.map((name, content) => MapEntry(name, List<int>.of(content))),
    );
  return result;
}

class _FakeApi {
  _FakeApi({
    this.initialDraftAssetCount = 0,
    this.corruptFirstDownload = false,
    this.failUploadAt,
    this.tagStatus = 404,
    this.unrelatedReleases = const [],
    this.notFoundBody,
    this.paginated = false,
    this.changeLatestAfterFirstRead = false,
    this.publishBeforeUploadCallback = false,
  }) {
    if (initialDraftAssetCount > 0) {
      _release = _releaseJson(
        body:
            '$_releaseBody\n\n${releaseProvenanceMarker(_tag, _sourceSha, _runId)}',
        assets: _localAssetNames.take(initialDraftAssetCount).map((name) {
          final fileName = name;
          return _assetJson(
            100 + _localAssetNames.indexOf(fileName),
            fileName,
            _bundleBytes[fileName]!,
          );
        }).toList(),
      );
      _downloads.addAll(
        Map<int, List<int>>.fromEntries(
          _localAssetNames.take(initialDraftAssetCount).map((name) {
            final content = List<int>.of(_bundleBytes[name]!);
            if (corruptFirstDownload && name == _localAssetNames.first) {
              content[0] ^= 0xff;
            }
            return MapEntry(100 + _localAssetNames.indexOf(name), content);
          }),
        ),
      );
    }
  }

  final int initialDraftAssetCount;
  final bool corruptFirstDownload;
  final int? failUploadAt;
  final int tagStatus;
  final List<Map<String, Object?>> unrelatedReleases;
  final Uint8List? notFoundBody;
  final bool paginated;
  final bool changeLatestAfterFirstRead;
  final bool publishBeforeUploadCallback;
  int pageTwoCalls = 0;
  final List<ReleaseApiRequest> requests = [];
  final Map<int, List<int>> _downloads = {};
  Map<String, Object?>? _release;
  int _nextAssetId = 200;
  int _uploadCount = 0;
  int _latestCalls = 0;
  int postCount = 0;
  bool _publishedDuringRevalidation = false;

  int get latestCalls => _latestCalls;

  void publishMatchingDraft() {
    _publishedDuringRevalidation = true;
    _release!['draft'] = false;
  }

  Future<ReleaseApiResponse> execute(ReleaseApiRequest request) async {
    requests.add(request);
    if (request is GetReleaseByTagRequest) {
      if (_publishedDuringRevalidation) return _response(200, _release!);
      if (tagStatus != 404) {
        return _response(tagStatus, const <String, Object?>{
          'message': 'Forbidden',
        });
      }
      return _notFound(notFoundBody);
    }
    if (request is ListReleasesRequest) {
      if (request.page == 2) {
        pageTwoCalls++;
        return _response(200, <Object?>[]);
      }
      final pageReleases = <Object?>[
        ...unrelatedReleases.take(_release == null ? 100 : 99),
        if (_release != null) _release,
      ];
      return ReleaseApiResponse(
        statusCode: 200,
        headers: paginated
            ? const {
                'Link':
                    '<https://api.github.com/repos/Artypoul/Flashco/releases?page=2&per_page=100>; rel="next"',
              }
            : const {},
        body: Uint8List.fromList(utf8.encode(jsonEncode(pageReleases))),
      );
    }
    if (request is GetLatestReleaseRequest) {
      _latestCalls++;
      if (changeLatestAfterFirstRead) {
        final latest = _releaseJson()
          ..['id'] = _latestCalls == 1 ? 41 : 42
          ..['draft'] = false
          ..['body'] = '';
        return _response(200, latest);
      }
      return _notFound(notFoundBody);
    }
    if (request is CreateDraftReleaseRequest) {
      _release = _releaseJson(body: request.body);
      return _response(201, _release!);
    }
    if (request is DownloadReleaseAssetRequest) {
      final data = _downloads[request.assetId];
      if (data == null) return _response(404, const <String, Object?>{});
      return ReleaseApiResponse(
        statusCode: 200,
        headers: const {},
        body: Uint8List.fromList(data),
      );
    }
    if (request is UploadReleaseAssetRequest) {
      if (publishBeforeUploadCallback) publishMatchingDraft();
      await request.beforeUpload();
      _uploadCount++;
      if (failUploadAt == _uploadCount) return _response(503, const {});
      postCount++;
      final data = await request.file.readAsBytes();
      final asset = _assetJson(_nextAssetId++, request.name, data);
      final assets = _release!['assets']! as List<Object?>;
      assets.add(asset);
      _downloads[asset['id']! as int] = data;
      return _response(201, asset);
    }
    throw StateError('Unexpected request $request');
  }
}

const _localAssetNames = <String>[
  _apk,
  _exe,
  _zip,
  'release-manifest.json',
  'SHA256SUMS',
];

final Map<String, List<int>> _bundleBytes = <String, List<int>>{
  _apk: [1, 2, 3, 4],
  _exe: [5, 6, 7],
  _zip: [8, 9, 10, 11],
  'release-manifest.json': <int>[],
  'SHA256SUMS': <int>[],
};

Map<String, Object?> _releaseJson({
  String body = '',
  List<Map<String, Object?>>? assets,
}) => <String, Object?>{
  'id': 77,
  'tag_name': _tag,
  'target_commitish': 'main',
  'draft': true,
  'prerelease': false,
  'body': body,
  'assets': assets ?? <Map<String, Object?>>[],
};

Map<String, Object?> _assetJson(int id, String name, List<int> bytes) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'size': bytes.length,
      'state': 'uploaded',
      'digest': 'sha256:${sha256.convert(bytes)}',
    };

ReleaseApiResponse _notFound([Uint8List? fixture]) => ReleaseApiResponse(
  statusCode: 404,
  headers: const {},
  body:
      fixture ??
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(const {
            'message': 'Not Found',
            'documentation_url':
                'https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name',
            'status': '404',
          }),
        ),
      ),
);

ReleaseApiResponse _response(int status, Object body) => ReleaseApiResponse(
  statusCode: status,
  headers: const {},
  body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

Future<Object> _captureError(Future<Object?> action) async {
  try {
    await action;
  } on Object catch (error) {
    return error;
  }
  throw StateError('Expected publisher operation to fail.');
}
