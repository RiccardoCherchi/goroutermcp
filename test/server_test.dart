import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../bin/server.dart';

class _FakeBridge implements RouteBridge {
  _FakeBridge({this.response, this.error, this.hang = false});

  final Map<String, Object?>? response;
  final Object? error;
  final bool hang;
  final List<List<Object?>> calls = <List<Object?>>[];

  @override
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?>? args,
  }) {
    calls.add(<Object?>[method, args]);
    if (hang) {
      return Completer<Map<String, Object?>>().future;
    }
    if (error != null) {
      return Future<Map<String, Object?>>.error(error!);
    }
    return Future<Map<String, Object?>>.value(response!);
  }

  @override
  Future<void> close() async {}
}

Map<String, Object?> _decode(CallToolResult result) =>
    jsonDecode((result.content.single as TextContent).text)
        as Map<String, Object?>;

String _text(CallToolResult result) =>
    (result.content.single as TextContent).text;

void main() {
  group('list_routes tool', () {
    test('returns the routes reported by the app', () async {
      final _FakeBridge bridge = _FakeBridge(
        response: <String, Object?>{
          'routes': <Object?>[
            <String, Object?>{'fullPath': '/home', 'extra': 'none'},
          ],
        },
      );
      final GoRouterMcpTools tools = GoRouterMcpTools(bridge);

      final CallToolResult result = await tools.listRoutes();

      expect(result.isError, isFalse);
      expect(_decode(result)['routes'], hasLength(1));
      expect(bridge.calls.single.first, 'ext.gorouter_mcp.listRoutes');
    });

    test('reports a disconnected app as a tool error', () async {
      final GoRouterMcpTools tools = GoRouterMcpTools(
        _FakeBridge(
          error: const BridgeException('No app is running on the VM Service.'),
        ),
      );

      final CallToolResult result = await tools.listRoutes();

      expect(result.isError, isTrue);
      expect(_text(result), contains('No app is running'));
    });

    test('reports an unexpected failure as a tool error', () async {
      final GoRouterMcpTools tools = GoRouterMcpTools(
        _FakeBridge(error: StateError('boom')),
      );

      final CallToolResult result = await tools.listRoutes();

      expect(result.isError, isTrue);
      expect(_text(result), contains('boom'));
    });

    test('reports a timeout as a tool error', () async {
      final GoRouterMcpTools tools = GoRouterMcpTools(
        _FakeBridge(hang: true),
        timeout: const Duration(milliseconds: 20),
      );

      final CallToolResult result = await tools.listRoutes();

      expect(result.isError, isTrue);
      expect(_text(result), contains('Timed out'));
    });
  });

  group('current_route tool', () {
    test('returns the current location', () async {
      final GoRouterMcpTools tools = GoRouterMcpTools(
        _FakeBridge(response: <String, Object?>{'location': '/home'}),
      );

      final CallToolResult result = await tools.currentRoute();

      expect(result.isError, isFalse);
      expect(_decode(result)['location'], '/home');
    });
  });

  group('navigate tool', () {
    test('forwards its arguments and returns the new location', () async {
      final _FakeBridge bridge = _FakeBridge(
        response: <String, Object?>{
          'ok': true,
          'location': '/city/milano/events',
        },
      );
      final GoRouterMcpTools tools = GoRouterMcpTools(bridge);

      final CallToolResult result = await tools.navigate(<String, dynamic>{
        'target': '/city/:citySlug/events',
        'pathParams': <String, dynamic>{'citySlug': 'milano'},
      });

      expect(result.isError, isFalse);
      expect(_decode(result)['location'], '/city/milano/events');
      expect(bridge.calls.single.first, 'ext.gorouter_mcp.navigate');
      expect(
        (bridge.calls.single.last! as Map<String, Object?>)['target'],
        '/city/:citySlug/events',
      );
    });

    test('marks a rejected navigation as a tool error', () async {
      final GoRouterMcpTools tools = GoRouterMcpTools(
        _FakeBridge(
          response: <String, Object?>{
            'ok': false,
            'error': 'boom while building',
          },
        ),
      );

      final CallToolResult result = await tools.navigate(<String, dynamic>{
        'target': '/event-listing',
      });

      expect(result.isError, isTrue);
      expect(_text(result), contains('boom while building'));
    });
  });

  group('resolveVmServiceUri', () {
    test('prefers the command line argument', () {
      expect(
        resolveVmServiceUri(
          argument: 'http://127.0.0.1:1/abc=/',
          environment: <String, String>{
            'GOROUTER_MCP_VM_URI': 'http://127.0.0.1:2/env=/',
          },
        ),
        Uri.parse('http://127.0.0.1:1/abc=/'),
      );
    });

    test('falls back to the environment variable', () {
      expect(
        resolveVmServiceUri(
          environment: <String, String>{
            'GOROUTER_MCP_VM_URI': 'http://127.0.0.1:2/env=/',
          },
        ),
        Uri.parse('http://127.0.0.1:2/env=/'),
      );
    });

    test('falls back to the uri file written by flutter run', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'gorouter_mcp',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/gorouter_mcp.uri');
      await file.writeAsString('http://127.0.0.1:3/file=/\n');

      expect(
        resolveVmServiceUri(
          environment: const <String, String>{},
          uriFilePath: file.path,
        ),
        Uri.parse('http://127.0.0.1:3/file=/'),
      );
    });

    test('explains how to start the app when nothing is configured', () {
      expect(
        () => resolveVmServiceUri(
          environment: const <String, String>{},
          uriFilePath: '/does/not/exist.uri',
        ),
        throwsA(
          isA<BridgeException>().having(
            (BridgeException e) => e.message,
            'message',
            contains('--vmservice-out-file'),
          ),
        ),
      );
    });
  });

  group('webSocketUri', () {
    test('converts an http service uri to a websocket uri', () {
      expect(
        webSocketUri(Uri.parse('http://127.0.0.1:52321/abcdef=/')).toString(),
        'ws://127.0.0.1:52321/abcdef=/ws',
      );
    });
  });
}
