import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lorraine/mcp_server.dart';

const _fixtureState = {
  'version': 2,
  'meetings': [
    {
      'id': 'meeting-standup',
      'title': 'Monday standup',
      'created_at': '2026-09-01T08:00:00.000',
      'audio_path': '/private/recordings/meeting-standup.m4a',
      'duration_seconds': 0,
      'status': 'processing',
      'processing_stage': 'Transcribing',
      'progress': 0.4,
    },
    {
      'id': 'meeting-roadmap',
      'title': 'Roadmap sync',
      'created_at': '2026-08-30T09:30:00.000',
      'audio_path': '/private/recordings/meeting-roadmap.m4a',
      'duration_seconds': 1800,
      'status': 'ready',
      'language': 'en',
      'summary':
          '# Roadmap sync\n\n- The beta ships on Friday\n'
          '- Alice owns the launch checklist',
      'segments': [
        {
          'start': 0.0,
          'end': 4.2,
          'speaker_id': 'SPEAKER_00',
          'text': 'Welcome everyone, let us review the roadmap.',
        },
        {
          'start': 4.2,
          'end': 9.8,
          'speaker_id': 'SPEAKER_01',
          'text': 'The beta ships on Friday if QA passes.',
        },
        {
          'start': 70.5,
          'end': 74.0,
          'speaker_id': 'SPEAKER_00',
          'text': 'I will own the launch checklist.',
        },
      ],
      'speakers': [
        {
          'id': 'SPEAKER_00',
          'embedding': [0.1, 0.2],
          'sample_path': '/private/samples/meeting-roadmap-SPEAKER_00.wav',
          'profile_id': 'profile-alice',
          'match_confidence': 0.91,
          'identity_confirmed': true,
        },
        {
          'id': 'SPEAKER_01',
          'embedding': [0.3, 0.4],
        },
      ],
    },
    {
      'id': 'meeting-budget',
      'title': 'Q3 budget review',
      'created_at': '2026-08-15T14:00:00.000',
      'audio_path': '/private/recordings/meeting-budget.m4a',
      'duration_seconds': 900,
      'status': 'ready',
      'language': 'en',
      'segments': [
        {
          'start': 12.0,
          'end': 16.0,
          'speaker_id': 'SPEAKER_00',
          'text': 'The travel budget is frozen until October.',
        },
      ],
      'speakers': [
        {
          'id': 'SPEAKER_00',
          'embedding': [0.5, 0.6],
        },
      ],
    },
  ],
  'profiles': [
    {
      'id': 'profile-alice',
      'name': 'Alice Prieto',
      'email': 'alice@example.com',
      'embeddings': [
        [0.1, 0.2],
      ],
      'sample_path': '/private/samples/profile-alice.wav',
      'created_at': '2026-07-01T00:00:00.000',
    },
  ],
  'settings': {
    'modal_base_url': 'https://example.modal.run',
    'api_key': 'modal-secret-key-123',
    'summary_provider': 'anthropic',
    'summary_providers': {
      'anthropic': {
        'base_url': 'https://api.anthropic.com/v1',
        'model': 'claude-opus-4-8',
        'api_key': 'anthropic-secret-456',
      },
    },
  },
};

void main() {
  late Directory tempDir;
  late LorraineMcpServer server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lorraine_mcp_test');
    final stateFile = File('${tempDir.path}/state.json');
    await stateFile.writeAsString(jsonEncode(_fixtureState));
    server = LorraineMcpServer(MeetingStore(stateFile.path));
  });

  tearDown(() => tempDir.delete(recursive: true));

  Map<String, dynamic> rpc(String method, [Map<String, dynamic>? params]) =>
      server.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      })!;

  Map<String, dynamic> callTool(
    String name, [
    Map<String, dynamic> arguments = const {},
  ]) {
    final response = rpc('tools/call', {'name': name, 'arguments': arguments});
    return response['result'] as Map<String, dynamic>;
  }

  String toolText(Map<String, dynamic> result) {
    final content = result['content'] as List<dynamic>;
    return (content.single as Map<String, dynamic>)['text'] as String;
  }

  test('initialize reports tool support and echoes a known version', () {
    final result =
        rpc('initialize', {
              'protocolVersion': '2025-03-26',
              'capabilities': <String, dynamic>{},
              'clientInfo': {'name': 'test', 'version': '0'},
            })['result']
            as Map<String, dynamic>;
    expect(result['protocolVersion'], '2025-03-26');
    expect((result['serverInfo'] as Map<String, dynamic>)['name'], 'lorraine');
    expect(result['capabilities'], containsPair('tools', anything));
  });

  test('unknown protocol versions fall back to the newest supported one', () {
    final result =
        rpc('initialize', {'protocolVersion': '1999-01-01'})['result']
            as Map<String, dynamic>;
    expect(result['protocolVersion'], supportedProtocolVersions.last);
  });

  test('notifications and unknown methods behave per JSON-RPC', () {
    expect(
      server.handleMessage({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }),
      isNull,
    );
    final error = rpc('resources/list')['error'] as Map<String, dynamic>;
    expect(error['code'], -32601);
  });

  test('tools/list exposes the four query tools with schemas', () {
    final tools =
        (rpc('tools/list')['result'] as Map<String, dynamic>)['tools']
            as List<dynamic>;
    final names = tools
        .map((tool) => (tool as Map<String, dynamic>)['name'])
        .toSet();
    expect(names, {
      'list_meetings',
      'get_transcript',
      'get_summary',
      'search_meetings',
    });
    for (final tool in tools.cast<Map<String, dynamic>>()) {
      expect(tool['description'], isNotEmpty);
      expect(tool['inputSchema'], containsPair('type', 'object'));
    }
  });

  test('list_meetings returns all meetings newest first', () {
    final payload =
        jsonDecode(toolText(callTool('list_meetings'))) as Map<String, dynamic>;
    expect(payload['total_meetings'], 3);
    final meetings = (payload['meetings'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(meetings.map((meeting) => meeting['id']).toList(), [
      'meeting-standup',
      'meeting-roadmap',
      'meeting-budget',
    ]);
    final roadmap = meetings[1];
    expect(roadmap['has_transcript'], isTrue);
    expect(roadmap['has_summary'], isTrue);
    expect(roadmap['duration'], '30:00');
    expect(roadmap['speakers'], ['Alice Prieto', 'SPEAKER_01 (unidentified)']);
    expect(meetings.first['has_transcript'], isFalse);
  });

  test('list_meetings filters by title query and date range', () {
    final byQuery =
        jsonDecode(toolText(callTool('list_meetings', {'query': 'roadmap'})))
            as Map<String, dynamic>;
    expect(byQuery['matched'], 1);
    expect(
      ((byQuery['meetings'] as List<dynamic>).single
          as Map<String, dynamic>)['id'],
      'meeting-roadmap',
    );

    final byRange =
        jsonDecode(
              toolText(
                callTool('list_meetings', {
                  'from': '2026-08-20',
                  'to': '2026-08-30',
                }),
              ),
            )
            as Map<String, dynamic>;
    expect(
      ((byRange['meetings'] as List<dynamic>).single
          as Map<String, dynamic>)['id'],
      'meeting-roadmap',
      reason: 'a bare "to" date includes that whole day',
    );

    final badDate = callTool('list_meetings', {'from': 'yesterday'});
    expect(badDate['isError'], isTrue);
  });

  test('get_transcript resolves enrolled speaker names', () {
    final result = callTool('get_transcript', {
      'meeting_id': 'meeting-roadmap',
    });
    expect(result['isError'], isFalse);
    final text = toolText(result);
    expect(
      text,
      contains(
        '- SPEAKER_00: Alice Prieto <alice@example.com> '
        '(identity confirmed in the app)',
      ),
    );
    expect(text, contains('- SPEAKER_01: unidentified'));
    expect(
      text,
      contains('[0:00] Alice Prieto: Welcome everyone, let us review'),
    );
    expect(text, contains('[0:04] SPEAKER_01: The beta ships on Friday'));
    expect(text, contains('[1:10] Alice Prieto: I will own the launch'));
  });

  test('get_transcript accepts a unique id prefix and rejects others', () {
    expect(
      toolText(callTool('get_transcript', {'meeting_id': 'meeting-r'})),
      contains('# Roadmap sync'),
    );
    final ambiguous = callTool('get_transcript', {'meeting_id': 'meeting-'});
    expect(ambiguous['isError'], isTrue);
    expect(toolText(ambiguous), contains('ambiguous'));
    final missing = callTool('get_transcript', {'meeting_id': 'nope'});
    expect(missing['isError'], isTrue);
    expect(toolText(missing), contains('list_meetings'));
  });

  test('get_transcript explains meetings without a transcript', () {
    final text = toolText(
      callTool('get_transcript', {'meeting_id': 'meeting-standup'}),
    );
    expect(text, contains('Transcription is still in progress'));
    expect(text, contains('Transcribing'));
  });

  test('get_summary returns the stored markdown synopsis', () {
    final text = toolText(
      callTool('get_summary', {'meeting_id': 'meeting-roadmap'}),
    );
    expect(text, contains('Summary of "Roadmap sync"'));
    expect(text, contains('- Alice owns the launch checklist'));
  });

  test('get_summary explains when no synopsis exists yet', () {
    final text = toolText(
      callTool('get_summary', {'meeting_id': 'meeting-budget'}),
    );
    expect(text, contains('No summary has been generated'));
    expect(text, contains('use get_transcript'));
  });

  test('search_meetings finds text in transcripts and summaries', () {
    final friday =
        jsonDecode(toolText(callTool('search_meetings', {'query': 'Friday'})))
            as Map<String, dynamic>;
    expect(friday['matched_meetings'], 1);
    final snippets =
        ((friday['results'] as List<dynamic>).single
                as Map<String, dynamic>)['snippets']
            as List<dynamic>;
    final places = snippets
        .map((snippet) => (snippet as Map<String, dynamic>)['where'])
        .toSet();
    expect(places, containsAll(['summary', 'transcript']));

    final budget =
        jsonDecode(toolText(callTool('search_meetings', {'query': 'budget'})))
            as Map<String, dynamic>;
    final ids = (budget['results'] as List<dynamic>)
        .map((result) => (result as Map<String, dynamic>)['id'])
        .toList();
    expect(ids, ['meeting-budget']);

    final empty = callTool('search_meetings', {'query': '   '});
    expect(empty['isError'], isTrue);
  });

  test('no tool output leaks credentials, embeddings, or file paths', () {
    final outputs = [
      jsonEncode(rpc('tools/list')),
      toolText(callTool('list_meetings')),
      toolText(callTool('get_transcript', {'meeting_id': 'meeting-roadmap'})),
      toolText(callTool('get_summary', {'meeting_id': 'meeting-roadmap'})),
      toolText(callTool('search_meetings', {'query': 'secret'})),
      toolText(callTool('search_meetings', {'query': 'e'})),
    ].join('\n');
    expect(outputs, isNot(contains('modal-secret-key-123')));
    expect(outputs, isNot(contains('anthropic-secret-456')));
    expect(outputs, isNot(contains('example.modal.run')));
    expect(outputs, isNot(contains('/private/recordings')));
    expect(outputs, isNot(contains('/private/samples')));
    expect(outputs, isNot(contains('embedding')));
  });

  test('a missing state file serves an empty history', () {
    final emptyServer = LorraineMcpServer(
      MeetingStore('${tempDir.path}/does-not-exist.json'),
    );
    final response = emptyServer.handleMessage({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'tools/call',
      'params': {'name': 'list_meetings', 'arguments': <String, dynamic>{}},
    })!;
    final result = response['result'] as Map<String, dynamic>;
    final payload = jsonDecode(toolText(result)) as Map<String, dynamic>;
    expect(payload['total_meetings'], 0);
  });

  test('serve answers over a newline-delimited stream', () async {
    final output = StringBuffer();
    final input = Stream.fromIterable([
      utf8.encode('this is not json\n'),
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': 9, 'method': 'ping'})}\n',
      ),
    ]);
    await server.serve(input: input, output: output);
    final lines = const LineSplitter().convert(output.toString());
    expect(lines, hasLength(2));
    final parseError =
        (jsonDecode(lines[0]) as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(parseError['code'], -32700);
    final pong = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(pong['id'], 9);
    expect(pong['result'], isEmpty);
  });
}
