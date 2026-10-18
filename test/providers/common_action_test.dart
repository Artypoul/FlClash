import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flashco/common/request.dart';
import 'package:flashco/core/controller.dart';
import 'package:flashco/core/interface.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/action.dart';
import 'package:flashco/providers/app.dart';
import 'package:flashco/providers/config.dart';
import 'package:flashco/providers/core.dart';
import 'package:flashco/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

const runningVersion = '0.8.96';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockCoreHandlerInterface core;
  late HttpClientAdapter originalRequestAdapter;

  setUpAll(() {
    core = MockCoreHandlerInterface();
    globalState.packageInfo = PackageInfo(
      appName: 'Flashco',
      packageName: 'com.follow.flashco',
      version: runningVersion,
      buildNumber: '1',
    );
  });

  setUp(() {
    reset(core);
    originalRequestAdapter = request.dio.httpClientAdapter;
  });

  tearDown(() {
    request.dio.httpClientAdapter = originalRequestAdapter;
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('CommonAction.updateMode', () {
    test('advances through every mode and wraps back to the first', () {
      final container = buildContainer();
      final action = container.read(commonActionProvider.notifier);
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: Mode.values.first));

      final seen = <Mode>[container.read(patchClashConfigProvider).mode];
      for (var i = 0; i < Mode.values.length; i++) {
        action.updateMode();
        seen.add(container.read(patchClashConfigProvider).mode);
      }

      expect(seen.sublist(0, Mode.values.length), Mode.values);
      expect(seen.last, Mode.values.first, reason: 'wraps after the last mode');
    });
  });

  group('CommonAction.updateSpeedStatistics', () {
    test('toggles the tray title flag both ways', () {
      final container = buildContainer();
      final action = container.read(commonActionProvider.notifier);
      final initial = container.read(appSettingProvider).showTrayTitle;

      action.updateSpeedStatistics();
      expect(container.read(appSettingProvider).showTrayTitle, !initial);

      action.updateSpeedStatistics();
      expect(container.read(appSettingProvider).showTrayTitle, initial);
    });
  });

  group('CommonAction.updateTraffic', () {
    test('records the sampled traffic and the running total', () async {
      final container = buildContainer();
      container
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(onlyStatisticsProxy: true));
      when(
        () => core.getTraffic(true),
      ).thenAnswer((_) async => const Traffic(up: 10, down: 20));
      when(
        () => core.getTotalTraffic(true),
      ).thenAnswer((_) async => const Traffic(up: 100, down: 200));

      await container.read(commonActionProvider.notifier).updateTraffic();

      expect(container.read(trafficsProvider).list.last.up, 10);
      expect(container.read(trafficsProvider).list.last.down, 20);
      expect(
        container.read(totalTrafficProvider),
        const Traffic(up: 100, down: 200),
      );
      verify(() => core.getTraffic(true)).called(1);
      verify(() => core.getTotalTraffic(true)).called(1);
    });

    test('swallows a core failure and leaves the total untouched', () async {
      final container = buildContainer();
      final before = container.read(totalTrafficProvider);
      when(() => core.getTraffic(any())).thenThrow(StateError('core down'));

      await expectLater(
        container.read(commonActionProvider.notifier).updateTraffic(),
        completes,
      );
      expect(container.read(totalTrafficProvider), before);
    });

    test('does not record a total when only the total call fails', () async {
      final container = buildContainer();
      final before = container.read(totalTrafficProvider);
      when(
        () => core.getTraffic(any()),
      ).thenAnswer((_) async => const Traffic(up: 1, down: 2));
      when(() => core.getTotalTraffic(any())).thenThrow(StateError('boom'));

      await container.read(commonActionProvider.notifier).updateTraffic();

      expect(container.read(trafficsProvider).list.last.up, 1);
      expect(container.read(totalTrafficProvider), before);
    });

    test(
      'drops concurrent in-flight updates while one is in progress',
      () async {
        final container = buildContainer();
        final completer = Completer<Traffic>();
        when(() => core.getTraffic(any())).thenAnswer((_) => completer.future);
        when(
          () => core.getTotalTraffic(any()),
        ).thenAnswer((_) => completer.future);

        final first = container
            .read(commonActionProvider.notifier)
            .updateTraffic();
        final second = container
            .read(commonActionProvider.notifier)
            .updateTraffic();

        await expectLater(second, completes);
        completer.complete(const Traffic(up: 5, down: 10));
        await first;

        verify(() => core.getTraffic(any())).called(1);
        verify(() => core.getTotalTraffic(any())).called(1);
      },
    );
  });

  group('CommonAction.autoCheckUpdate', () {
    test('returns without a network call when the setting is off', () async {
      final container = buildContainer();
      final adapter = _UpdateAdapter((_) async => _releaseResponse('v0.8.96'));
      request.dio.httpClientAdapter = adapter;
      container
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(autoCheckUpdate: false));

      await expectLater(
        container.read(commonActionProvider.notifier).autoCheckUpdate(),
        completion(isFalse),
      );
      expect(adapter.calls, 0);
    });

    test('checks the current release once when enabled', () async {
      final container = buildContainer();
      final adapter = _UpdateAdapter(
        (_) async => _releaseResponse(runningVersion),
      );
      request.dio.httpClientAdapter = adapter;

      await expectLater(
        container.read(commonActionProvider.notifier).autoCheckUpdate(),
        completion(isFalse),
      );
      expect(adapter.calls, 1);
    });

    test('a delayed check does not block unrelated provider updates', () async {
      final container = buildContainer();
      final response = Completer<ResponseBody>();
      final adapter = _UpdateAdapter((_) => response.future);
      request.dio.httpClientAdapter = adapter;

      final pending = container
          .read(commonActionProvider.notifier)
          .autoCheckUpdate();
      await adapter.dispatched.future;

      expect(adapter.calls, 1);
      final before = container.read(appSettingProvider).showTrayTitle;
      container.read(commonActionProvider.notifier).updateSpeedStatistics();
      expect(container.read(appSettingProvider).showTrayTitle, !before);

      response.complete(_releaseResponse(runningVersion));
      await expectLater(pending, completion(isFalse));
    });
  });
}

class _UpdateAdapter implements HttpClientAdapter {
  _UpdateAdapter(this.respond);

  final Future<ResponseBody> Function(RequestOptions options) respond;
  final dispatched = Completer<void>();
  var calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls++;
    if (!dispatched.isCompleted) dispatched.complete();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

Future<ResponseBody> _releaseResponse(String tag) async =>
    ResponseBody.fromString(
      '{"tag_name":"v$tag","body":"notes"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
