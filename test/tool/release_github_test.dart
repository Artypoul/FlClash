import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_github.dart';
import '../../tool/release_publisher.dart';

void main() {
  group('GhReleaseApiExecutor', () {
    test('uses the fixed repository for release reads', () async {
      final runner = _FakeRunner();
      final execute = createGhReleaseApiExecutor(
        token: 'fake-token',
        runner: runner.call,
      );

      await execute(const ListReleasesRequest(page: 2, perPage: 50));
      await execute(const GetReleaseByTagRequest('v1.2.3'));
      await execute(const GetLatestReleaseRequest());

      expect(runner.calls, hasLength(3));
      expect(
        runner.calls[0].arguments.last,
        'repos/Artypoul/Flashco/releases?per_page=50&page=2',
      );
      expect(
        runner.calls[1].arguments.last,
        'repos/Artypoul/Flashco/releases/tags/v1.2.3',
      );
      expect(
        runner.calls[2].arguments.last,
        'repos/Artypoul/Flashco/releases/latest',
      );
      for (final call in runner.calls) {
        expect(call.arguments, contains('--hostname'));
        expect(call.arguments, contains('github.com'));
        expect(call.arguments, contains('--include'));
        expect(call.environment['GH_TOKEN'], 'fake-token');
        expect(call.arguments.join(' '), isNot(contains('fake-token')));
      }
    });

    test(
      'returns parsed status and headers with binary asset bytes intact',
      () async {
        final bytes = Uint8List.fromList([0, 255, 10, 13, 0, 128]);
        final runner = _FakeRunner(
          output: _response(200, {
            'content-type': 'application/octet-stream',
          }, bytes),
        );
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        final response = await execute(const DownloadReleaseAssetRequest(42));

        expect(response.statusCode, 200);
        expect(response.headers['content-type'], 'application/octet-stream');
        expect(response.body, bytes);
        expect(
          runner.calls.single.arguments.last,
          'repos/Artypoul/Flashco/releases/assets/42',
        );
        expect(
          runner.calls.single.arguments,
          contains('Accept: application/octet-stream'),
        );
      },
    );

    test(
      'parses the captured gh response with mixed header line endings',
      () async {
        final bytes = await File(
          'test/fixtures/release/gh-assets-sha256sums-response.http',
        ).readAsBytes();
        final runner = _FakeRunner(output: Uint8List.fromList(bytes));
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        final response = await execute(const DownloadReleaseAssetRequest(42));

        expect(response.statusCode, 200);
        expect(response.headers['content-length'], '1517');
        expect(response.body, hasLength(1517));
        expect(response.body, bytes.sublist(_bodyStart(bytes)));
      },
    );

    test(
      'preserves structured HTTP errors despite gh returning nonzero',
      () async {
        final body = Uint8List.fromList(utf8.encode('{"message":"Not Found"}'));
        final runner = _FakeRunner(
          result: GhProcessResult(
            1,
            _response(404, {'content-type': 'application/json'}, body),
            Uint8List.fromList(utf8.encode('safe generic CLI error')),
          ),
        );
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        final response = await execute(const GetReleaseByTagRequest('v1.2.3'));

        expect(response.statusCode, 404);
        expect(response.body, body);
      },
    );

    test('rejects a success response when gh exits nonzero', () async {
      final runner = _FakeRunner(
        result: GhProcessResult(
          1,
          _response(201, const {
            'content-type': 'application/json',
          }, Uint8List.fromList(utf8.encode('{"id":7}'))),
          Uint8List.fromList(utf8.encode('ambiguous transport failure')),
        ),
      );
      final execute = createGhReleaseApiExecutor(
        token: 'fake-token',
        runner: runner.call,
      );

      await expectLater(
        execute(const GetLatestReleaseRequest()),
        throwsA(isA<ReleaseGitHubApiException>()),
      );
    });

    test('creates only a stable draft with fixed status flags', () async {
      final runner = _FakeRunner();
      final execute = createGhReleaseApiExecutor(
        token: 'fake-token',
        runner: runner.call,
      );

      await execute(
        const CreateDraftReleaseRequest(
          tag: 'v1.2.3',
          targetSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          body: 'Verified notes',
        ),
      );

      final call = runner.calls.single;
      final body = jsonDecode(utf8.decode(call.stdinBytes!)) as Map;
      expect(call.arguments, contains('--input'));
      expect(call.arguments, contains('-'));
      expect(call.arguments, contains('--method'));
      expect(call.arguments, contains('POST'));
      expect(call.arguments.last, 'repos/Artypoul/Flashco/releases');
      expect(body, {
        'tag_name': 'v1.2.3',
        'target_commitish': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'name': 'v1.2.3',
        'body': 'Verified notes',
        'draft': true,
        'prerelease': false,
      });
    });

    test(
      'uploads the requested file as bytes to the fixed upload host',
      () async {
        final dir = await Directory.systemTemp.createTemp('gh-upload-test-');
        try {
          final payload = Uint8List.fromList([0, 1, 254, 255]);
          final file = File('${dir.path}/payload.bin');
          await file.writeAsBytes(payload);
          final runner = _FakeRunner();
          final execute = createGhReleaseApiExecutor(
            token: 'fake-token',
            runner: runner.call,
          );

          await execute(
            UploadReleaseAssetRequest(
              releaseId: 77,
              name: 'safe asset.zip',
              file: file,
              size: payload.length,
              sha256: crypto.sha256.convert(payload).toString(),
              beforeUpload: () async {},
            ),
          );

          final call = runner.calls.single;
          expect(call.arguments, contains('--method'));
          expect(call.arguments, contains('POST'));
          expect(call.arguments, contains('--hostname'));
          expect(call.arguments, contains('github.com'));
          expect(call.arguments, contains('--input'));
          expect(call.arguments, contains(file.path));
          expect(
            call.arguments,
            contains('Content-Type: application/octet-stream'),
          );
          expect(
            call.arguments.last,
            'https://uploads.github.com/repos/Artypoul/Flashco/releases/77/assets?name=safe%20asset.zip',
          );
          expect(call.stdinBytes, isNull);
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );

    test('runs the fresh guard after validation and before upload', () async {
      final dir = await Directory.systemTemp.createTemp('gh-upload-guard-');
      try {
        final payload = Uint8List.fromList([0, 1, 2, 3]);
        final file = File('${dir.path}/payload.bin');
        await file.writeAsBytes(payload);
        final events = <String>[];
        final runner = _FakeRunner(onCall: () => events.add('post'));
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        await execute(
          UploadReleaseAssetRequest(
            releaseId: 77,
            name: 'safe asset.zip',
            file: file,
            size: payload.length,
            sha256: crypto.sha256.convert(payload).toString(),
            beforeUpload: () async => events.add('guard'),
          ),
        );

        expect(events, ['guard', 'post']);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('guard failure prevents upload and hides exception details', () async {
      final dir = await Directory.systemTemp.createTemp('gh-upload-guard-');
      try {
        final payload = Uint8List.fromList([0, 1, 2, 3]);
        final file = File('${dir.path}/payload.bin');
        await file.writeAsBytes(payload);
        final runner = _FakeRunner();
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        await expectLater(
          execute(
            UploadReleaseAssetRequest(
              releaseId: 77,
              name: 'safe asset.zip',
              file: file,
              size: payload.length,
              sha256: crypto.sha256.convert(payload).toString(),
              beforeUpload: () async => throw StateError('private detail'),
            ),
          ),
          throwsA(
            isA<ReleaseGitHubApiException>().having(
              (error) => error.message,
              'message',
              isNot(contains('private detail')),
            ),
          ),
        );
        expect(runner.calls, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejects an upload file changed before hashing', () async {
      final dir = await Directory.systemTemp.createTemp('gh-upload-changed-');
      try {
        final original = Uint8List.fromList([0, 1, 2, 3]);
        final file = File('${dir.path}/payload.bin');
        await file.writeAsBytes([9, 9, 9, 9]);
        final runner = _FakeRunner();
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        await expectLater(
          execute(
            UploadReleaseAssetRequest(
              releaseId: 77,
              name: 'safe asset.zip',
              file: file,
              size: original.length,
              sha256: crypto.sha256.convert(original).toString(),
              beforeUpload: () async {},
            ),
          ),
          throwsA(isA<ReleaseGitHubApiException>()),
        );
        expect(runner.calls, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejects malformed requests before launching gh', () async {
      final runner = _FakeRunner();
      final execute = createGhReleaseApiExecutor(
        token: 'fake-token',
        runner: runner.call,
      );

      await expectLater(
        execute(const ListReleasesRequest(page: 0)),
        throwsA(isA<ReleaseGitHubApiException>()),
      );
      await expectLater(
        execute(const GetReleaseByTagRequest('../other')),
        throwsA(isA<ReleaseGitHubApiException>()),
      );
      await expectLater(
        execute(const DownloadReleaseAssetRequest(0)),
        throwsA(isA<ReleaseGitHubApiException>()),
      );
      expect(runner.calls, isEmpty);
    });

    test(
      'does not expose process stderr or token in transport errors',
      () async {
        final runner = _FakeRunner(
          result: GhProcessResult(
            1,
            Uint8List(0),
            Uint8List.fromList(utf8.encode('token=secret-detail')),
          ),
        );
        final execute = createGhReleaseApiExecutor(
          token: 'fake-token',
          runner: runner.call,
        );

        await expectLater(
          execute(const GetLatestReleaseRequest()),
          throwsA(
            isA<ReleaseGitHubApiException>().having(
              (error) => error.message,
              'message',
              isNot(contains('secret-detail')),
            ),
          ),
        );
      },
    );

    test('rejects missing token without launching gh', () async {
      final runner = _FakeRunner();

      expect(
        () => createGhReleaseApiExecutor(token: '  ', runner: runner.call),
        throwsA(isA<ReleaseGitHubApiException>()),
      );
      expect(runner.calls, isEmpty);
    });
  });
}

Uint8List _response(int status, Map<String, String> headers, Uint8List body) {
  final head = StringBuffer('HTTP/2 $status OK\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  head.write('\r\n');
  return Uint8List.fromList([...ascii.encode(head.toString()), ...body]);
}

int _bodyStart(List<int> bytes) {
  for (var index = 0; index <= bytes.length - 4; index++) {
    if (bytes[index] == 13 &&
        bytes[index + 1] == 10 &&
        bytes[index + 2] == 13 &&
        bytes[index + 3] == 10) {
      return index + 4;
    }
  }
  throw StateError('Fixture response delimiter is missing.');
}

class _FakeRunner {
  _FakeRunner({Uint8List? output, this.result, this.onCall})
    : output = output ?? _defaultResponse;

  static final Uint8List _defaultResponse = _response(
    200,
    const {},
    Uint8List.fromList(utf8.encode('{}')),
  );

  final Uint8List output;
  final GhProcessResult? result;
  final void Function()? onCall;
  final calls = <_GhCall>[];

  Future<GhProcessResult> call(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    Uint8List? stdinBytes,
  }) async {
    onCall?.call();
    calls.add(
      _GhCall(
        executable,
        List.unmodifiable(arguments),
        Map.unmodifiable(environment),
        stdinBytes,
      ),
    );
    return result ?? GhProcessResult(0, output, Uint8List(0));
  }
}

class _GhCall {
  const _GhCall(
    this.executable,
    this.arguments,
    this.environment,
    this.stdinBytes,
  );

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final Uint8List? stdinBytes;
}
