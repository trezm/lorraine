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

  /// Seconds since either audio track last carried sound above the speech
  /// threshold, or null when unknown (no active recording, or a platform
  /// without level monitoring).
  Future<double?> silenceSeconds() async {
    try {
      return await _channel.invokeMethod<double>('silenceSeconds');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
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
              'enriched_match_threshold': settings.enrichedMatchThreshold
                  .toString(),
              'match_margin': settings.matchMargin.toString(),
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

class SummaryService {
  static const _systemPrompt =
      'Summarize this meeting transcript. Return concise Markdown with these '
      'exact sections: Summary, Decisions, Action items, Open questions. '
      'Use the authoritative speaker identity mapping whenever attributing '
      'statements or action items. Preserve unidentified speaker labels as '
      'shown and do not invent facts. If a section has no items, say '
      '"None recorded".';

  /// Anthropic requires an explicit cap; the OpenAI dialect and Ollama use
  /// their own server-side defaults when it is omitted.
  static const _maxTokens = 16000;

  Future<String> summarize(
    Meeting meeting,
    AppSettings settings, {
    Map<String, String> speakerNames = const {},
    ValueChanged<SummaryProgress>? onProgress,
  }) async {
    final provider = settings.summaryProvider;
    final config = settings.summaryConfig;
    final model = config.model.trim();
    if (model.isEmpty) {
      throw const SummaryConfigurationException(
        'No summarization model is set. Choose one in Settings.',
      );
    }
    if (provider.requiresApiKey && config.apiKey.trim().isEmpty) {
      throw SummaryConfigurationException(
        '${provider.label} needs an API key. Add one in Settings.',
      );
    }

    String displayName(String speakerId) {
      final identified = speakerNames[speakerId]?.trim();
      if (identified == null || identified.isEmpty) return speakerId;
      return identified.replaceAll(RegExp(r'\s+'), ' ');
    }

    final transcript = meeting.segments
        .map((segment) => '[${displayName(segment.speakerId)}] ${segment.text}')
        .join('\n');
    final limited = transcript.length > 100000
        ? transcript.substring(0, 100000)
        : transcript;
    final identities =
        speakerNames.entries
            .where((entry) => entry.value.trim().isNotEmpty)
            .map(
              (entry) =>
                  '${entry.key} = ${entry.value.trim().replaceAll(RegExp(r'\s+'), ' ')}',
            )
            .toList()
          ..sort();
    final identityMapping = identities.isEmpty
        ? 'No speakers have been identified.'
        : identities.join('\n');
    final summaryInput =
        'Speaker identity mapping:\n$identityMapping\n\nTranscript:\n$limited';
    final base = config.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

    return switch (provider) {
      SummaryProvider.ollama => _summarizeWithOllama(
        base,
        model,
        summaryInput,
        onProgress: onProgress,
      ),
      SummaryProvider.anthropic => _summarizeWithAnthropic(
        base,
        model,
        config.apiKey.trim(),
        summaryInput,
        onProgress: onProgress,
      ),
      SummaryProvider.openai ||
      SummaryProvider.openaiCompatible ||
      SummaryProvider.openRouter => _summarizeWithOpenAi(
        provider,
        base,
        model,
        config.apiKey.trim(),
        summaryInput,
        onProgress: onProgress,
      ),
    };
  }

  Future<String> _summarizeWithOllama(
    String base,
    String model,
    String transcript, {
    ValueChanged<SummaryProgress>? onProgress,
  }) async {
    await _ensureModel(base, model, onProgress: onProgress);
    onProgress?.call(
      SummaryProgress(message: 'Generating summary with $model…'),
    );
    final response = await http
        .post(
          Uri.parse('$base/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'system': _systemPrompt,
            'prompt': transcript,
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

  /// OpenAI, OpenRouter, and any other server implementing
  /// `POST /chat/completions`.
  Future<String> _summarizeWithOpenAi(
    SummaryProvider provider,
    String base,
    String model,
    String apiKey,
    String transcript, {
    ValueChanged<SummaryProgress>? onProgress,
  }) async {
    onProgress?.call(
      SummaryProgress(message: 'Generating summary with $model…'),
    );
    final response = await http
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            // OpenRouter names the calling app on its activity page.
            if (provider == SummaryProvider.openRouter) 'X-Title': 'Lorraine',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': _systemPrompt},
              {'role': 'user', 'content': transcript},
            ],
            'stream': false,
          }),
        )
        .timeout(const Duration(minutes: 5));
    final body = _decodeSummaryResponse(provider.label, response);
    final choices = body['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) return '';
    final message =
        (choices.first as Map<String, dynamic>)['message']
            as Map<String, dynamic>?;
    return message?['content'] as String? ?? '';
  }

  /// Anthropic's Messages API, which does not follow the OpenAI dialect:
  /// `x-api-key` instead of bearer auth, a top-level `system` string, and a
  /// content-block array in the response.
  Future<String> _summarizeWithAnthropic(
    String base,
    String model,
    String apiKey,
    String transcript, {
    ValueChanged<SummaryProgress>? onProgress,
  }) async {
    onProgress?.call(
      SummaryProgress(message: 'Generating summary with $model…'),
    );
    final response = await http
        .post(
          Uri.parse('$base/messages'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': _maxTokens,
            'system': _systemPrompt,
            'messages': [
              {'role': 'user', 'content': transcript},
            ],
          }),
        )
        .timeout(const Duration(minutes: 5));
    final body = _decodeSummaryResponse('Anthropic', response);
    if (body['stop_reason'] == 'refusal') {
      throw const HttpException(
        'Anthropic declined to summarize this transcript.',
      );
    }
    return (body['content'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'] as String? ?? '')
        .join();
  }

  /// Both cloud dialects report failures as `{"error": {"message": ...}}`.
  Map<String, dynamic> _decodeSummaryResponse(
    String label,
    http.Response response,
  ) {
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      body = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body?['error'];
      final detail = error is Map<String, dynamic>
          ? error['message']?.toString()
          : error?.toString();
      throw HttpException(
        '$label returned ${response.statusCode}: '
        '${detail ?? response.body}',
      );
    }
    if (body == null) {
      throw HttpException('$label returned an unreadable response.');
    }
    return body;
  }

  Future<void> _ensureModel(
    String base,
    String model, {
    ValueChanged<SummaryProgress>? onProgress,
  }) async {
    onProgress?.call(
      SummaryProgress(message: 'Checking for local model $model…'),
    );
    final show = await http
        .post(
          Uri.parse('$base/api/show'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': model}),
        )
        .timeout(const Duration(seconds: 15));
    if (show.statusCode >= 200 && show.statusCode < 300) return;
    if (show.statusCode != HttpStatus.notFound) {
      throw HttpException(
        'Could not check Ollama model $model: '
        '${show.statusCode} ${_ollamaError(show.body)}',
      );
    }

    onProgress?.call(
      SummaryProgress(message: 'Downloading $model…', progress: 0),
    );
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse('$base/api/pull'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'model': model, 'stream': true});
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw HttpException(
          'Could not download Ollama model $model: '
          '${response.statusCode} ${_ollamaError(body)}',
        );
      }

      var completed = false;
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(minutes: 30));
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final update = jsonDecode(line) as Map<String, dynamic>;
        final error = update['error']?.toString();
        if (error != null && error.isNotEmpty) {
          throw HttpException('Could not download Ollama model $model: $error');
        }
        final status = update['status']?.toString() ?? 'Downloading';
        final total = (update['total'] as num?)?.toDouble();
        final downloaded = (update['completed'] as num?)?.toDouble();
        final progress = total != null && total > 0 && downloaded != null
            ? (downloaded / total).clamp(0.0, 1.0)
            : null;
        onProgress?.call(
          SummaryProgress(
            message: status == 'success' ? '$model is ready.' : status,
            progress: status == 'success' ? 1 : progress,
          ),
        );
        if (status == 'success') completed = true;
      }
      if (!completed) {
        throw HttpException(
          'Ollama ended the $model download before reporting success.',
        );
      }
    } finally {
      client.close();
    }
  }

  String _ollamaError(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return decoded['error']?.toString() ?? body;
    } on FormatException {
      return body;
    }
  }
}

class SummaryProgress {
  const SummaryProgress({required this.message, this.progress});

  final String message;
  final double? progress;
}

/// Raised before any request when the chosen provider is missing a model or
/// key, so the user is pointed at Settings instead of a transport error.
class SummaryConfigurationException implements Exception {
  const SummaryConfigurationException(this.message);
  final String message;
  @override
  String toString() => message;
}
