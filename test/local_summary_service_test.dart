import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lorraine/models.dart';
import 'package:lorraine/services.dart';

void main() {
  test('lazily pulls a missing Ollama model before summarizing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/show') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write(jsonEncode({'error': 'model not found'}));
      } else if (request.uri.path == '/api/pull') {
        request.response
          ..write(
            '${jsonEncode({'status': 'downloading', 'completed': 50, 'total': 100})}\n',
          )
          ..write('${jsonEncode({'status': 'success'})}\n');
      } else if (request.uri.path == '/api/generate') {
        request.response.write(jsonEncode({'response': '# Summary\nDone'}));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final progress = <SummaryProgress>[];
    final meeting = Meeting(
      id: 'meeting-1',
      title: 'Summary test',
      createdAt: DateTime.utc(2026, 7, 24),
      audioPath: '/tmp/meeting.m4a',
      durationSeconds: 10,
      status: MeetingStatus.ready,
      segments: const [
        TranscriptSegment(
          start: 0,
          end: 1,
          speakerId: 'SPEAKER_00',
          text: 'We made a decision.',
        ),
      ],
    );

    final summary = await SummaryService().summarize(
      meeting,
      AppSettings(
        summaryProviders: {
          SummaryProvider.ollama: SummaryProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}',
            model: 'gemma3:4b',
          ),
        },
      ),
      onProgress: progress.add,
    );

    expect(summary, '# Summary\nDone');
    expect(requests, ['/api/show', '/api/pull', '/api/generate']);
    expect(progress.any((item) => item.progress == 0.5), isTrue);
    expect(progress.any((item) => item.progress == 1), isTrue);
    expect(progress.last.message, contains('Generating summary'));
  });

  test('uses an installed Ollama model without pulling it', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/show') {
        request.response.write(jsonEncode({'details': {}}));
      } else if (request.uri.path == '/api/generate') {
        request.response.write(jsonEncode({'response': 'Already installed'}));
      }
      await request.response.close();
    });

    final summary = await SummaryService().summarize(
      Meeting(
        id: 'meeting-1',
        title: 'Summary test',
        createdAt: DateTime.utc(2026, 7, 24),
        audioPath: '/tmp/meeting.m4a',
        durationSeconds: 10,
        status: MeetingStatus.ready,
        segments: const [
          TranscriptSegment(
            start: 0,
            end: 1,
            speakerId: 'SPEAKER_00',
            text: 'Hello.',
          ),
        ],
      ),
      AppSettings(
        summaryProviders: {
          SummaryProvider.ollama: SummaryProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}',
            model: 'gemma3:4b',
          ),
        },
      ),
    );

    expect(summary, 'Already installed');
    expect(requests, ['/api/show', '/api/generate']);
  });

  test('summarizes through an OpenAI-compatible endpoint', () async {
    late Map<String, dynamic> body;
    late HttpHeaders headers;
    final server = await _serve((request, payload) {
      body = payload;
      headers = request.headers;
      return {
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '# Summary\nFrom OpenAI'},
          },
        ],
      };
    });

    final summary = await SummaryService().summarize(
      _meeting(),
      AppSettings(
        summaryProvider: SummaryProvider.openai,
        summaryProviders: {
          SummaryProvider.openai: SummaryProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'gpt-4o-mini',
            apiKey: 'sk-test',
          ),
        },
      ),
    );

    expect(summary, '# Summary\nFrom OpenAI');
    expect(headers.value('authorization'), 'Bearer sk-test');
    expect(body['model'], 'gpt-4o-mini');
    final messages = body['messages'] as List<dynamic>;
    expect(messages.first['role'], 'system');
    expect(messages.last['content'], contains('We made a decision.'));
  });

  test('summarizes through the Anthropic Messages API', () async {
    late Map<String, dynamic> body;
    late HttpHeaders headers;
    final server = await _serve((request, payload) {
      body = payload;
      headers = request.headers;
      return {
        'content': [
          {'type': 'text', 'text': '# Summary\n'},
          {'type': 'text', 'text': 'From Anthropic'},
        ],
        'stop_reason': 'end_turn',
      };
    });

    final summary = await SummaryService().summarize(
      _meeting(),
      AppSettings(
        summaryProvider: SummaryProvider.anthropic,
        summaryProviders: {
          SummaryProvider.anthropic: SummaryProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'claude-opus-4-8',
            apiKey: 'sk-ant-test',
          ),
        },
      ),
    );

    expect(summary, '# Summary\nFrom Anthropic');
    expect(headers.value('x-api-key'), 'sk-ant-test');
    expect(headers.value('anthropic-version'), '2023-06-01');
    expect(body['system'], isA<String>());
    expect(body['max_tokens'], isA<int>());
  });

  test('surfaces the provider error message instead of raw JSON', () async {
    final server = await _serve(
      (request, payload) => {
        'error': {'message': 'Incorrect API key provided'},
      },
      statusCode: HttpStatus.unauthorized,
    );

    await expectLater(
      SummaryService().summarize(
        _meeting(),
        AppSettings(
          summaryProvider: SummaryProvider.openRouter,
          summaryProviders: {
            SummaryProvider.openRouter: SummaryProviderConfig(
              baseUrl: 'http://127.0.0.1:${server.port}/api/v1',
              model: 'anthropic/claude-opus-4-8',
              apiKey: 'bad-key',
            ),
          },
        ),
      ),
      throwsA(
        isA<HttpException>().having(
          (error) => error.message,
          'message',
          contains('Incorrect API key provided'),
        ),
      ),
    );
  });

  test('refuses to call a cloud provider before a key is set', () async {
    await expectLater(
      SummaryService().summarize(
        _meeting(),
        const AppSettings(summaryProvider: SummaryProvider.anthropic),
      ),
      throwsA(isA<SummaryConfigurationException>()),
    );
  });

  test('promotes legacy Ollama settings into the provider map', () {
    final settings = AppSettings.fromJson({
      'ollama_url': 'http://192.168.1.5:11434',
      'ollama_model': 'llama3',
    });

    expect(settings.summaryProvider, SummaryProvider.ollama);
    expect(settings.summaryConfig.baseUrl, 'http://192.168.1.5:11434');
    expect(settings.summaryConfig.model, 'llama3');
  });

  test('keeps every provider config across a save/load round trip', () {
    const original = AppSettings(
      summaryProvider: SummaryProvider.anthropic,
      summaryProviders: {
        SummaryProvider.anthropic: SummaryProviderConfig(
          baseUrl: 'https://api.anthropic.com/v1',
          model: 'claude-opus-4-8',
          apiKey: 'sk-ant-test',
        ),
        SummaryProvider.ollama: SummaryProviderConfig(
          baseUrl: 'http://localhost:11434',
          model: 'gemma3:4b',
        ),
      },
    );

    final restored = AppSettings.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );

    expect(restored.summaryProvider, SummaryProvider.anthropic);
    expect(restored.configFor(SummaryProvider.anthropic).apiKey, 'sk-ant-test');
    expect(restored.configFor(SummaryProvider.ollama).model, 'gemma3:4b');
  });
}

/// A one-shot JSON endpoint that captures the request and replies with [body].
Future<HttpServer> _serve(
  Map<String, dynamic> Function(HttpRequest request, Map<String, dynamic> body)
  handler, {
  int statusCode = HttpStatus.ok,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final payload =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final response = handler(request, payload);
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response));
    await request.response.close();
  });
  return server;
}

Meeting _meeting() => Meeting(
  id: 'meeting-1',
  title: 'Summary test',
  createdAt: DateTime.utc(2026, 7, 24),
  audioPath: '/tmp/meeting.m4a',
  durationSeconds: 10,
  status: MeetingStatus.ready,
  segments: const [
    TranscriptSegment(
      start: 0,
      end: 1,
      speakerId: 'SPEAKER_00',
      text: 'We made a decision.',
    ),
  ],
);
