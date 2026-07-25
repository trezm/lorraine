import 'dart:convert';
import 'dart:math' as math;

const _notSet = Object();

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
    this.identityConfirmed = false,
  });

  final String id;
  final List<double> embedding;
  final String? samplePath;
  final String? profileId;
  final double? matchConfidence;
  final bool identityConfirmed;

  MeetingSpeaker copyWith({
    String? samplePath,
    Object? profileId = _notSet,
    Object? matchConfidence = _notSet,
    bool? identityConfirmed,
  }) => MeetingSpeaker(
    id: id,
    embedding: embedding,
    samplePath: samplePath ?? this.samplePath,
    profileId: identical(profileId, _notSet)
        ? this.profileId
        : profileId as String?,
    matchConfidence: identical(matchConfidence, _notSet)
        ? this.matchConfidence
        : matchConfidence as double?,
    identityConfirmed: identityConfirmed ?? this.identityConfirmed,
  );

  factory MeetingSpeaker.fromJson(Map<String, dynamic> json) => MeetingSpeaker(
    id: json['id'] as String,
    embedding: (json['embedding'] as List<dynamic>? ?? const [])
        .map((value) => (value as num).toDouble())
        .toList(),
    samplePath: json['sample_path'] as String?,
    profileId: json['profile_id'] as String?,
    matchConfidence: (json['match_confidence'] as num?)?.toDouble(),
    identityConfirmed:
        json['identity_confirmed'] as bool? ??
        (json['profile_id'] != null &&
            ((json['match_confidence'] as num?)?.toDouble() ?? 0) < 0.72),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'embedding': embedding,
    'sample_path': samplePath,
    'profile_id': profileId,
    'match_confidence': matchConfidence,
    'identity_confirmed': identityConfirmed,
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
    this.processingStage,
    this.progress = 0,
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
  final String? processingStage;
  final double progress;
  final List<TranscriptSegment> segments;
  final List<MeetingSpeaker> speakers;

  Meeting copyWith({
    MeetingStatus? status,
    Object? jobId = _notSet,
    Object? language = _notSet,
    Object? summary = _notSet,
    Object? error = _notSet,
    Object? processingStage = _notSet,
    double? progress,
    List<TranscriptSegment>? segments,
    List<MeetingSpeaker>? speakers,
  }) => Meeting(
    id: id,
    title: title,
    createdAt: createdAt,
    audioPath: audioPath,
    durationSeconds: durationSeconds,
    status: status ?? this.status,
    jobId: identical(jobId, _notSet) ? this.jobId : jobId as String?,
    language: identical(language, _notSet)
        ? this.language
        : language as String?,
    summary: identical(summary, _notSet) ? this.summary : summary as String?,
    error: identical(error, _notSet) ? this.error : error as String?,
    processingStage: identical(processingStage, _notSet)
        ? this.processingStage
        : processingStage as String?,
    progress: progress ?? this.progress,
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
    processingStage: json['processing_stage'] as String?,
    progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
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
    'processing_stage': processingStage,
    'progress': progress,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    'speakers': speakers.map((speaker) => speaker.toJson()).toList(),
  };
}

class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.embeddings,
    required this.samplePath,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final List<List<double>> embeddings;
  final String samplePath;
  final DateTime createdAt;

  List<double> get embedding => _centroid(embeddings);
  int get enrollmentCount => embeddings.length;

  SpeakerProfile enroll(List<double> value) {
    if (value.isEmpty ||
        (embeddings.isNotEmpty && value.length != embeddings.first.length)) {
      return this;
    }
    final normalized = _normalize(value);
    if (embeddings.any((sample) => _cosine(sample, normalized) > 0.9999)) {
      return this;
    }
    return SpeakerProfile(
      id: id,
      name: name,
      email: email,
      embeddings: [...embeddings, normalized],
      samplePath: samplePath,
      createdAt: createdAt,
    );
  }

  factory SpeakerProfile.fromJson(Map<String, dynamic> json) {
    final stored = json['embeddings'] as List<dynamic>?;
    final embeddings = stored == null
        ? [
            (json['embedding'] as List<dynamic>? ?? const [])
                .map((value) => (value as num).toDouble())
                .toList(),
          ]
        : stored
              .map(
                (sample) => (sample as List<dynamic>)
                    .map((value) => (value as num).toDouble())
                    .toList(),
              )
              .toList();
    return SpeakerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String? ?? '',
      embeddings: embeddings.where((sample) => sample.isNotEmpty).toList(),
      samplePath: json['sample_path'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'embedding': embedding,
    'embeddings': embeddings,
    'sample_path': samplePath,
    'created_at': createdAt.toIso8601String(),
  };

  Map<String, dynamic> toApiJson() => {
    'id': id,
    'name': name,
    'embedding': embedding,
    'embeddings': embeddings,
  };
}

class VoiceProfileMatch {
  const VoiceProfileMatch({
    required this.profile,
    required this.score,
    required this.runnerUpScore,
    required this.accepted,
  });

  final SpeakerProfile profile;
  final double score;
  final double? runnerUpScore;
  final bool accepted;
}

VoiceProfileMatch? matchVoiceProfile(
  List<double> embedding,
  List<SpeakerProfile> profiles, {
  required double threshold,
  double enrichedThreshold = 0.60,
  double requiredMargin = 0.25,
}) {
  if (embedding.isEmpty) return null;
  final scored = <({SpeakerProfile profile, double score})>[];
  for (final profile in profiles) {
    final candidates = profile.embeddings
        .where((sample) => sample.length == embedding.length)
        .toList();
    if (candidates.isEmpty) continue;
    final sampleScore = candidates
        .map((sample) => _cosine(embedding, sample))
        .reduce(math.max);
    final score = math.max(
      sampleScore,
      _cosine(embedding, _centroid(candidates)),
    );
    scored.add((profile: profile, score: score));
  }
  if (scored.isEmpty) return null;
  scored.sort((left, right) => right.score.compareTo(left.score));
  final best = scored.first;
  final runnerUpScore = scored.length > 1 ? scored[1].score : null;
  final margin = runnerUpScore == null
      ? double.infinity
      : best.score - runnerUpScore;
  final accepted =
      best.score >= threshold ||
      (best.profile.enrollmentCount >= 2 &&
          best.score >= enrichedThreshold &&
          margin >= requiredMargin);
  return VoiceProfileMatch(
    profile: best.profile,
    score: best.score,
    runnerUpScore: runnerUpScore,
    accepted: accepted,
  );
}

List<double> _normalize(List<double> value) {
  final norm = math.sqrt(
    value.fold<double>(0, (sum, item) => sum + item * item),
  );
  if (norm == 0) return List<double>.from(value);
  return value.map((item) => item / norm).toList();
}

double _cosine(List<double> left, List<double> right) {
  if (left.isEmpty || left.length != right.length) return -1;
  final a = _normalize(left);
  final b = _normalize(right);
  var result = 0.0;
  for (var index = 0; index < a.length; index++) {
    result += a[index] * b[index];
  }
  return result;
}

List<double> _centroid(List<List<double>> samples) {
  if (samples.isEmpty) return const [];
  final dimensions = samples.first.length;
  final valid = samples.where((sample) => sample.length == dimensions).toList();
  if (dimensions == 0 || valid.isEmpty) return const [];
  final sum = List<double>.filled(dimensions, 0);
  for (final sample in valid) {
    final normalized = _normalize(sample);
    for (var index = 0; index < dimensions; index++) {
      sum[index] += normalized[index];
    }
  }
  return _normalize(sum);
}

class AppSettings {
  const AppSettings({
    this.modalBaseUrl = '',
    this.apiKey = '',
    this.autoDeployModal = true,
    this.ollamaUrl = 'http://localhost:11434',
    this.ollamaModel = 'gemma3:4b',
    this.matchThreshold = 0.75,
    this.enrichedMatchThreshold = 0.60,
    this.matchMargin = 0.25,
  });

  final String modalBaseUrl;
  final String apiKey;
  final bool autoDeployModal;
  final String ollamaUrl;
  final String ollamaModel;
  final double matchThreshold;
  final double enrichedMatchThreshold;
  final double matchMargin;

  bool get modalConfigured => modalBaseUrl.trim().isNotEmpty;

  AppSettings copyWith({
    String? modalBaseUrl,
    String? apiKey,
    bool? autoDeployModal,
    String? ollamaUrl,
    String? ollamaModel,
    double? matchThreshold,
    double? enrichedMatchThreshold,
    double? matchMargin,
  }) => AppSettings(
    modalBaseUrl: modalBaseUrl ?? this.modalBaseUrl,
    apiKey: apiKey ?? this.apiKey,
    autoDeployModal: autoDeployModal ?? this.autoDeployModal,
    ollamaUrl: ollamaUrl ?? this.ollamaUrl,
    ollamaModel: ollamaModel ?? this.ollamaModel,
    matchThreshold: matchThreshold ?? this.matchThreshold,
    enrichedMatchThreshold:
        enrichedMatchThreshold ?? this.enrichedMatchThreshold,
    matchMargin: matchMargin ?? this.matchMargin,
  );

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final storedThreshold = (json['match_threshold'] as num?)?.toDouble();
    final hasTunableEnrichedSettings =
        json.containsKey('enriched_match_threshold') ||
        json.containsKey('match_margin');
    final migrateOldDefault =
        !hasTunableEnrichedSettings &&
        (storedThreshold == null || (storedThreshold - 0.72).abs() < 0.0001);
    return AppSettings(
      modalBaseUrl: json['modal_base_url'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      autoDeployModal: json['auto_deploy_modal'] as bool? ?? true,
      ollamaUrl: json['ollama_url'] as String? ?? 'http://localhost:11434',
      ollamaModel: json['ollama_model'] as String? ?? 'gemma3:4b',
      matchThreshold: migrateOldDefault ? 0.75 : storedThreshold ?? 0.75,
      enrichedMatchThreshold:
          (json['enriched_match_threshold'] as num?)?.toDouble() ?? 0.60,
      matchMargin: (json['match_margin'] as num?)?.toDouble() ?? 0.25,
    );
  }

  Map<String, dynamic> toJson() => {
    'modal_base_url': modalBaseUrl,
    'api_key': apiKey,
    'auto_deploy_modal': autoDeployModal,
    'ollama_url': ollamaUrl,
    'ollama_model': ollamaModel,
    'match_threshold': matchThreshold,
    'enriched_match_threshold': enrichedMatchThreshold,
    'match_margin': matchMargin,
  };
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);
