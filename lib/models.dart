import 'dart:convert';

enum MeetingStatus { recorded, uploading, processing, ready, failed }

class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.speakerId,
    required this.text,
  });

  final double start;
  final double end;
  final String speakerId;
  final String text;

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        speakerId: json['speaker_id'] as String? ?? 'SPEAKER_UNKNOWN',
        text: json['text'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'speaker_id': speakerId,
    'text': text,
  };
}

class MeetingSpeaker {
  const MeetingSpeaker({
    required this.id,
    required this.embedding,
    this.samplePath,
    this.profileId,
    this.matchConfidence,
  });

  final String id;
  final List<double> embedding;
  final String? samplePath;
  final String? profileId;
  final double? matchConfidence;

  MeetingSpeaker copyWith({String? samplePath, String? profileId}) =>
      MeetingSpeaker(
        id: id,
        embedding: embedding,
        samplePath: samplePath ?? this.samplePath,
        profileId: profileId ?? this.profileId,
        matchConfidence: matchConfidence,
      );

  factory MeetingSpeaker.fromJson(Map<String, dynamic> json) => MeetingSpeaker(
    id: json['id'] as String,
    embedding: (json['embedding'] as List<dynamic>? ?? const [])
        .map((value) => (value as num).toDouble())
        .toList(),
    samplePath: json['sample_path'] as String?,
    profileId: json['profile_id'] as String?,
    matchConfidence: (json['match_confidence'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'embedding': embedding,
    'sample_path': samplePath,
    'profile_id': profileId,
    'match_confidence': matchConfidence,
  };
}

class Meeting {
  const Meeting({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.audioPath,
    required this.durationSeconds,
    required this.status,
    this.jobId,
    this.language,
    this.summary,
    this.error,
    this.segments = const [],
    this.speakers = const [],
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final String audioPath;
  final int durationSeconds;
  final MeetingStatus status;
  final String? jobId;
  final String? language;
  final String? summary;
  final String? error;
  final List<TranscriptSegment> segments;
  final List<MeetingSpeaker> speakers;

  Meeting copyWith({
    MeetingStatus? status,
    String? jobId,
    String? language,
    String? summary,
    String? error,
    List<TranscriptSegment>? segments,
    List<MeetingSpeaker>? speakers,
  }) => Meeting(
    id: id,
    title: title,
    createdAt: createdAt,
    audioPath: audioPath,
    durationSeconds: durationSeconds,
    status: status ?? this.status,
    jobId: jobId ?? this.jobId,
    language: language ?? this.language,
    summary: summary ?? this.summary,
    error: error,
    segments: segments ?? this.segments,
    speakers: speakers ?? this.speakers,
  );

  factory Meeting.fromJson(Map<String, dynamic> json) => Meeting(
    id: json['id'] as String,
    title: json['title'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    audioPath: json['audio_path'] as String,
    durationSeconds: json['duration_seconds'] as int? ?? 0,
    status: MeetingStatus.values.byName(json['status'] as String),
    jobId: json['job_id'] as String?,
    language: json['language'] as String?,
    summary: json['summary'] as String?,
    error: json['error'] as String?,
    segments: (json['segments'] as List<dynamic>? ?? const [])
        .map((item) => TranscriptSegment.fromJson(item as Map<String, dynamic>))
        .toList(),
    speakers: (json['speakers'] as List<dynamic>? ?? const [])
        .map((item) => MeetingSpeaker.fromJson(item as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'created_at': createdAt.toIso8601String(),
    'audio_path': audioPath,
    'duration_seconds': durationSeconds,
    'status': status.name,
    'job_id': jobId,
    'language': language,
    'summary': summary,
    'error': error,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    'speakers': speakers.map((speaker) => speaker.toJson()).toList(),
  };
}

class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.embedding,
    required this.samplePath,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final List<double> embedding;
  final String samplePath;
  final DateTime createdAt;

  factory SpeakerProfile.fromJson(Map<String, dynamic> json) => SpeakerProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    email: json['email'] as String? ?? '',
    embedding: (json['embedding'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(),
    samplePath: json['sample_path'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'embedding': embedding,
    'sample_path': samplePath,
    'created_at': createdAt.toIso8601String(),
  };

  Map<String, dynamic> toApiJson() => {
    'id': id,
    'name': name,
    'embedding': embedding,
  };
}

class AppSettings {
  const AppSettings({
    this.modalBaseUrl = '',
    this.apiKey = '',
    this.autoDeployModal = true,
    this.ollamaUrl = 'http://localhost:11434',
    this.ollamaModel = 'gemma3:4b',
    this.matchThreshold = 0.72,
  });

  final String modalBaseUrl;
  final String apiKey;
  final bool autoDeployModal;
  final String ollamaUrl;
  final String ollamaModel;
  final double matchThreshold;

  bool get modalConfigured => modalBaseUrl.trim().isNotEmpty;

  AppSettings copyWith({
    String? modalBaseUrl,
    String? apiKey,
    bool? autoDeployModal,
    String? ollamaUrl,
    String? ollamaModel,
    double? matchThreshold,
  }) => AppSettings(
    modalBaseUrl: modalBaseUrl ?? this.modalBaseUrl,
    apiKey: apiKey ?? this.apiKey,
    autoDeployModal: autoDeployModal ?? this.autoDeployModal,
    ollamaUrl: ollamaUrl ?? this.ollamaUrl,
    ollamaModel: ollamaModel ?? this.ollamaModel,
    matchThreshold: matchThreshold ?? this.matchThreshold,
  );

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    modalBaseUrl: json['modal_base_url'] as String? ?? '',
    apiKey: json['api_key'] as String? ?? '',
    autoDeployModal: json['auto_deploy_modal'] as bool? ?? true,
    ollamaUrl: json['ollama_url'] as String? ?? 'http://localhost:11434',
    ollamaModel: json['ollama_model'] as String? ?? 'gemma3:4b',
    matchThreshold: (json['match_threshold'] as num?)?.toDouble() ?? 0.72,
  );

  Map<String, dynamic> toJson() => {
    'modal_base_url': modalBaseUrl,
    'api_key': apiKey,
    'auto_deploy_modal': autoDeployModal,
    'ollama_url': ollamaUrl,
    'ollama_model': ollamaModel,
    'match_threshold': matchThreshold,
  };
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);
