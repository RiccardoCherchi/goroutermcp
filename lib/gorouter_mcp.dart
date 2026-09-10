/// Exposes a running app's [GoRouter] to an AI agent over the Dart VM Service.
///
/// Call [GoRouterMcp.attach] once, right after the router is built. Outside
/// debug builds it does nothing.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'src/handlers.dart';
import 'src/protocol.dart';

export 'src/handlers.dart' show GoRouterMcpHandlers, McpFixture;
export 'src/protocol.dart'
    show CurrentRoute, ExtraRequirement, NavigateMode, RouteInfo;

/// Registers the `ext.gorouter_mcp.*` VM service extensions.
abstract final class GoRouterMcp {
  static GoRouterMcpHandlers? _handlers;
  static bool _registered = false;

  /// The handlers currently serving the service extensions, if attached.
  @visibleForTesting
  static GoRouterMcpHandlers? get handlers => _handlers;

  /// Attaches [router] to the VM service extensions used by the MCP server.
  ///
  /// Does nothing outside [kDebugMode]. Calling it again — as happens on hot
  /// restart — rebinds the extensions to the new [router].
  static void attach(
    GoRouter router, {
    Map<String, List<McpFixture>> fixtures = const <String, List<McpFixture>>{},
    Set<String> safeRoutes = const <String>{},
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (!kDebugMode) {
      return;
    }
    _handlers = GoRouterMcpHandlers(
      router,
      fixtures: fixtures,
      safeRoutes: safeRoutes,
      timeout: timeout,
    );
    if (_registered) {
      return;
    }
    _registered = true;
    _register(kListRoutesMethod, (_) async => _handlers!.listRoutes());
    _register(kCurrentRouteMethod, (_) async => _handlers!.currentRoute());
    _register(
      kNavigateMethod,
      (Map<String, String> parameters) =>
          _handlers!.navigate(_decodeArgs(parameters)),
    );
  }

  static void _register(
    String method,
    Future<Map<String, Object?>> Function(Map<String, String>) handler,
  ) {
    developer.registerExtension(method, (
      String method,
      Map<String, String> parameters,
    ) async {
      try {
        final Map<String, Object?> result = await handler(parameters);
        return developer.ServiceExtensionResponse.result(
          jsonEncode(<String, Object?>{'type': 'gorouter_mcp', ...result}),
        );
      } catch (error, stack) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          jsonEncode(<String, Object?>{'error': '$error', 'stack': '$stack'}),
        );
      }
    });
  }

  static Map<String, Object?> _decodeArgs(Map<String, String> parameters) {
    final String? raw = parameters[kArgsParam];
    if (raw == null || raw.isEmpty) {
      return <String, Object?>{};
    }
    return (jsonDecode(raw) as Map<Object?, Object?>).cast<String, Object?>();
  }
}
