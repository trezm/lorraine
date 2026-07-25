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
    final progress = <LocalSummaryProgress>[];
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

    final summary = await LocalSummaryService().summarize(
      meeting,
      AppSettings(
        ollamaUrl: 'http://127.0.0.1:${server.port}',
        ollamaModel: 'gemma3:4b',
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

    final summary = await LocalSummaryService().summarize(
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
        ollamaUrl: 'http://127.0.0.1:${server.port}',
        ollamaModel: 'gemma3:4b',
      ),
    );

    expect(summary, 'Already installed');
    expect(requests, ['/api/show', '/api/generate']);
  });
}
