import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Protocol revisions of the Model Context Protocol this server understands.
const supportedProtocolVersions = ['2024-11-05', '2025-03-26', '2025-06-18'];

/// Version reported in the MCP `initialize` handshake.
const mcpServerVersion = '1.0.0';

/// Read-only access to the meeting history the app persists in `state.json`.
///
/// The store deliberately parses only meetings and speaker profiles. The
/// settings block — which holds the Modal and summarization API keys — is
/// never decoded, so credentials cannot reach an MCP client even by accident.
class MeetingStore {
  MeetingStore(this.statePath);

  static const _bundleIdentifier = 'com.lorraine.meeting.lorraine';

  /// Absolute path of the `state.json` snapshot to read.
  final String statePath;

  /// Resolves the state file the app itself would use: a `LORRAINE_STATE`
  /// override, then the current Application Support location, then the legacy
  /// sandbox container. Falls back to the current location when none exists
  /// yet, so a fresh install serves an empty history instead of failing.
  static String defaultStatePath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final override = env['LORRAINE_STATE'];
    if (override != null && override.trim().isNotEmpty) return override;
    final home = env['HOME'] ?? '';
    final current =
        '$home/Library/Application Support/$_bundleIdentifier/'
        'Lorraine/state.json';
    final legacy =
        '$home/Library/Containers/$_bundleIdentifier/Data/Library/'
        'Application Support/$_bundleIdentifier/Lorraine/state.json';
    if (File(current).existsSync()) return current;
    if (File(legacy).existsSync()) return legacy;
    return current;
  }

  /// Reads a fresh snapshot on every call so results include meetings
  /// recorded while the server is running. The app replaces `state.json`
  /// atomically via rename, so a read never observes a partial file.
  MeetingSnapshot load() {
    final file = File(statePath);
    if (!file.existsSync()) {
      return const MeetingSnapshot(meetings: [], profiles: []);
    }
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return MeetingSnapshot(
      meetings: (raw['meetings'] as List<dynamic>? ?? const [])
          .map((item) => Meeting.fromJson(item as Map<String, dynamic>))
          .toList(),
      profiles: (raw['profiles'] as List<dynamic>? ?? const [])
          .map((item) => SpeakerProfile.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// The meetings and speaker profiles read from one `state.json` snapshot.
class MeetingSnapshot {
  const MeetingSnapshot({required this.meetings, required this.profiles});

  final List<Meeting> meetings;
  final List<SpeakerProfile> profiles;
}

class _JsonRpcFailure implements Exception {
  const _JsonRpcFailure(this.code, this.message);

  final int code;
  final String message;
}

class _ToolFailure implements Exception {
  const _ToolFailure(this.message);

  final String message;
}

/// A minimal MCP server (JSON-RPC 2.0 over newline-delimited stdio) exposing
/// read-only query tools over the local meeting history.
///
/// Nothing here talks to the network, mutates state, or surfaces audio
/// paths, voice embeddings, or API keys — it reads `state.json` and returns
/// text.
class LorraineMcpServer {
  LorraineMcpServer(this.store);

  final MeetingStore store;

  static const _maxSnippetsPerMeeting = 5;
  static const _maxSnippetLength = 240;

  /// Tool metadata reported by `tools/list`.
  static const toolDefinitions = [
    {
      'name': 'list_meetings',
      'description':
          'List recorded meetings, newest first, with id, title, date, '
          'duration, transcription status, speaker names, and whether a '
          'transcript and summary exist. Optionally filter by a '
          'case-insensitive title substring and an ISO-8601 date range.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Case-insensitive substring to match against meeting titles.',
          },
          'from': {
            'type': 'string',
            'description':
                'Earliest meeting to include, ISO-8601 (e.g. 2026-08-01). '
                'Inclusive.',
          },
          'to': {
            'type': 'string',
            'description':
                'Latest meeting to include, ISO-8601. A bare date includes '
                'that whole day.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum meetings to return. Defaults to 25.',
          },
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_transcript',
      'description':
          'Return the raw speaker-labelled transcript of one meeting as '
          'timestamped lines, with anonymous speaker labels resolved to '
          'enrolled names where the person is known.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'meeting_id': {
            'type': 'string',
            'description':
                'Meeting id (or unique id prefix) from list_meetings or '
                'search_meetings.',
          },
        },
        'required': ['meeting_id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_summary',
      'description':
          'Return the stored Markdown summary (synopsis) of one meeting, if '
          'one has been generated in the app.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'meeting_id': {
            'type': 'string',
            'description':
                'Meeting id (or unique id prefix) from list_meetings or '
                'search_meetings.',
          },
        },
        'required': ['meeting_id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'search_meetings',
      'description':
          'Case-insensitive full-text search across meeting titles, '
          'summaries, and transcript text. Returns matching meetings, newest '
          'first, each with a few matching snippets.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Text to find (case-insensitive substring).',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Maximum matching meetings to return. Defaults to 10.',
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
  ];

  /// Reads newline-delimited JSON-RPC messages from [input] and writes one
  /// response line per request to [output] until [input] closes.
  Future<void> serve({
    required Stream<List<int>> input,
    required StringSink output,
  }) async {
    final lines = const LineSplitter().bind(utf8.decoder.bind(input));
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        output.writeln(jsonEncode(_error(null, -32700, 'Parse error')));
        continue;
      }
      if (decoded is! Map<String, dynamic>) {
        output.writeln(
          jsonEncode(_error(null, -32600, 'Request must be a JSON object')),
        );
        continue;
      }
      final response = handleMessage(decoded);
      if (response != null) output.writeln(jsonEncode(response));
    }
  }

  /// Handles one JSON-RPC message; returns null for notifications and client
  /// responses, which expect no reply.
  Map<String, dynamic>? handleMessage(Map<String, dynamic> message) {
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      return id == null ? null : _error(id, -32600, 'Request has no method');
    }
    if (id == null) return null;
    final params = message['params'];
    final arguments = params is Map<String, dynamic>
        ? params
        : <String, dynamic>{};
    try {
      final result = switch (method) {
        'initialize' => _initialize(arguments),
        'ping' => <String, dynamic>{},
        'tools/list' => {'tools': toolDefinitions},
        'tools/call' => _callTool(arguments),
        _ => throw _JsonRpcFailure(-32601, 'Method not found: $method'),
      };
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on _JsonRpcFailure catch (failure) {
      return _error(id, failure.code, failure.message);
    } catch (error) {
      return _error(id, -32603, 'Internal error: $error');
    }
  }

  Map<String, dynamic> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  Map<String, dynamic> _initialize(Map<String, dynamic> params) {
    final requested = params['protocolVersion'] as String?;
    return {
      'protocolVersion': supportedProtocolVersions.contains(requested)
          ? requested
          : supportedProtocolVersions.last,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': 'lorraine', 'version': mcpServerVersion},
      'instructions':
          'Read-only access to the Lorraine meeting history stored on this '
          'Mac. Use list_meetings or search_meetings to find a meeting id, '
          'then get_transcript for the raw speaker-labelled notes or '
          'get_summary for the synopsis.',
    };
  }

  Map<String, dynamic> _callTool(Map<String, dynamic> params) {
    final name = params['name'];
    final rawArguments = params['arguments'];
    final arguments = rawArguments is Map<String, dynamic>
        ? rawArguments
        : <String, dynamic>{};
    final MeetingSnapshot snapshot;
    try {
      snapshot = store.load();
    } on FormatException catch (error) {
      return _toolError('Could not parse ${store.statePath}: $error');
    } on FileSystemException catch (error) {
      return _toolError('Could not read ${store.statePath}: $error');
    }
    try {
      return switch (name) {
        'list_meetings' => _listMeetings(snapshot, arguments),
        'get_transcript' => _getTranscript(snapshot, arguments),
        'get_summary' => _getSummary(snapshot, arguments),
        'search_meetings' => _searchMeetings(snapshot, arguments),
        _ => throw _JsonRpcFailure(-32602, 'Unknown tool: $name'),
      };
    } on _ToolFailure catch (failure) {
      return _toolError(failure.message);
    }
  }

  Map<String, dynamic> _toolText(String text) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': false,
  };

  Map<String, dynamic> _toolError(String text) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': true,
  };

  Map<String, dynamic> _listMeetings(
    MeetingSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final query = (arguments['query'] as String? ?? '').trim().toLowerCase();
    final from = _parseInstant(arguments['from'], 'from');
    final to = _parseInstant(arguments['to'], 'to', endOfDay: true);
    final limit = (arguments['limit'] as num?)?.toInt() ?? 25;
    if (limit < 1) throw const _ToolFailure('limit must be at least 1');

    final profilesById = _profilesById(snapshot);
    final matched =
        snapshot.meetings
            .where(
              (meeting) =>
                  (query.isEmpty ||
                      meeting.title.toLowerCase().contains(query)) &&
                  (from == null || !meeting.createdAt.isBefore(from)) &&
                  (to == null || meeting.createdAt.isBefore(to)),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final shown = matched.take(limit).toList();
    return _toolText(
      prettyJson({
        'total_meetings': snapshot.meetings.length,
        'matched': matched.length,
        'returned': shown.length,
        'meetings': [
          for (final meeting in shown) _meetingCard(meeting, profilesById),
        ],
      }),
    );
  }

  Map<String, dynamic> _getTranscript(
    MeetingSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final meeting = _requireMeeting(snapshot, arguments);
    final profilesById = _profilesById(snapshot);
    final header = StringBuffer()
      ..writeln('# ${meeting.title}')
      ..writeln('- id: ${meeting.id}')
      ..writeln('- recorded: ${meeting.createdAt.toIso8601String()}')
      ..writeln('- duration: ${_formatDuration(meeting.durationSeconds)}')
      ..writeln('- status: ${meeting.status.name}');
    final language = meeting.language;
    if (language != null) header.writeln('- language: $language');

    if (meeting.segments.isEmpty) {
      header
        ..writeln()
        ..writeln(_missingTranscriptReason(meeting));
      return _toolText(header.toString());
    }

    if (meeting.speakers.isNotEmpty) {
      header
        ..writeln()
        ..writeln('Speakers:');
      for (final speaker in meeting.speakers) {
        header.writeln(_speakerLegendLine(speaker, profilesById));
      }
    }
    header
      ..writeln()
      ..writeln('Transcript:');
    for (final segment in meeting.segments) {
      final name = _segmentSpeakerName(
        segment.speakerId,
        meeting,
        profilesById,
      );
      header.writeln(
        '[${_formatTimestamp(segment.start)}] $name: ${segment.text.trim()}',
      );
    }
    return _toolText(header.toString());
  }

  Map<String, dynamic> _getSummary(
    MeetingSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final meeting = _requireMeeting(snapshot, arguments);
    final summary = meeting.summary;
    if (summary == null || summary.trim().isEmpty) {
      return _toolText(
        'No summary has been generated for "${meeting.title}" '
        '(${meeting.id}, recorded ${meeting.createdAt.toIso8601String()}). '
        'Summaries are generated on demand in the Lorraine app. '
        '${meeting.segments.isEmpty ? _missingTranscriptReason(meeting) : 'The transcript exists — use get_transcript to read it.'}',
      );
    }
    return _toolText(
      'Summary of "${meeting.title}" '
      '(${meeting.id}, recorded ${meeting.createdAt.toIso8601String()}):\n\n'
      '$summary',
    );
  }

  Map<String, dynamic> _searchMeetings(
    MeetingSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final query = (arguments['query'] as String? ?? '').trim();
    if (query.isEmpty) throw const _ToolFailure('query must not be empty');
    final needle = query.toLowerCase();
    final limit = (arguments['limit'] as num?)?.toInt() ?? 10;
    if (limit < 1) throw const _ToolFailure('limit must be at least 1');

    final profilesById = _profilesById(snapshot);
    final sorted = [...snapshot.meetings]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final results = <Map<String, dynamic>>[];
    for (final meeting in sorted) {
      final snippets = <Map<String, String>>[];
      var matchCount = 0;
      void addMatch(String where, String snippet) {
        matchCount++;
        if (snippets.length < _maxSnippetsPerMeeting) {
          snippets.add({'where': where, 'snippet': _clip(snippet)});
        }
      }

      if (meeting.title.toLowerCase().contains(needle)) {
        addMatch('title', meeting.title);
      }
      final summary = meeting.summary;
      if (summary != null) {
        for (final line in const LineSplitter().convert(summary)) {
          if (line.toLowerCase().contains(needle)) {
            addMatch('summary', line.trim());
          }
        }
      }
      for (final segment in meeting.segments) {
        if (segment.text.toLowerCase().contains(needle)) {
          final name = _segmentSpeakerName(
            segment.speakerId,
            meeting,
            profilesById,
          );
          addMatch(
            'transcript',
            '[${_formatTimestamp(segment.start)}] $name: '
                '${segment.text.trim()}',
          );
        }
      }
      if (matchCount == 0) continue;
      results.add({
        'id': meeting.id,
        'title': meeting.title,
        'created_at': meeting.createdAt.toIso8601String(),
        'match_count': matchCount,
        'snippets': snippets,
      });
    }
    return _toolText(
      prettyJson({
        'query': query,
        'matched_meetings': results.length,
        'results': results.take(limit).toList(),
      }),
    );
  }

  Map<String, dynamic> _meetingCard(
    Meeting meeting,
    Map<String, SpeakerProfile> profilesById,
  ) => {
    'id': meeting.id,
    'title': meeting.title,
    'created_at': meeting.createdAt.toIso8601String(),
    'duration': _formatDuration(meeting.durationSeconds),
    'status': meeting.status.name,
    if (meeting.language != null) 'language': meeting.language,
    'has_transcript': meeting.segments.isNotEmpty,
    'has_summary': meeting.summary?.trim().isNotEmpty ?? false,
    'speakers': [
      for (final speaker in meeting.speakers)
        _speakerDisplayName(speaker, profilesById),
    ],
    if (meeting.error != null) 'error': meeting.error,
  };

  Meeting _requireMeeting(
    MeetingSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final idOrPrefix = (arguments['meeting_id'] as String? ?? '').trim();
    if (idOrPrefix.isEmpty) {
      throw const _ToolFailure('meeting_id must not be empty');
    }
    for (final meeting in snapshot.meetings) {
      if (meeting.id == idOrPrefix) return meeting;
    }
    final prefixed = snapshot.meetings
        .where((meeting) => meeting.id.startsWith(idOrPrefix))
        .toList();
    if (prefixed.length == 1) return prefixed.first;
    if (prefixed.length > 1) {
      throw _ToolFailure(
        'Meeting id prefix "$idOrPrefix" is ambiguous: '
        '${prefixed.map((meeting) => meeting.id).join(', ')}',
      );
    }
    throw _ToolFailure(
      'No meeting with id "$idOrPrefix". Use list_meetings to see the '
      '${snapshot.meetings.length} known meeting(s).',
    );
  }

  Map<String, SpeakerProfile> _profilesById(MeetingSnapshot snapshot) => {
    for (final profile in snapshot.profiles) profile.id: profile,
  };

  String _speakerDisplayName(
    MeetingSpeaker speaker,
    Map<String, SpeakerProfile> profilesById,
  ) {
    final profile = profilesById[speaker.profileId];
    return profile?.name ?? '${speaker.id} (unidentified)';
  }

  String _speakerLegendLine(
    MeetingSpeaker speaker,
    Map<String, SpeakerProfile> profilesById,
  ) {
    final profile = profilesById[speaker.profileId];
    if (profile == null) return '- ${speaker.id}: unidentified';
    final email = profile.email.trim().isEmpty ? '' : ' <${profile.email}>';
    final confidence = speaker.matchConfidence;
    final basis = speaker.identityConfirmed
        ? 'identity confirmed in the app'
        : 'matched by voice'
              '${confidence == null ? '' : ', similarity ${confidence.toStringAsFixed(2)}'}';
    return '- ${speaker.id}: ${profile.name}$email ($basis)';
  }

  String _segmentSpeakerName(
    String speakerId,
    Meeting meeting,
    Map<String, SpeakerProfile> profilesById,
  ) {
    for (final speaker in meeting.speakers) {
      if (speaker.id == speakerId) {
        return profilesById[speaker.profileId]?.name ?? speakerId;
      }
    }
    return speakerId;
  }

  String _missingTranscriptReason(Meeting meeting) => switch (meeting.status) {
    MeetingStatus.recorded =>
      'This meeting has been recorded but not transcribed yet.',
    MeetingStatus.uploading || MeetingStatus.processing =>
      'Transcription is still in progress'
          '${meeting.processingStage == null ? '' : ' (${meeting.processingStage})'}.',
    MeetingStatus.failed =>
      'Transcription failed'
          '${meeting.error == null ? '' : ': ${meeting.error}'}',
    MeetingStatus.ready => 'The transcript is empty.',
  };

  DateTime? _parseInstant(Object? raw, String name, {bool endOfDay = false}) {
    if (raw == null) return null;
    if (raw is! String || raw.trim().isEmpty) {
      throw _ToolFailure('$name must be an ISO-8601 date string');
    }
    final text = raw.trim();
    final DateTime parsed;
    try {
      parsed = DateTime.parse(text);
    } on FormatException {
      throw _ToolFailure('$name is not a valid ISO-8601 date: "$text"');
    }
    final dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text);
    return endOfDay && dateOnly ? parsed.add(const Duration(days: 1)) : parsed;
  }

  String _clip(String text) => text.length <= _maxSnippetLength
      ? text
      : '${text.substring(0, _maxSnippetLength)}…';

  String _formatDuration(int seconds) => _formatTimestamp(seconds.toDouble());

  String _formatTimestamp(double seconds) {
    final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final remainder = (total % 60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$remainder'
        : '$minutes:$remainder';
  }
}
