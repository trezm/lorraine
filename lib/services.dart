import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  final AppSettings settings;

  Uri _uri(String path) => Uri.parse(
    '${settings.modalBaseUrl.replaceFirst(RegExp(r'/+$'), '')}$path',
  );

  Map<String, String> get _headers => {
    if (settings.apiKey.isNotEmpty)
      'Authorization': 'Bearer ${settings.apiKey}',
  };

  Future<String> submit(Meeting meeting, List<SpeakerProfile> profiles) async {
    final request = http.MultipartRequest('POST', _uri('/jobs'));
    request.headers.addAll(_headers);
    request.fields['meeting_id'] = meeting.id;
    request.fields['known_profiles'] = jsonEncode(
      profiles.map((profile) => profile.toApiJson()).toList(),
    );
    request.fields['match_threshold'] = settings.matchThreshold.toString();
    request.files.add(
      await http.MultipartFile.fromPath('audio', meeting.audioPath),
    );
    final streamed = await request.send().timeout(const Duration(minutes: 10));
    final response = await http.Response.fromStream(streamed);
    final body = _decode(response);
    return body['job_id'] as String;
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
