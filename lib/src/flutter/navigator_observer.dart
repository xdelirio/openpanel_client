import 'package:flutter/widgets.dart';
import 'package:openpanel_client/src/client.dart';

/// The path a route is reported under, or null to leave it out.
typedef ScreenNamer = String? Function(Route<dynamic> route);

/// Reports a `screen_view` whenever the visible route changes.
///
/// By default a route is reported by its `settings.name` (go_router sets the
/// path pattern there, e.g. `/content/:id`, which groups every title under
/// one screen), and unnamed routes — dialogs, sheets, menus — are skipped.
/// Pass [nameOf] to report something else or to skip more.
class OpenPanelObserver extends NavigatorObserver {
  OpenPanelObserver(this.client, {ScreenNamer? nameOf})
    : _nameOf = nameOf ?? _byName;

  final OpenPanel client;
  final ScreenNamer _nameOf;

  static String? _byName(Route<dynamic> route) {
    final name = route.settings.name;
    return name == null || name.isEmpty ? null : name;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _report(newRoute);
  }

  /// Back on [previousRoute]: it is on screen again — unless what closed
  /// was a popup, which never left it.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute || previousRoute == null) return;
    _report(previousRoute);
  }

  void _report(Route<dynamic> route) {
    // A popup (dialog, sheet) leaves the page under it in view; it is not a
    // screen of its own.
    if (route is PopupRoute) return;
    final path = _nameOf(route);
    if (path != null) client.screen(path);
  }
}
