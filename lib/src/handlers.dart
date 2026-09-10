import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';

import 'protocol.dart';
import 'route_walker.dart';

/// An `extra` payload an agent can hand to a route that needs one.
///
/// [build] is called once per navigation, so a fixture may create fresh model
/// instances rather than sharing one across calls.
class McpFixture {
  const McpFixture(this.description, this.build, {this.name = 'default'});

  /// Human-readable summary, surfaced to the agent by `list_routes`.
  final String description;

  /// Builds the value passed as `extra`.
  final Object? Function() build;

  /// Fixture name, unique per route. Defaults to `default`.
  final String name;
}

/// Implementation of the three MCP operations against a [GoRouter].
///
/// Kept separate from the service extension plumbing so it can be driven
/// directly from widget tests.
class GoRouterMcpHandlers {
  GoRouterMcpHandlers(
    this.router, {
    this.fixtures = const <String, List<McpFixture>>{},
    this.safeRoutes = const <String>{},
    this.timeout = const Duration(seconds: 5),
    Future<void> Function()? settle,
  }) : _settle = settle ?? _awaitFrame;

  final GoRouter router;

  /// Fixtures per route, keyed by full path or route name.
  final Map<String, List<McpFixture>> fixtures;

  /// Routes the adapter declares navigable without `extra`, keyed by full path
  /// or route name.
  final Set<String> safeRoutes;

  /// How long [navigate] waits for the new page to settle before giving up.
  final Duration timeout;

  final Future<void> Function() _settle;

  List<RouteRecord> get _records => walkRouter(router);

  /// Lists every route in the router tree.
  Map<String, Object?> listRoutes() => <String, Object?>{
    'routes': _records
        .map(
          (RouteRecord r) => RouteInfo(
            fullPath: r.fullPath,
            name: r.name,
            pathParams: r.pathParams,
            extra: _extraRequirement(r),
            fixtures: _fixturesFor(r).map((McpFixture f) => f.name).toList(),
          ).toJson(),
        )
        .toList(),
  };

  /// Reports where the router currently is.
  Map<String, Object?> currentRoute() {
    final RouteMatchList matchList = router.routerDelegate.currentConfiguration;
    final RouteMatchList effective = _effective(matchList);
    final Map<GoRoute, String> paths = <GoRoute, String>{
      for (final RouteRecord r in _records) r.route: r.fullPath,
    };
    final List<RouteMatchInfo> matches = <RouteMatchInfo>[];
    void collect(List<RouteMatchBase> ms) {
      for (final RouteMatchBase m in ms) {
        if (m is ShellRouteMatch) {
          collect(m.matches);
        } else if (m is RouteMatch) {
          matches.add(
            RouteMatchInfo(
              matchedLocation: m.matchedLocation,
              name: m.route.name,
              path: paths[m.route] ?? m.route.path,
            ),
          );
          if (m is ImperativeRouteMatch) {
            collect(m.matches.matches);
          }
        }
      }
    }

    collect(matchList.matches);
    return CurrentRoute(
      location: effective.uri.toString(),
      name: effective.lastOrNull?.route.name,
      pathParams: effective.pathParameters,
      queryParams: effective.uri.queryParameters,
      matches: matches,
    ).toJson();
  }

  /// Navigates to a route, reporting a page that throws while building as an
  /// error rather than as a success.
  Future<Map<String, Object?>> navigate(Map<String, Object?> args) async {
    try {
      final NavigateRequest request = NavigateRequest.fromJson(args);
      return (await _navigate(request).timeout(
        timeout,
        onTimeout: () => NavigateResult.error(
          'Timed out after ${timeout.inSeconds}s waiting for '
          '"${request.target}" to settle.',
        ),
      )).toJson();
    } on FormatException catch (error) {
      return NavigateResult.error(error.message).toJson();
    }
  }

  Future<NavigateResult> _navigate(NavigateRequest request) async {
    if (request.mode == NavigateMode.pop) {
      if (!router.canPop()) {
        return const NavigateResult.error(
          'Cannot pop: the navigator has a single page.',
        );
      }
      return _run(() => router.pop());
    }

    final RouteRecord? record = _find(request.target);
    if (record == null) {
      return NavigateResult.error(
        'No route matches target "${request.target}". '
        'Call list_routes to see the available paths and names.',
      );
    }

    final String location;
    try {
      location = buildLocation(
        record.fullPath,
        pathParams: request.pathParams,
        queryParams: request.queryParams,
      );
    } on FormatException catch (error) {
      return NavigateResult.error(error.message);
    }

    final Object? extra;
    try {
      extra = _resolveExtra(record, request.fixture);
    } on FormatException catch (error) {
      return NavigateResult.error(error.message);
    }

    return _run(() {
      if (request.mode == NavigateMode.push) {
        // Deliberately not awaited: push's future completes when the pushed
        // page is popped.
        router.push<Object?>(location, extra: extra);
      } else {
        router.go(location, extra: extra);
      }
    });
  }

  /// Runs [action], then waits for a frame while capturing framework errors,
  /// so a page that throws during build surfaces as an error.
  Future<NavigateResult> _run(VoidCallback action) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? previousOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      action();
      await _settle();
    } catch (error) {
      return NavigateResult.error('$error');
    } finally {
      FlutterError.onError = previousOnError;
    }
    final String location = _effective(
      router.routerDelegate.currentConfiguration,
    ).uri.toString();
    if (errors.isNotEmpty) {
      return NavigateResult.error(
        errors.map((FlutterErrorDetails e) => e.exceptionAsString()).join('\n'),
        location: location,
      );
    }
    return NavigateResult.ok(location);
  }

  /// An imperative `push` leaves [RouteMatchList.uri] pointing at the location
  /// underneath the pushed page, so unwrap to the pushed match list.
  static RouteMatchList _effective(RouteMatchList matchList) {
    final RouteMatch? last = matchList.lastOrNull;
    return last is ImperativeRouteMatch ? _effective(last.matches) : matchList;
  }

  RouteRecord? _find(String target) {
    for (final RouteRecord record in _records) {
      if (record.fullPath == target || record.name == target) {
        return record;
      }
    }
    return null;
  }

  List<McpFixture> _fixturesFor(RouteRecord record) =>
      fixtures[record.fullPath] ??
      (record.name == null
          ? const <McpFixture>[]
          : fixtures[record.name!] ?? const <McpFixture>[]);

  ExtraRequirement _extraRequirement(RouteRecord record) {
    if (_fixturesFor(record).isNotEmpty) {
      return ExtraRequirement.fixture;
    }
    if (safeRoutes.contains(record.fullPath) ||
        (record.name != null && safeRoutes.contains(record.name))) {
      return ExtraRequirement.none;
    }
    return ExtraRequirement.unknown;
  }

  Object? _resolveExtra(RouteRecord record, String? requested) {
    final List<McpFixture> available = _fixturesFor(record);
    if (requested != null) {
      final McpFixture fixture = available.firstWhere(
        (McpFixture f) => f.name == requested,
        orElse: () => throw FormatException(
          'No fixture named "$requested" for "${record.fullPath}". '
          'Registered: ${available.isEmpty ? '(none)' : available.map((McpFixture f) => f.name).join(', ')}.',
        ),
      );
      return fixture.build();
    }
    if (available.isEmpty) {
      return null;
    }
    if (available.length > 1) {
      throw FormatException(
        '"${record.fullPath}" has ${available.length} fixtures; pass one of: '
        '${available.map((McpFixture f) => f.name).join(', ')}.',
      );
    }
    return available.single.build();
  }
}

Future<void> _awaitFrame() {
  final Completer<void> completer = Completer<void>();
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  });
  SchedulerBinding.instance.scheduleFrame();
  return completer.future;
}
