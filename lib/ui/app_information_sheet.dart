import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/tunnel_diagnostics.dart';
import 'tunnel_diagnostics_card.dart';

/// Information opened explicitly from the app bar. The parent supplies current
/// snapshots and already-sanitized messages; this view never reads private data.
class AppInformationSheet extends StatelessWidget {
  const AppInformationSheet({
    super.key,
    required this.isAndroid,
    required this.diagnostics,
    required this.refreshing,
    required this.stale,
    required this.onClose,
    required this.version,
    this.onRefresh,
    this.connectionError,
    this.lastErrorCode,
  });

  final bool isAndroid;
  final TunnelDiagnostics diagnostics;
  final bool refreshing;
  final bool stale;
  final VoidCallback onClose;
  final VoidCallback? onRefresh;
  final String? connectionError;
  final String? lastErrorCode;
  final String version;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    key: const Key('app_information_sheet'),
    heightFactor: .9,
    widthFactor: 1,
    child: SafeArea(
      top: false,
      child: Column(children: [
        // Closing remains reachable independently of content height/text scale.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Expanded(child: Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('Информация',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            )),
            IconButton(
              key: const Key('close_app_information'),
              tooltip: 'Закрыть информацию',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(
          key: const Key('app_information_content'),
          padding: const EdgeInsets.all(14),
          children: [
            const Text('Pushok Flow',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Версия $version', key: const Key('app_information_version'),
              style: const TextStyle(color: PushokPalette.muted)),
            if (connectionError != null || lastErrorCode != null) ...[
              const SizedBox(height: 14),
              PushokPanel(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Последняя ошибка',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                  if (connectionError != null) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(liveRegion: true,
                      child: Text(connectionError!,
                        key: const Key('connection_error'),
                        style: const TextStyle(color: PushokPalette.orange))),
                  ),
                  if (lastErrorCode != null) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Код диагностики: $lastErrorCode',
                      key: const Key('diagnostic_error_code'),
                      style: const TextStyle(color: PushokPalette.muted)),
                  ),
                ],
              )),
            ],
            const SizedBox(height: 14),
            if (isAndroid) TunnelDiagnosticsCard(
              diagnostics: diagnostics,
              refreshing: refreshing,
              stale: stale,
              onRefresh: onRefresh,
            ) else const PushokPanel(
              child: Text('Диагностика связи доступна в приложении для Android.'),
            ),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: TextButton(
              key: const Key('app_information_licenses'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Pushok Flow',
                applicationVersion: version,
              ),
              child: const Text('Лицензии компонентов'),
            )),
          ],
        )),
      ]),
    ),
  );
}
