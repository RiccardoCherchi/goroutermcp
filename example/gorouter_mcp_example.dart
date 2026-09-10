// Attach gorouter_mcp to a GoRouter so an agent can list and drive the routes.
//
// Run with:
//   flutter run --vmservice-out-file=.dart_tool/gorouter_mcp.uri
// then point an MCP client at `dart run gorouter_mcp:server`.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gorouter_mcp/gorouter_mcp.dart';

/// A route that needs `extra` to build gets a fixture; a route that does not
/// gets declared safe, which promotes it from `unknown` to `none` in
/// `list_routes`.
final Map<String, List<McpFixture>> exampleFixtures =
    <String, List<McpFixture>>{
      'event': <McpFixture>[
        McpFixture(
          'Demo event',
          () => <String, Object?>{'title': 'Coldplay, San Siro'},
        ),
      ],
    };

final Set<String> exampleSafeRoutes = <String>{'/home', '/city/:citySlug'};

GoRouter buildRouter() => GoRouter(
  initialLocation: '/home',
  routes: <RouteBase>[
    GoRoute(
      path: '/home',
      name: 'home',
      builder: (_, __) => const _Screen('home'),
    ),
    GoRoute(
      path: '/city/:citySlug',
      builder: (BuildContext context, GoRouterState state) =>
          _Screen('city ${state.pathParameters['citySlug']}'),
    ),
    GoRoute(
      path: '/event',
      name: 'event',
      builder: (BuildContext context, GoRouterState state) {
        // Reading `extra` in the builder is why fixtures exist: without
        // one, navigating here throws while building the page.
        final Map<String, Object?> extra = state.extra! as Map<String, Object?>;
        return _Screen('event ${extra['title']}');
      },
    ),
  ],
);

void main() {
  final GoRouter router = buildRouter();
  GoRouterMcp.attach(
    router,
    fixtures: exampleFixtures,
    safeRoutes: exampleSafeRoutes,
  );
  runApp(MaterialApp.router(routerConfig: router));
}

class _Screen extends StatelessWidget {
  const _Screen(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}
