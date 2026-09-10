import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gorouter_mcp/src/route_walker.dart';

Widget _stub(BuildContext context, GoRouterState state) =>
    const SizedBox.shrink();

void main() {
  group('walkRoutes', () {
    test('computes full paths for nested relative routes', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        GoRoute(
          path: '/city',
          builder: _stub,
          routes: <RouteBase>[
            GoRoute(
              path: 'events',
              builder: _stub,
              routes: <RouteBase>[GoRoute(path: 'archive', builder: _stub)],
            ),
          ],
        ),
      ]);

      expect(records.map((RouteRecord r) => r.fullPath), <String>[
        '/city',
        '/city/events',
        '/city/events/archive',
      ]);
    });

    test('keeps absolute child paths as-is', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        GoRoute(
          path: '/city',
          builder: _stub,
          routes: <RouteBase>[GoRoute(path: '/login', builder: _stub)],
        ),
      ]);

      expect(records.map((RouteRecord r) => r.fullPath), <String>[
        '/city',
        '/login',
      ]);
    });

    test('extracts path parameter names, including from ancestors', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        GoRoute(
          path: '/city/:citySlug',
          builder: _stub,
          routes: <RouteBase>[
            GoRoute(
              path: 'events/:eventId',
              name: 'city-event',
              builder: _stub,
            ),
          ],
        ),
      ]);

      expect(records.last.fullPath, '/city/:citySlug/events/:eventId');
      expect(records.last.pathParams, <String>['citySlug', 'eventId']);
      expect(records.last.name, 'city-event');
      expect(records.first.pathParams, <String>['citySlug']);
      expect(records.first.name, isNull);
    });

    test('descends through ShellRoute without contributing a path', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              child,
          routes: <RouteBase>[
            GoRoute(path: '/home', builder: _stub),
            GoRoute(path: '/settings', builder: _stub),
          ],
        ),
      ]);

      expect(records.map((RouteRecord r) => r.fullPath), <String>[
        '/home',
        '/settings',
      ]);
    });

    test('descends through nested ShellRoute under a GoRoute', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        GoRoute(
          path: '/city/:citySlug',
          builder: _stub,
          routes: <RouteBase>[
            ShellRoute(
              builder:
                  (BuildContext context, GoRouterState state, Widget child) =>
                      child,
              routes: <RouteBase>[GoRoute(path: 'events', builder: _stub)],
            ),
          ],
        ),
      ]);

      expect(records.map((RouteRecord r) => r.fullPath), <String>[
        '/city/:citySlug',
        '/city/:citySlug/events',
      ]);
      expect(records.last.pathParams, <String>['citySlug']);
    });

    test('descends through StatefulShellRoute branches', () {
      final List<RouteRecord> records = walkRoutes(<RouteBase>[
        StatefulShellRoute.indexedStack(
          builder:
              (
                BuildContext context,
                GoRouterState state,
                StatefulNavigationShell shell,
              ) => shell,
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              routes: <RouteBase>[GoRoute(path: '/feed', builder: _stub)],
            ),
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: '/profile',
                  builder: _stub,
                  routes: <RouteBase>[GoRoute(path: 'tickets', builder: _stub)],
                ),
              ],
            ),
          ],
        ),
      ]);

      expect(records.map((RouteRecord r) => r.fullPath), <String>[
        '/feed',
        '/profile',
        '/profile/tickets',
      ]);
    });

    test('walks a GoRouter instance', () {
      final GoRouter router = GoRouter(
        initialLocation: '/home',
        routes: <RouteBase>[
          GoRoute(path: '/home', name: 'home', builder: _stub),
        ],
      );

      final List<RouteRecord> records = walkRouter(router);
      expect(records.single.fullPath, '/home');
      expect(records.single.name, 'home');
      router.dispose();
    });
  });
}
