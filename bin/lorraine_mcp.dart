import 'dart:io';

import 'package:lorraine/mcp_server.dart';

const _usage = '''
Serve Lorraine's local meeting history to MCP clients over stdio, read-only.

Usage: lorraine_mcp [--state <path/to/state.json>]

The state file defaults to \$LORRAINE_STATE if set, then the app's current
Application Support location, then the legacy sandbox container.
''';

Future<void> main(List<String> arguments) async {
  String? statePath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--help' || argument == '-h') {
      stdout.write(_usage);
      return;
    } else if (argument == '--state' && index + 1 < arguments.length) {
      statePath = arguments[++index];
    } else if (argument.startsWith('--state=')) {
      statePath = argument.substring('--state='.length);
    } else {
      stderr
        ..writeln('Unknown argument: $argument')
        ..write(_usage);
      exitCode = 64;
      return;
    }
  }
  if (statePath != null && !File(statePath).existsSync()) {
    stderr.writeln('State file not found: $statePath');
    exitCode = 66;
    return;
  }
  final store = MeetingStore(statePath ?? MeetingStore.defaultStatePath());
  // Startup diagnostics belong on stderr; stdout carries only MCP messages.
  stderr.writeln('lorraine MCP server reading ${store.statePath}');
  await LorraineMcpServer(store).serve(input: stdin, output: stdout);
}
