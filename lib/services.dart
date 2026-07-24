import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class AudioCaptureService {
  static const _channel = MethodChannel('com.lorraine.meeting/audio_capture');

  Future<bool> isSupported() async {
    if (!Platform.isMacOS) return false;
    return await _channel.invokeMethod<bool>('isSupported') ?? false;
  }

  Future<void> start(String outputPath) async {
    await _channel.invokeMethod<void>('start', {'outputPath': outputPath});
  }

  Future<String> stop() async =>
      (await _channel.invokeMethod<String>('stop')) ?? '';
}

class PreparedAudio {
  const PreparedAudio({required this.file, required this.isTemporary});

  final File file;
  final bool isTemporary;

  Future<void> dispose() async {
    if (isTemporary && await file.exists()) await file.delete();
  }
}

class UploadPreparationService {
  Future<PreparedAudio> prepare(Meeting meeting, Directory appRoot) async {
    if (!Platform.isMacOS) {
      return PreparedAudio(file: File(meeting.audioPath), isTemporary: false);
    }
    final directory = Directory('${appRoot.path}/upload_temp');
    await directory.create(recursive: true);
    final pcm = File('${directory.path}/${meeting.id}-upload.caf');
    final output = File('${directory.path}/${meeting.id}-upload.m4a');
    if (await pcm.exists()) await pcm.delete();
    if (await output.exists()) await output.delete();
    try {
      final downmix = await Process.run('/usr/bin/afconvert', [
        meeting.audioPath,
        '-o',
        pcm.path,
        '-f',
        'caff',
        '-d',
        'LEI16@16000',
        '-c',
        '1',
        '--mix',
      ]);
      if (downmix.exitCode != 0) {
        throw ProcessException(
          '/usr/bin/afconvert',
          const [],
          downmix.stderr.toString(),
          downmix.exitCode,
        );
      }
      final encode = await Process.run('/usr/bin/afconvert', [
        pcm.path,
        '-o',
        output.path,
        '-f',
        'm4af',
        '-d',
        'aac ',
        '-b',
        '32000',
        '-q',
        '127',
      ]);
      if (encode.exitCode != 0 || !await output.exists()) {
        throw ProcessException(
          '/usr/bin/afconvert',
          const [],
          encode.stderr.toString(),
          encode.exitCode,
        );
      }
      return PreparedAudio(file: output, isTemporary: true);
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      if (await pcm.exists()) await pcm.delete();
    }
  }
}

enum ModalDeploymentState {
  idle,
  checking,
  deploying,
  ready,
  unavailable,
  failed,
}

class ModalDeploymentResult {
  const ModalDeploymentResult({required this.endpoint, required this.output});

  final String endpoint;
  final String output;
}

class _ModalCliCommand {
  const _ModalCliCommand(this.executable, [this.prefixArguments = const []]);

  final String executable;
  final List<String> prefixArguments;

  Future<ProcessResult> run(List<String> arguments) => Process.run(executable, [
    ...prefixArguments,
    ...arguments,
  ], runInShell: false);

  Future<Process> start(
    List<String> arguments, {
    Map<String, String>? environment,
  }) => Process.start(
    executable,
    [...prefixArguments, ...arguments],
    environment: environment,
    runInShell: false,
  );
}

class ModalDeploymentService {
  Future<ModalDeploymentResult> deploy(Directory appSupportRoot) async {
    final cli = await _findCli();
    if (cli == null) {
      throw const ModalCliUnavailable(
        'Modal CLI was not found. Install it with `python3 -m pip install modal`, then run `modal setup`.',
      );
    }

    final profile = await cli.run(const ['profile', 'current']);
    if (profile.exitCode != 0) {
      throw ModalCliUnavailable(
        'Modal CLI is not authenticated. Run `modal setup`. ${profile.stderr}'
            .trim(),
      );
    }
    final secretName = await _selectSecret(cli);

    final backendDirectory = Directory('${appSupportRoot.path}/backend');
    await backendDirectory.create(recursive: true);
    final script = File('${backendDirectory.path}/modal_app.py');
    final bundled = await rootBundle.loadString('backend/modal_app.py');
    if (!await script.exists() || await script.readAsString() != bundled) {
      await script.writeAsString(bundled, flush: true);
    }

    final process = await cli.start(
      ['deploy', script.path, '--name', 'lorraine-transcription'],
      environment: {'LORRAINE_MODAL_SECRET': secretName},
    );
    final outputFuture = process.stdout.transform(utf8.decoder).join();
    final errorFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    final output = '${await outputFuture}\n${await errorFuture}'.trim();
    if (exitCode != 0) {
      throw ModalDeploymentException(
        output.isEmpty
            ? 'Modal deployment failed with exit code $exitCode.'
            : output,
      );
    }

    final urls = RegExp(
      r'https://[A-Za-z0-9.-]+\.modal\.run',
    ).allMatches(output).map((match) => match.group(0)!).toList();
    if (urls.isEmpty) {
      throw const ModalDeploymentException(
        'Modal deployed successfully, but its endpoint URL was not present in the CLI output.',
      );
    }
    final endpoint = urls.last;
    final health = await http
        .get(Uri.parse('$endpoint/health'))
        .timeout(const Duration(seconds: 90));
    if (health.statusCode != 200) {
      throw ModalDeploymentException(
        'Modal deployed, but its health check returned ${health.statusCode}.',
      );
    }
    return ModalDeploymentResult(endpoint: endpoint, output: output);
  }

  Future<_ModalCliCommand?> _findCli() async {
    final home = Platform.environment['HOME'];
    final candidates = <_ModalCliCommand>[
      const _ModalCliCommand('/opt/homebrew/bin/modal'),
      const _ModalCliCommand('/usr/local/bin/modal'),
      if (home != null) _ModalCliCommand('$home/.local/bin/modal'),
      if (home != null)
        for (var minor = 14; minor >= 9; minor--)
          _ModalCliCommand('$home/Library/Python/3.$minor/bin/modal'),
      const _ModalCliCommand('modal'),
      if (Platform.isWindows) ...const [
        _ModalCliCommand('py', ['-3', '-m', 'modal']),
        _ModalCliCommand('python', ['-m', 'modal']),
      ] else ...const [
        _ModalCliCommand('/usr/bin/python3', ['-m', 'modal']),
        _ModalCliCommand('python3', ['-m', 'modal']),
        _ModalCliCommand('python', ['-m', 'modal']),
      ],
    ];
    for (final candidate in candidates) {
      try {
        final result = await candidate.run(const ['--version']);
        if (result.exitCode == 0) return candidate;
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  Future<String> _selectSecret(_ModalCliCommand cli) async {
    final result = await cli.run(const ['secret', 'list', '--json']);
    if (result.exitCode != 0) {
      throw ModalDeploymentException(
        'Could not inspect Modal secrets: ${result.stderr}'.trim(),
      );
    }
    try {
      final rows = jsonDecode(result.stdout as String) as List<dynamic>;
      final names = rows
          .map((row) => (row as Map<String, dynamic>)['Name']?.toString())
          .whereType<String>()
          .toSet();
      for (final preferred in const [
        'lorraine-secrets',
        'huggingface',
        'huggingface-secret',
      ]) {
        if (names.contains(preferred)) return preferred;
      }
    } on FormatException {
      // Modal's deploy error will provide the actionable secret guidance.
    }
    return 'lorraine-secrets';
  }
}

class ModalCliUnavailable implements Exception {
  const ModalCliUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModalDeploymentException implements Exception {
  const ModalDeploymentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModalClient {
  ModalClient(this.settings);

  static const _chunkSize = 5 * 1024 * 1024;
  static const _chunkAttempts = 4;

  final AppSettings settings;

  Uri _uri(String path) => Uri.parse(
    '${settings.modalBaseUrl.replaceFirst(RegExp(r'/+$'), '')}$path',
  );

  Map<String, String> get _headers => {
    if (settings.apiKey.isNotEmpty)
      'Authorization': 'Bearer ${settings.apiKey}',
  };

  Future<String> submit(
    Meeting meeting,
    List<SpeakerProfile> profiles, {
    File? audioFile,
    ValueChanged<double>? onUploadProgress,
  }) async {
    final audio = audioFile ?? File(meeting.audioPath);
    final totalBytes = await audio.length();
    final chunkCount = (totalBytes / _chunkSize).ceil();
    final audioHash = await sha256.bind(audio.openRead()).first;
    final initialized = _decode(
      await http
          .post(
            _uri('/uploads'),
            headers: _headers,
            body: {
              'meeting_id': meeting.id,
              'filename': audio.uri.pathSegments.last,
              'known_profiles': jsonEncode(
                profiles.map((profile) => profile.toApiJson()).toList(),
              ),
              'match_threshold': settings.matchThreshold.toString(),
              'total_bytes': totalBytes.toString(),
              'chunk_count': chunkCount.toString(),
              'audio_sha256': audioHash.toString(),
            },
          )
          .timeout(const Duration(minutes: 2)),
    );
    final jobId = initialized['job_id'] as String;
    final input = await audio.open();
    var uploaded = 0;
    onUploadProgress?.call(0);
    try {
      for (var index = 0; index < chunkCount; index++) {
        final chunk = await input.read(_chunkSize);
        await _uploadChunk(jobId, index, chunk);
        uploaded += chunk.length;
        onUploadProgress?.call(
          totalBytes == 0 ? 1 : (uploaded / totalBytes).clamp(0, 1),
        );
      }
      _decode(
        await http
            .post(_uri('/uploads/$jobId/complete'), headers: _headers)
            .timeout(const Duration(minutes: 5)),
      );
      onUploadProgress?.call(1);
      return jobId;
    } finally {
      await input.close();
    }
  }

  Future<void> _uploadChunk(String jobId, int index, List<int> bytes) async {
    Object? lastError;
    for (var attempt = 0; attempt < _chunkAttempts; attempt++) {
      try {
        final response = await http
            .put(
              _uri('/uploads/$jobId/chunks/$index'),
              headers: {
                ..._headers,
                'Content-Type': 'application/octet-stream',
                'X-Chunk-SHA256': sha256.convert(bytes).toString(),
              },
              body: bytes,
            )
            .timeout(const Duration(minutes: 5));
        _decode(response);
        return;
      } catch (error) {
        lastError = error;
        if (attempt + 1 < _chunkAttempts) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    throw HttpException(
      'Chunk ${index + 1} could not be uploaded after $_chunkAttempts attempts: '
      '$lastError',
    );
  }

  Future<Map<String, dynamic>> job(String id) async {
    final response = await http
        .get(_uri('/jobs/$id'), headers: _headers)
        .timeout(const Duration(seconds: 45));
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        body['detail']?.toString() ?? 'Modal returned ${response.statusCode}',
      );
    }
    return body;
  }
}

class LocalSummaryService {
  Future<String> summarize(Meeting meeting, AppSettings settings) async {
    final transcript = meeting.segments
        .map((segment) => '[${segment.speakerId}] ${segment.text}')
        .join('\n');
    final limited = transcript.length > 100000
        ? transcript.substring(0, 100000)
        : transcript;
    final prompt =
        '''Summarize this meeting transcript. Return concise Markdown with these exact sections: Summary, Decisions, Action items, Open questions. Preserve names as shown and do not invent facts. If a section has no items, say "None recorded".\n\n$limited''';
    final base = settings.ollamaUrl.replaceFirst(RegExp(r'/+$'), '');
    final response = await http
        .post(
          Uri.parse('$base/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': settings.ollamaModel,
            'prompt': prompt,
            'stream': false,
          }),
        )
        .timeout(const Duration(minutes: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Ollama returned ${response.statusCode}: ${response.body}',
      );
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['response']
            as String? ??
        '';
  }
}
