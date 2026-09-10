## 0.1.0

- Initial release.
- `GoRouterMcp.attach` registers the `ext.gorouter_mcp.*` VM service extensions
  in debug builds: `listRoutes`, `currentRoute`, `navigate`.
- Route walker computes a full path for every `GoRoute`, including nested
  routes, path parameters, `ShellRoute` and `StatefulShellRoute`.
- Fixtures supply the `extra` payload routes need to build, and declare which
  routes are safe without one.
- `bin/server.dart`: MCP server over stdio proxying the extensions through the
  Dart VM Service.
