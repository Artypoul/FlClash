import 'package:flashco/common/common.dart';
import 'package:flashco/core/controller.dart';
import 'package:flashco/core/interface.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/icons/icons.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/providers.dart';
import 'package:flashco/state.dart';
import 'package:flashco/views/dashboard/simple_home.dart';
import 'package:flashco/widgets/widgets.dart';
import 'package:flashco/views/navigation.dart';
import 'package:flashco/views/profiles/add.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/glyph_finders.dart';
import '../../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

const _nodeA = Proxy(name: 'Node A', type: 'Vless');
const _nodeB = Proxy(name: 'Node B', type: 'Vless');
const _groups = [
  Group(
    name: 'PROXY',
    type: GroupType.Selector,
    hidden: false,
    now: 'Node A',
    all: [
      Proxy(name: 'Fastest', type: 'URLTest'),
      _nodeA,
      _nodeB,
    ],
  ),
  Group(
    name: 'Fastest',
    type: GroupType.URLTest,
    now: 'Node B',
    all: [_nodeA, _nodeB],
  ),
];

void main() {
  late ProviderContainer container;
  late _MockCore core;
  var excludedWifi = false;

  setUpAll(() {
    registerFallbackValue(
      const ChangeProxyParams(groupName: '', proxyName: ''),
    );
  });

  setUp(() {
    excludedWifi = false;
    navigationPort = navigation;
    addTearDown(() => navigationPort = null);
    core = _MockCore();
    when(
      () => core.changeProxy(any()),
    ).thenAnswer((_) async => const ChangeProxyResult());
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        suspendProvider.overrideWith((_) => excludedWifi),
        profilesProvider.overrideWith(
          () => TestProfiles([
            const Profile(
              id: 1,
              label: 'My config',
              autoUpdateDuration: Duration.zero,
            ),
          ]),
        ),
      ],
    );
    globalState.container = container;
    container.listen(currentProfileIdProvider, (_, _) {});
    container.read(currentProfileIdProvider.notifier).value = 1;
    container.read(groupsProvider.notifier).value = _groups;
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    addTearDown(container.dispose);
  });

  Future<void> pumpHome(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: const Locale('en'),
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: Consumer(
              builder: (_, ref, _) => Theme(
                data: ThemeData(
                  colorScheme: ref.watch(
                    genColorSchemeProvider(
                      ref.watch(currentBrightnessProvider),
                    ),
                  ),
                ).withAppShapes,
                child: Builder(builder: navigation.getItems().first.builder),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('home provides one prominent launch and configuration import', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.byType(SimpleHomeView), findsOneWidget);
    expect(find.byType(CommonFloatingActionButton), findsOneWidget);
    expect(find.text('Launch'), findsOneWidget);
    expect(find.text('Add configuration'), findsOneWidget);
    expect(find.text('My config'), findsOneWidget);
    expect(
      tester.getSize(find.byType(FloatingActionButton)).width,
      greaterThan(300),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Fastest toggles the existing selector and restores manual pick',
    (tester) async {
      await pumpHome(tester);
      expect(
        tester.widget<CommonCheckBox>(find.byType(CommonCheckBox)).value,
        isFalse,
      );
      await tester.tap(find.byType(CommonCheckBox));
      await tester.pump();
      expect(
        container.read(currentProfileProvider)!.selectedMap['PROXY'],
        'Fastest',
      );
      await tester.tap(find.byType(CommonCheckBox));
      await tester.pump();
      expect(
        container.read(currentProfileProvider)!.selectedMap['PROXY'],
        'Node A',
      );
    },
  );

  testWidgets(
    'saved Fastest choice is reflected and can hold its current node',
    (tester) async {
      container
          .read(profilesProvider.notifier)
          .put(
            const Profile(
              id: 1,
              label: 'My config',
              autoUpdateDuration: Duration.zero,
              selectedMap: {'PROXY': 'Fastest'},
            ),
          );
      await pumpHome(tester);
      expect(
        tester.widget<CommonCheckBox>(find.byType(CommonCheckBox)).value,
        isTrue,
      );
      await tester.tap(find.byType(CommonCheckBox));
      await tester.pump();
      expect(
        container.read(currentProfileProvider)!.selectedMap['PROXY'],
        'Node B',
      );
    },
  );

  testWidgets('failed selection rolls back the checkbox and releases it', (
    tester,
  ) async {
    when(() => core.changeProxy(any())).thenThrow(Exception('offline'));
    await pumpHome(tester);
    await tester.tap(find.byType(CommonCheckBox));
    await tester.pump();
    final checkbox = tester.widget<CommonCheckBox>(find.byType(CommonCheckBox));
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty configuration keeps import and disables launch', (
    tester,
  ) async {
    (container.read(profilesProvider.notifier) as TestProfiles).replace([]);
    await pumpHome(tester);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    expect(find.text('Add configuration'), findsOneWidget);
    expect(
      tester.widget<CommonCheckBox>(find.byType(CommonCheckBox)).onChanged,
      isNull,
    );
  });

  testWidgets('unavailable Core or missing Fastest disables the checkbox', (
    tester,
  ) async {
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await pumpHome(tester);
    expect(
      tester.widget<CommonCheckBox>(find.byType(CommonCheckBox)).onChanged,
      isNull,
    );
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    container.read(groupsProvider.notifier).value = [];
    await tester.pump();
    expect(
      tester.widget<CommonCheckBox>(find.byType(CommonCheckBox)).onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen with large text scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHome(tester, scale: 2);
    await tester.ensureVisible(find.byType(CommonCheckBox));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Core failure cannot leave the home status connected', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1000;
    await pumpHome(tester);
    expect(find.text('Connected'), findsOneWidget);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await tester.pump();
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Disconnected'), findsWidgets);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('disabling Fastest restores a manual entry outside its nodes', (
    tester,
  ) async {
    container.read(groupsProvider.notifier).value = [
      _groups.first.copyWith(
        now: 'Manual group',
        all: [
          ..._groups.first.all,
          const Proxy(name: 'Manual group', type: 'Selector'),
        ],
      ),
      _groups.last,
    ];
    await pumpHome(tester);
    await tester.tap(find.byType(CommonCheckBox));
    await tester.pump();
    await tester.tap(find.byType(CommonCheckBox));
    await tester.pump();
    expect(
      container.read(currentProfileProvider)!.selectedMap['PROXY'],
      'Manual group',
    );
  });

  testWidgets('configuration action opens the existing import screen', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Add configuration'));
    await tester.pumpAndSettle();
    expect(find.byType(AddProfileView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all controls inherit the application theme in light and dark', (
    tester,
  ) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      container
          .read(themeSettingProvider.notifier)
          .update(
            (settings) =>
                settings.copyWith(themeMode: mode, primaryColor: 0xff267b52),
          );
      await pumpHome(tester);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(CommonFloatingActionButton));
      final scheme = container.read(
        genColorSchemeProvider(
          mode == ThemeMode.light ? Brightness.light : Brightness.dark,
        ),
      );
      expect(Theme.of(context).colorScheme, scheme);
      final surface = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(surface.color, scheme.primaryContainer);
      expect(surface.shape, AppShape.md);
      expect(find.byType(CommonCheckBox), findsOneWidget);
      expect(find.byType(ListItem<dynamic>), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('stopped launch keeps its play icon on excluded Wi-Fi', (
    tester,
  ) async {
    excludedWifi = true;
    await pumpHome(tester);
    expect(find.text('Launch'), findsOneWidget);
    expect(find.byGlyph(AppGlyphs.wifiOff), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu preserves advanced navigation and the control panel', (
    tester,
  ) async {
    container.listen(currentPageLabelProvider, (_, _) {});
    await pumpHome(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Control panel'), findsOneWidget);
    expect(find.text(PageLabel.profiles.label), findsOneWidget);
    expect(find.text(PageLabel.proxies.label), findsOneWidget);
    await tester.tap(find.text(PageLabel.tools.label));
    await tester.pumpAndSettle();
    expect(container.read(currentPageLabelProvider), PageLabel.tools);
    expect(tester.takeException(), isNull);
  });
}
