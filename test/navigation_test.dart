import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gorouter_mcp/gorouter_mcp.dart';
import 'package:gorouter_mcp/src/protocol.dart';

Widget _text(String label) => Scaffold(body: Text(label));

GoRouter _buildRouter() => GoRouter(
  initialLocation: '/home',
  routes: <RouteBase>[
    GoRoute(path: '/home', name: 'home', builder: (_, __) => _text('home')),
    GoRoute(
      path: '/city/:citySlug/events',
      name: 'city-events',
      builder: (BuildContext context, GoRouterState state) =>
          _text('events ${state.pathParameters['citySlug']}'),
    ),
    GoRoute(
      path: '/event-listing',
      name: 'event-listing',
      builder: (BuildContext context, GoRouterState state) {
        final Map<String, Object?> extra = state.extra! as Map<String, Object?>;
        return _text('listing ${extra['event']}');
      },
    ),
  ],
);

void main() {
  late GoRouter router;
  late GoRouterMcpHandlers handlers;

  Future<void> pumpApp(
    WidgetTester tester, {
    Map<String, List<McpFixture>> fixtures = const {},
    Set<String> safeRoutes = const <String>{},
  }) async {
    router = _buildRouter();
    handlers = GoRouterMcpHandlers(
      router,
      fixtures: fixtures,
      safeRoutes: safeRoutes,
      settle: () => tester.pumpAndSettle(),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    addTearDown(router.dispose);
  }

  group('listRoutes', () {
    testWidgets('reports paths, names, params and extra state', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        fixtures: <String, List<McpFixture>>{
          'event-listing': <McpFixture>[
            McpFixture('Demo event', () => <String, Object?>{'event': 'demo'}),
          ],
        },
        safeRoutes: <String>{'/home'},
      );

      final List<RouteInfo> routes =
          (handlers.listRoutes()['routes']! as List<Object?>)
              .map(
                (Object? e) => RouteInfo.fromJson((e! as Map<String, Object?>)),
              )
              .toList();

      expect(routes.map((RouteInfo r) => r.fullPath), <String>[
        '/home',
        '/city/:citySlug/events',
        '/event-listing',
      ]);
      expect(routes[0].extra, ExtraRequirement.none);
      expect(routes[1].extra, ExtraRequirement.unknown);
      expect(routes[1].pathParams, <String>['citySlug']);
      expect(routes[2].extra, ExtraRequirement.fixture);
      expect(routes[2].fixtures, <String>['default']);
      expect(routes[2].name, 'event-listing');
    });
  });

  group('currentRoute', () {
    testWidgets('reports location, name, params and match stack', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      await handlers.navigate(
        const NavigateRequest(
          target: '/city/:citySlug/events',
          pathParams: <String, String>{'citySlug': 'milano'},
          queryParams: <String, String>{'tab': 'past'},
        ).toJson(),
      );

      final CurrentRoute current = CurrentRoute.fromJson(
        handlers.currentRoute(),
      );
      expect(current.location, '/city/milano/events?tab=past');
      expect(current.name, 'city-events');
      expect(current.pathParams, <String, String>{'citySlug': 'milano'});
      expect(current.queryParams, <String, String>{'tab': 'past'});
      expect(current.matches.single.path, '/city/:citySlug/events');
    });
  });

  group('navigate', () {
    testWidgets('go substitutes path and query parameters', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(
            target: '/city/:citySlug/events',
            pathParams: <String, String>{'citySlug': 'milano'},
          ).toJson(),
        ),
      );

      expect(result.ok, isTrue);
      expect(result.location, '/city/milano/events');
      expect(find.text('events milano'), findsOneWidget);
    });

    testWidgets('accepts a route name as target', (WidgetTester tester) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(
            target: 'city-events',
            pathParams: <String, String>{'citySlug': 'roma'},
          ).toJson(),
        ),
      );

      expect(result.ok, isTrue);
      expect(result.location, '/city/roma/events');
    });

    testWidgets('push then pop returns to the previous location', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final NavigateResult pushed = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(
            target: 'city-events',
            mode: NavigateMode.push,
            pathParams: <String, String>{'citySlug': 'roma'},
          ).toJson(),
        ),
      );
      expect(pushed.ok, isTrue);
      expect(pushed.location, '/city/roma/events');

      final NavigateResult popped = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: '', mode: NavigateMode.pop).toJson(),
        ),
      );
      expect(popped.ok, isTrue);
      expect(popped.location, '/home');
    });

    testWidgets('pop on the last page is rejected', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final NavigateResult popped = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: '', mode: NavigateMode.pop).toJson(),
        ),
      );
      expect(popped.ok, isFalse);
      expect(popped.error, contains('pop'));
    });

    testWidgets('uses the single registered fixture as extra', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        fixtures: <String, List<McpFixture>>{
          'event-listing': <McpFixture>[
            McpFixture('Demo event', () => <String, Object?>{'event': 'demo'}),
          ],
        },
      );

      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: '/event-listing').toJson(),
        ),
      );

      expect(result.ok, isTrue, reason: result.error);
      expect(find.text('listing demo'), findsOneWidget);
    });

    testWidgets('reports a build failure as an error', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: '/event-listing').toJson(),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('Null'));
    });

    testWidgets('rejects an unknown target', (WidgetTester tester) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: '/nope').toJson(),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('/nope'));
    });

    testWidgets('rejects a missing path parameter', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(target: 'city-events').toJson(),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('citySlug'));
    });

    testWidgets('rejects an unknown fixture name', (WidgetTester tester) async {
      await pumpApp(
        tester,
        fixtures: <String, List<McpFixture>>{
          'event-listing': <McpFixture>[
            McpFixture('Demo event', () => <String, Object?>{'event': 'demo'}),
          ],
        },
      );
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(
          const NavigateRequest(
            target: '/event-listing',
            fixture: 'missing',
          ).toJson(),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('missing'));
    });

    testWidgets('rejects an unknown mode', (WidgetTester tester) async {
      await pumpApp(tester);
      final NavigateResult result = NavigateResult.fromJson(
        await handlers.navigate(<String, Object?>{
          'target': '/home',
          'mode': 'teleport',
        }),
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('teleport'));
    });
  });
}
