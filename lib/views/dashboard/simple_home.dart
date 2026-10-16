import 'package:flashco/common/common.dart';
import 'package:flashco/core/core.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/icons/icons.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/providers.dart';
import 'package:flashco/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'dashboard.dart';
import 'widgets/core_status_button.dart';
import '../profiles/add.dart';

class SimpleHomeView extends ConsumerWidget {
  const SimpleHomeView({super.key});

  List<CommonPopupMenuItem> _menuItems(BuildContext context, WidgetRef ref) {
    final currentItems = ref.read(currentNavigationItemsStateProvider).value;
    return [
      CommonPopupMenuItem(
        label: context.appLocalizations.controlPanel,
        glyph: AppGlyphs.dashboard,
        onPressed: () =>
            showExtend(context, builder: (_) => const DashboardView()),
      ),
      for (final item in ref.watch(navigationItemsStateProvider).value)
        if (item.label != PageLabel.dashboard && item.modes.isNotEmpty)
          CommonPopupMenuItem(
            label: item.label.label,
            glyph: item.glyph,
            onPressed: () {
              if (currentItems.any((current) => current.label == item.label)) {
                ref.read(currentPageLabelProvider.notifier).toPage(item.label);
              } else {
                showExtend(
                  context,
                  props: ExtendProps(
                    forceFull: item.modes.contains(NavigationItemMode.moreFull),
                  ),
                  builder: item.builder,
                );
              }
            },
          ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = context.appLocalizations;
    final profile = ref.watch(currentProfileProvider);
    final coreStatus = ref.watch(coreStatusProvider);
    final running = ref.watch(isStartProvider);
    final hasProfiles = ref.watch(
      profilesProvider.select((profiles) => profiles.isNotEmpty),
    );
    final suspended = ref.watch(suspendProvider);
    final scheme = context.colorScheme;
    final connected = coreStatus == CoreStatus.connected && running;
    final status = switch (coreStatus) {
      CoreStatus.connecting => labels.connecting,
      CoreStatus.disconnected => labels.disconnected,
      CoreStatus.connected =>
        running
            ? (suspended ? labels.suspended : labels.connected)
            : labels.disconnected,
    };
    final canToggle = hasProfiles || running;
    return CommonScaffold(
      title: appName,
      actions: [
        if (coreLib == null && coreStatus != CoreStatus.connected)
          const CoreStatusButton(),
      ],
      menuItems: _menuItems(context, ref),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final padding = EdgeInsets.fromLTRB(
            24,
            context.contentTopPadding,
            24,
            24 + BottomInsetScope.of(context),
          );
          return SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - padding.vertical).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox.square(
                        dimension: 112,
                        child: Semantics(
                          toggled: running,
                          child: ElasticButton(
                            enabled: canToggle,
                            child: IconButton.filledTonal(
                              tooltip: running ? labels.stop : labels.launch,
                              style: IconButton.styleFrom(
                                backgroundColor: running
                                    ? scheme.primaryContainer
                                    : Color.alphaBlend(
                                        scheme.primaryContainer.withValues(
                                          alpha: 0.24,
                                        ),
                                        scheme.surface,
                                      ),
                                foregroundColor: running
                                    ? scheme.onPrimaryContainer
                                    : scheme.primary,
                                shape: AppShape.xxl,
                              ),
                              onPressed: canToggle
                                  ? ref
                                        .read(commonActionProvider.notifier)
                                        .toggleRunning
                                  : null,
                              icon: const GlyphIcon(
                                AppGlyphs.power,
                                size: 64,
                                fill: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: connected && !suspended
                                  ? scheme.primary
                                  : scheme.outline,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: 8),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              status,
                              textAlign: TextAlign.center,
                              style: context.textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (profile != null) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const GlyphIcon(AppGlyphs.layers, size: 22),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                profile.realLabel,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                      TextButton.icon(
                        onPressed: () => showAddProfilePage(context),
                        icon: const GlyphIcon(AppGlyphs.add, size: 20),
                        label: Text(
                          labels.addConfiguration,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
