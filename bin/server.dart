/// MCP server that proxies the `ext.gorouter_mcp.*` VM service extensions of a
/// running Flutter app.
///
/// Run it from a Flutter project that depends on `gorouter_mcp`:
///
/// ```
/// flutter run --vmservice-out-file=.dart_tool/gorouter_mcp.uri
/// dart run gorouter_mcp:server
/// ```
///
/// This file is never imported from `lib/`, which keeps `mcp_dart` and
/// `vm_service` out of the app binary.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorouter_mcp/src/protocol.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:vm_service/utils.dart' as vm_utils;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Default path of the file `flutter run --vmservice-out-file` writes.
const String kDefaultUriFilePath = '.dart_tool/gorouter_mcp.uri';

/// Environment variable holding the VM Service URI.
const String kVmUriEnvVar = 'GOROUTER_MCP_VM_URI';

/// A failure the agent can act on, as opposed to a programming error.
class BridgeException implements Exception {
  const BridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Transport onto the app's service extensions.
abstract class RouteBridge {
  /// Calls [method] with [args], returning the extension's decoded result.
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?>? args,
  });

  /// Releases the underlying connection.
  Future<void> close();
}

/// The three MCP tools, as plain methods so they can be tested against a fake
/// [RouteBridge].
class GoRouterMcpTools {
  GoRouterMcpTools(this.bridge, {this.timeout = const Duration(seconds: 15)});

  final RouteBridge bridge;

  /// How long to wait for the app to answer before failing the tool call.
  final Duration timeout;

  /// Registers the tools on [server].
  void registerOn(McpServer server) {
    server.registerTool(
      'list_routes',
      description:
          'List every GoRouter route in the running app, with its '
          'full path, name, path parameters, whether it needs `extra` data '
          '(none/fixture/unknown) and which fixtures are registered.',
      inputSchema: JsonSchema.object(properties: <String, JsonSchema>{}),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) =>
          listRoutes(),
    );

    server.registerTool(
      'current_route',
      description:
          'Report where the running app currently is: location, '
          'route name, path and query parameters, and the match stack.',
      inputSchema: JsonSchema.object(properties: <String, JsonSchema>{}),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) =>
          currentRoute(),
    );

    server.registerTool(
      'navigate',
      description:
          'Navigate the running app to a route. `target` is a full '
          'path (as reported by list_routes) or a route name. Routes whose '
          '`extra` is `fixture` need a registered fixture; routes whose '
          '`extra` is `unknown` may throw while building.',
      inputSchema: JsonSchema.object(
        properties: <String, JsonSchema>{
          'target': JsonSchema.string(
            description: 'Full path or route name. Omit when mode is pop.',
          ),
          'mode': JsonSchema.string(
            description: 'go (replace), push (stack) or pop.',
            enumValues: <String>['go', 'push', 'pop'],
            defaultValue: 'go',
          ),
          'pathParams': JsonSchema.object(
            description: 'Values for the route path parameters.',
            additionalProperties: JsonSchema.string(),
          ),
          'queryParams': JsonSchema.object(
            description: 'Query string parameters.',
            additionalProperties: JsonSchema.string(),
          ),
          'fixture': JsonSchema.string(
            description:
                'Name of the fixture to pass as `extra`. '
                'Defaults to the route\'s only fixture, if it has one.',
          ),
        },
      ),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) =>
          navigate(args),
    );
  }

  /// Implements the `list_routes` tool.
  Future<CallToolResult> listRoutes() => _call(kListRoutesMethod);

  /// Implements the `current_route` tool.
  Future<CallToolResult> currentRoute() => _call(kCurrentRouteMethod);

  /// Implements the `navigate` tool.
  Future<CallToolResult> navigate(Map<String, dynamic> args) =>
      _call(kNavigateMethod, args: args, failWhenNotOk: true);

  Future<CallToolResult> _call(
    String method, {
    Map<String, Object?>? args,
    bool failWhenNotOk = false,
  }) async {
    final Map<String, Object?> result;
    try {
      result = await bridge
          .call(method, args: args)
          .timeout(
            timeout,
            onTimeout: () => throw BridgeException(
              'Timed out after ${timeout.inSeconds}s waiting for the app to '
              'answer $method. Is the app still running?',
            ),
          );
    } on BridgeException catch (error) {
      return _error(error.message);
    } catch (error) {
      return _error('$error');
    }
    if (failWhenNotOk && result['ok'] != true) {
      return _error(jsonEncode(result));
    }
    return CallToolResult.fromContent(<Content>[
      TextContent(text: jsonEncode(result)),
    ]);
  }

  static CallToolResult _error(String message) => CallToolResult(
    content: <Content>[TextContent(text: message)],
    isError: true,
  );
}

/// A [RouteBridge] backed by the Dart VM Service of a running app.
class VmServiceBridge implements RouteBridge {
  VmServiceBridge({
    Uri? uri,
    Map<String, String>? environment,
    String uriFilePath = kDefaultUriFilePath,
    this.maxAttempts = 3,
  }) : _uri = uri,
       _environment = environment ?? Platform.environment,
       _uriFilePath = uriFilePath;

  final Uri? _uri;
  final Map<String, String> _environment;
  final String _uriFilePath;

  /// How many times a call is retried across a dropped connection, which is
  /// what a hot restart looks like from here.
  final int maxAttempts;

  VmService? _service;
  String? _isolateId;

  @override
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?>? args,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
      try {
        final VmService service = await _connect();
        final Response response = await service.callServiceExtension(
          method,
          isolateId: await _isolateIdFor(service, method),
          args: <String, dynamic>{
            if (args != null) kArgsParam: jsonEncode(args),
          },
        );
        final Map<String, Object?> json = Map<String, Object?>.of(
          response.json ?? <String, Object?>{},
        )..remove('type');
        return json;
      } on BridgeException {
        rethrow;
      } catch (error) {
        lastError = error;
        await _reset();
      }
    }
    throw BridgeException(
      'Could not reach the app over the VM Service after '
      '$maxAttempts attempts: $lastError\n'
      'If the app was hot restarted, retry; otherwise start it with:\n'
      '  flutter run --vmservice-out-file=$kDefaultUriFilePath',
    );
  }

  @override
  Future<void> close() => _reset();

  Future<void> _reset() async {
    final VmService? service = _service;
    _service = null;
    _isolateId = null;
    await service?.dispose();
  }

  Future<VmService> _connect() async {
    final VmService? existing = _service;
    if (existing != null) {
      return existing;
    }
    final Uri uri =
        _uri ??
        resolveVmServiceUri(
          environment: _environment,
          uriFilePath: _uriFilePath,
        );
    try {
      final VmService service = await vmServiceConnectUri(
        webSocketUri(uri).toString(),
      );
      _service = service;
      unawaited(
        service.onDone.then((_) {
          if (_service == service) {
            _service = null;
            _isolateId = null;
          }
        }),
      );
      return service;
    } catch (error) {
      throw BridgeException(
        'Could not connect to the VM Service at $uri: '
        '$error\nStart the app with:\n'
        '  flutter run --vmservice-out-file=$kDefaultUriFilePath',
      );
    }
  }

  Future<String> _isolateIdFor(VmService service, String method) async {
    final String? cached = _isolateId;
    if (cached != null) {
      return cached;
    }
    final VM vm = await service.getVM();
    for (final IsolateRef ref in vm.isolates ?? <IsolateRef>[]) {
      final String? id = ref.id;
      if (id == null) {
        continue;
      }
      final Isolate isolate = await service.getIsolate(id);
      if (isolate.extensionRPCs?.contains(method) ?? false) {
        _isolateId = id;
        return id;
      }
    }
    throw BridgeException(
      'The app is running but does not expose $method. Call '
      'GoRouterMcp.attach(router) after building the router, and make sure '
      'this is a debug build.',
    );
  }
}

/// Locates the VM Service URI: the [argument] first, then [environment], then
/// the URI file written by `flutter run --vmservice-out-file`.
Uri resolveVmServiceUri({
  String? argument,
  Map<String, String>? environment,
  String uriFilePath = kDefaultUriFilePath,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? raw = argument ?? env[kVmUriEnvVar];
  if (raw != null && raw.isNotEmpty) {
    return Uri.parse(raw.trim());
  }
  final File file = File(uriFilePath);
  if (file.existsSync()) {
    final String contents = file.readAsStringSync().trim();
    if (contents.isNotEmpty) {
      return Uri.parse(contents);
    }
  }
  throw BridgeException(
    'No VM Service URI. Start the app with:\n'
    '  flutter run --vmservice-out-file=$uriFilePath\n'
    'or pass --vm-service-uri, or set $kVmUriEnvVar.',
  );
}

/// Converts a VM Service HTTP URI into the websocket URI clients connect to.
Uri webSocketUri(Uri uri) =>
    vm_utils.convertToWebSocketUrl(serviceProtocolUrl: uri);

Future<void> main(List<String> arguments) async {
  String? uriArgument;
  String uriFilePath = kDefaultUriFilePath;
  for (int i = 0; i < arguments.length; i++) {
    final String arg = arguments[i];
    if (arg == '--vm-service-uri' && i + 1 < arguments.length) {
      uriArgument = arguments[++i];
    } else if (arg.startsWith('--vm-service-uri=')) {
      uriArgument = arg.split('=').skip(1).join('=');
    } else if (arg == '--uri-file' && i + 1 < arguments.length) {
      uriFilePath = arguments[++i];
    } else if (arg.startsWith('--uri-file=')) {
      uriFilePath = arg.substring('--uri-file='.length);
    }
  }

  final VmServiceBridge bridge = VmServiceBridge(
    uri: uriArgument == null ? null : Uri.parse(uriArgument),
    uriFilePath: uriFilePath,
  );
  final McpServer server = McpServer(
    Implementation(name: 'gorouter_mcp', version: '0.1.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );
  GoRouterMcpTools(bridge).registerOn(server);

  // stdout is reserved for MCP protocol messages.
  await server.connect(StdioServerTransport());
}
