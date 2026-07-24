import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lorraine/models.dart';
import 'package:lorraine/services.dart';

void main() {
  test(
    'reports streaming upload progress while submitting a meeting',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var chunksReceived = 0;
      var completed = false;
      server.listen((request) async {
        final body = await request.fold<List<int>>(
          <int>[],
          (bytes, chunk) => bytes..addAll(chunk),
        );
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'POST' && request.uri.path == '/uploads') {
          request.response
            ..statusCode = HttpStatus.created
            ..write(jsonEncode({'job_id': 'job-1'}));
        } else if (request.method == 'PUT' &&
            request.uri.path == '/uploads/job-1/chunks/0') {
          chunksReceived++;
          expect(body, isNotEmpty);
          expect(
            request.headers.value('x-chunk-sha256'),
            sha256.convert(body).toString(),
          );
          request.response.write(jsonEncode({'received': 0}));
        } else if (request.method == 'POST' &&
            request.uri.path == '/uploads/job-1/complete') {
          completed = true;
          request.response
            ..statusCode = HttpStatus.accepted
            ..write(jsonEncode({'job_id': 'job-1'}));
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write(jsonEncode({'detail': 'not found'}));
        }
        await request.response.close();
      });
      final temporary = await Directory.systemTemp.createTemp(
        'lorraine-upload-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final audio = File('${temporary.path}/meeting.m4a');
      await audio.writeAsBytes(List<int>.filled(32 * 1024, 7));
      final progress = <double>[];
      final meeting = Meeting(
        id: 'meeting-1',
        title: 'Upload test',
        createdAt: DateTime.utc(2026, 7, 24),
        audioPath: audio.path,
        durationSeconds: 10,
        status: MeetingStatus.recorded,
      );

      final jobId = await ModalClient(
        AppSettings(modalBaseUrl: 'http://127.0.0.1:${server.port}'),
      ).submit(meeting, const [], onUploadProgress: progress.add);

      expect(jobId, 'job-1');
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(progress.every((value) => value >= 0 && value <= 1), isTrue);
      expect(chunksReceived, 1);
      expect(completed, isTrue);
    },
  );
}
