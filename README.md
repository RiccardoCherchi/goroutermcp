# gorouter_mcp

Drive a running Flutter app's `GoRouter` from an AI agent: list every route and
navigate straight to one, instead of replaying a click path.

Two halves that never share a process:

- **app side** — a Flutter library that registers three Dart VM service
  extensions (`ext.gorouter_mcp.listRoutes`, `.currentRoute`, `.navigate`) in
  debug builds only;
- **server side** — `bin/server.dart`, a pure Dart MCP server over stdio that
  connects to the app's VM Service and proxies each tool onto the matching
  extension.

`bin/server.dart` is never imported from `lib/`, so `mcp_dart` and `vm_service`
stay out of the app binary.

## Install

```yaml
dependencies:
  gorouter_mcp:
    git:
      url: https://github.com/<owner>/gorouter_mcp.git

# While developing the two together:
dependency_overrides:
  gorouter_mcp:
    path: ../../projects/gorouter_mcp
```

## Attach

Right after the router is built:

```dart
GoRouter routes = router(HomePage.routePath);
GoRouterMcp.attach(
  routes,
  fixtures: ticketooMcpFixtures,
  safeRoutes: ticketooMcpSafeRoutes,
);
```

Outside `kDebugMode`, `attach` returns immediately and registers nothing.
Calling it again — as hot restart does — rebinds to the new router.

## Fixtures

Roughly half of a real app's routes read `state.extra` inside the page builder,
so a URL alone is not enough to build them. Declare the payload per route,
keyed by full path or route name:

```dart
final ticketooMcpFixtures = <String, List<McpFixture>>{
  'event-listing': [
    McpFixture('Demo event with three listings', () => {'event': sampleEvent}),
  ],
};

// Routes known to build fine without `extra`. Declaring them only promotes
// them from `unknown` to `none` in list_routes; they navigate either way.
final ticketooMcpSafeRoutes = <String>{'/home', 'city-events'};
```

`McpFixture.build` runs once per navigation, so fixtures can hand out fresh
model instances. A route with several fixtures needs the `fixture` argument;
with exactly one, it is used by default.

## Run

```
flutter run --vmservice-out-file=.dart_tool/gorouter_mcp.uri
```

MCP client configuration, from the app checkout that depends on this package:

```json
{
  "command": "dart",
  "args": ["run", "gorouter_mcp:server"],
  "cwd": "/path/to/your-flutter-app"
}
```

The server finds the VM Service URI in this order:

1. `--vm-service-uri <uri>`;
2. the `GOROUTER_MCP_VM_URI` environment variable;
3. the URI file, `.dart_tool/gorouter_mcp.uri` by default (`--uri-file` to
   change it).

Because the URI file is written on the host, this works for simulators,
emulators and physical devices alike.

## Tools

### `list_routes`

One record per route in the tree:

```json
{
  "fullPath": "/city/:citySlug/events",
  "name": "city-events",
  "pathParams": ["citySlug"],
  "extra": "fixture",
  "fixtures": ["default"]
}
```

`extra` is:

- `none` — declared safe by the adapter; navigate freely;
- `fixture` — needs `extra`, and at least one fixture is registered;
- `unknown` — may need `extra` and nothing is registered; navigating may throw
  while building the page.

The package cannot tell `none` from `unknown` by inspection, because
`state.extra` is read inside the builder body. Anything the adapter has not
declared safe is reported as `unknown` — deliberately pessimistic.

### `current_route`

Location, matched route name, path and query parameters, and the match stack,
read from `routerDelegate.currentConfiguration`.

### `navigate`

```json
{
  "target": "/city/:citySlug/events",
  "mode": "go",
  "pathParams": {"citySlug": "milano"},
  "queryParams": {},
  "fixture": "default"
}
```

`target` is a full path or a route name; `mode` is `go`, `push` or `pop`.
Returns `{"ok": true, "location": "/city/milano/events"}`, or `ok: false` with
an error when the target is unknown, a path parameter or fixture is missing, or
the page throws while building — `navigate` installs a temporary
`FlutterError.onError` handler and waits for a frame, so a failed build is
reported instead of vanishing into the console. It gives up after 5 seconds.

## Out of scope

Screenshots, widget interaction (tap, type, scroll), and reading or mutating
BLoC state. The agent navigates and observes where it landed; nothing more.

## Test

```
flutter test
```
