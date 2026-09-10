/// Wire protocol shared by the app-side library and the MCP server.
///
/// This library is pure Dart on purpose: it is imported both by
/// `lib/gorouter_mcp.dart` (which runs inside the Flutter app) and by
/// `bin/server.dart` (which runs as a standalone CLI).
library;

/// Prefix of every VM service extension registered by this package.
const String kExtensionPrefix = 'ext.gorouter_mcp.';

/// Service extension that lists every route in the router tree.
const String kListRoutesMethod = '${kExtensionPrefix}listRoutes';

/// Service extension that reports the currently displayed route.
const String kCurrentRouteMethod = '${kExtensionPrefix}currentRoute';

/// Service extension that performs a navigation.
const String kNavigateMethod = '${kExtensionPrefix}navigate';

/// Every service extension takes its payload as a single JSON-encoded
/// parameter, because VM service extension parameters are string-valued.
const String kArgsParam = 'args';

/// How a route relates to `GoRouterState.extra`.
enum ExtraRequirement {
  /// The route builder does not read `state.extra`; safe to navigate.
  none,

  /// The route needs `extra` and at least one fixture is registered.
  fixture,

  /// The route may need `extra` and nothing is registered. Navigating may
  /// throw while building the page.
  unknown;

  String get wireName => name;

  static ExtraRequirement fromWire(String value) => values.firstWhere(
    (ExtraRequirement e) => e.wireName == value,
    orElse: () => ExtraRequirement.unknown,
  );
}

/// How to perform a navigation.
enum NavigateMode {
  go,
  push,
  pop;

  String get wireName => name;

  static NavigateMode? fromWire(String? value) {
    if (value == null) {
      return NavigateMode.go;
    }
    for (final NavigateMode mode in values) {
      if (mode.wireName == value) {
        return mode;
      }
    }
    return null;
  }
}

/// One record per route in the tree, as returned by `listRoutes`.
class RouteInfo {
  const RouteInfo({
    required this.fullPath,
    this.name,
    this.pathParams = const <String>[],
    this.extra = ExtraRequirement.unknown,
    this.fixtures = const <String>[],
  });

  factory RouteInfo.fromJson(Map<String, Object?> json) => RouteInfo(
    fullPath: json['fullPath'] as String,
    name: json['name'] as String?,
    pathParams: (json['pathParams'] as List<Object?>? ?? const <Object?>[])
        .cast<String>(),
    extra: ExtraRequirement.fromWire(json['extra'] as String? ?? 'unknown'),
    fixtures: (json['fixtures'] as List<Object?>? ?? const <Object?>[])
        .cast<String>(),
  );

  /// Path of the route with every ancestor path prepended, e.g.
  /// `/city/:citySlug/events`.
  final String fullPath;

  /// The route's `name:`, when it declares one.
  final String? name;

  /// Names of the path parameters appearing in [fullPath].
  final List<String> pathParams;

  /// Whether this route needs `extra` to build.
  final ExtraRequirement extra;

  /// Names of the fixtures registered for this route.
  final List<String> fixtures;

  Map<String, Object?> toJson() => <String, Object?>{
    'fullPath': fullPath,
    'name': name,
    'pathParams': pathParams,
    'extra': extra.wireName,
    'fixtures': fixtures,
  };
}

/// One entry of the current route match stack.
class RouteMatchInfo {
  const RouteMatchInfo({required this.matchedLocation, this.name, this.path});

  factory RouteMatchInfo.fromJson(Map<String, Object?> json) => RouteMatchInfo(
    matchedLocation: json['matchedLocation'] as String,
    name: json['name'] as String?,
    path: json['path'] as String?,
  );

  final String matchedLocation;
  final String? name;
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
    'matchedLocation': matchedLocation,
    'name': name,
    'path': path,
  };
}

/// Result of `currentRoute`.
class CurrentRoute {
  const CurrentRoute({
    required this.location,
    this.name,
    this.pathParams = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.matches = const <RouteMatchInfo>[],
  });

  factory CurrentRoute.fromJson(Map<String, Object?> json) => CurrentRoute(
    location: json['location'] as String,
    name: json['name'] as String?,
    pathParams:
        (json['pathParams'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, String>(),
    queryParams:
        (json['queryParams'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, String>(),
    matches: (json['matches'] as List<Object?>? ?? const <Object?>[])
        .map(
          (Object? e) => RouteMatchInfo.fromJson(
            (e! as Map<Object?, Object?>).cast<String, Object?>(),
          ),
        )
        .toList(),
  );

  final String location;
  final String? name;
  final Map<String, String> pathParams;
  final Map<String, String> queryParams;
  final List<RouteMatchInfo> matches;

  Map<String, Object?> toJson() => <String, Object?>{
    'location': location,
    'name': name,
    'pathParams': pathParams,
    'queryParams': queryParams,
    'matches': matches.map((RouteMatchInfo m) => m.toJson()).toList(),
  };
}

/// Arguments of `navigate`.
class NavigateRequest {
  const NavigateRequest({
    required this.target,
    this.mode = NavigateMode.go,
    this.pathParams = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.fixture,
  });

  /// Parses [json], throwing [FormatException] on malformed input.
  factory NavigateRequest.fromJson(Map<String, Object?> json) {
    final NavigateMode? mode = NavigateMode.fromWire(json['mode'] as String?);
    if (mode == null) {
      throw FormatException(
        'Unknown mode "${json['mode']}". '
        'Expected one of: ${NavigateMode.values.map((NavigateMode m) => m.wireName).join(', ')}.',
      );
    }
    final Object? target = json['target'];
    if (mode != NavigateMode.pop && (target is! String || target.isEmpty)) {
      throw const FormatException('"target" is required unless mode is "pop".');
    }
    return NavigateRequest(
      target: target is String ? target : '',
      mode: mode,
      pathParams: _stringMap(json['pathParams']),
      queryParams: _stringMap(json['queryParams']),
      fixture: json['fixture'] as String?,
    );
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value == null) {
      return const <String, String>{};
    }
    if (value is! Map<Object?, Object?>) {
      throw FormatException('Expected an object, got: $value');
    }
    return value.map(
      (Object? k, Object? v) =>
          MapEntry<String, String>(k.toString(), v.toString()),
    );
  }

  /// A full path or a route name.
  final String target;
  final NavigateMode mode;
  final Map<String, String> pathParams;
  final Map<String, String> queryParams;
  final String? fixture;

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target,
    'mode': mode.wireName,
    'pathParams': pathParams,
    'queryParams': queryParams,
    'fixture': fixture,
  };
}

/// Result of `navigate`.
class NavigateResult {
  const NavigateResult.ok(this.location) : ok = true, error = null;

  const NavigateResult.error(this.error, {this.location}) : ok = false;

  factory NavigateResult.fromJson(Map<String, Object?> json) =>
      json['ok'] == true
      ? NavigateResult.ok(json['location'] as String? ?? '')
      : NavigateResult.error(
          json['error'] as String? ?? 'unknown error',
          location: json['location'] as String?,
        );

  final bool ok;
  final String? location;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    if (location != null) 'location': location,
    if (error != null) 'error': error,
  };
}
