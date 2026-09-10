import 'package:go_router/go_router.dart';

/// A single [GoRoute] found in a router tree, with its position resolved.
class RouteRecord {
  RouteRecord({
    required this.route,
    required this.fullPath,
    required this.pathParams,
  });

  /// The route declaration this record was computed from.
  final GoRoute route;

  /// [route]'s path with every ancestor path prepended.
  final String fullPath;

  /// Path parameter names appearing in [fullPath], in order.
  final List<String> pathParams;

  String? get name => route.name;
}

final RegExp _pathParamPattern = RegExp(r':(\w+)');

/// Walks [router]'s route tree, returning one record per [GoRoute].
List<RouteRecord> walkRouter(GoRouter router) =>
    walkRoutes(router.configuration.routes);

/// Walks [routes] depth-first, returning one record per [GoRoute].
///
/// [ShellRoute] and [StatefulShellRoute] contribute no path of their own; the
/// walker descends into them carrying the enclosing prefix.
List<RouteRecord> walkRoutes(List<RouteBase> routes) {
  final List<RouteRecord> records = <RouteRecord>[];
  _walk(routes, '', records);
  return records;
}

void _walk(List<RouteBase> routes, String prefix, List<RouteRecord> out) {
  for (final RouteBase route in routes) {
    if (route is GoRoute) {
      final String fullPath = _join(prefix, route.path);
      out.add(
        RouteRecord(
          route: route,
          fullPath: fullPath,
          pathParams: _pathParamPattern
              .allMatches(fullPath)
              .map((RegExpMatch m) => m.group(1)!)
              .toList(),
        ),
      );
      _walk(route.routes, fullPath, out);
    } else if (route is StatefulShellRoute) {
      for (final StatefulShellBranch branch in route.branches) {
        _walk(branch.routes, prefix, out);
      }
    } else {
      _walk(route.routes, prefix, out);
    }
  }
}

/// Concatenates a parent path and a child path the way GoRouter matches them:
/// a child path starting with `/` is absolute and replaces the prefix.
String _join(String prefix, String path) {
  if (path.startsWith('/')) {
    return path;
  }
  if (prefix.isEmpty) {
    return '/$path';
  }
  return prefix.endsWith('/') ? '$prefix$path' : '$prefix/$path';
}

/// Substitutes [pathParams] and [queryParams] into a route's [fullPath],
/// producing a concrete location.
///
/// Throws [FormatException] when a parameter appearing in [fullPath] has no
/// value.
String buildLocation(
  String fullPath, {
  Map<String, String> pathParams = const <String, String>{},
  Map<String, String> queryParams = const <String, String>{},
}) {
  final List<String> missing = <String>[];
  final String path = fullPath.replaceAllMapped(_pathParamPattern, (Match m) {
    final String key = m.group(1)!;
    final String? value = pathParams[key];
    if (value == null) {
      missing.add(key);
      return m.group(0)!;
    }
    return Uri.encodeComponent(value);
  });
  if (missing.isNotEmpty) {
    throw FormatException(
      'Missing path parameter(s): ${missing.join(', ')} for "$fullPath".',
    );
  }
  if (queryParams.isEmpty) {
    return path;
  }
  return Uri(path: path, queryParameters: queryParams).toString();
}
