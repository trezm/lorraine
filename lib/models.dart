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
    String? title,
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
    title: title ?? this.title,
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

/// Backends that can generate a meeting summary.
///
/// OpenRouter speaks the OpenAI chat-completions dialect, so it shares that
/// transport and only differs in defaults and attribution headers. Anthropic
/// does not, so it has its own request shape.
enum SummaryProvider { ollama, openai, openaiCompatible, anthropic, openRouter }

extension SummaryProviderInfo on SummaryProvider {
  String get label => switch (this) {
    SummaryProvider.ollama => 'Ollama (on this Mac)',
    SummaryProvider.openai => 'OpenAI',
    SummaryProvider.openaiCompatible => 'OpenAI-compatible endpoint',
    SummaryProvider.anthropic => 'Anthropic',
    SummaryProvider.openRouter => 'OpenRouter',
  };

  String get description => switch (this) {
    SummaryProvider.ollama =>
      'Transcript text never leaves this computer. Missing models are '
          'downloaded automatically.',
    SummaryProvider.openai => 'Sends the transcript to the OpenAI API.',
    SummaryProvider.openaiCompatible =>
      'Any server that implements /chat/completions — LM Studio, vLLM, '
          'llama.cpp, Together, Groq, and similar.',
    SummaryProvider.anthropic => 'Sends the transcript to the Anthropic API.',
    SummaryProvider.openRouter =>
      'Sends the transcript to OpenRouter, which forwards it to the chosen '
          'upstream model.',
  };

  /// Whether the transcript stays on this computer.
  bool get isLocal => this == SummaryProvider.ollama;

  /// Whether a missing key should block a summary attempt.
  bool get requiresApiKey => switch (this) {
    SummaryProvider.ollama || SummaryProvider.openaiCompatible => false,
    _ => true,
  };

  SummaryProviderConfig get defaults => switch (this) {
    SummaryProvider.ollama => const SummaryProviderConfig(
      baseUrl: 'http://localhost:11434',
      model: 'gemma3:4b',
    ),
    SummaryProvider.openai => const SummaryProviderConfig(
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
    ),
    SummaryProvider.openaiCompatible => const SummaryProviderConfig(
      baseUrl: 'http://localhost:1234/v1',
      model: '',
    ),
    SummaryProvider.anthropic => const SummaryProviderConfig(
      baseUrl: 'https://api.anthropic.com/v1',
      model: 'claude-opus-4-8',
    ),
    SummaryProvider.openRouter => const SummaryProviderConfig(
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'anthropic/claude-opus-4-8',
    ),
  };

  static SummaryProvider parse(String? name) {
    for (final provider in SummaryProvider.values) {
      if (provider.name == name) return provider;
    }
    return SummaryProvider.ollama;
  }
}

/// Per-provider endpoint settings. Each provider keeps its own entry so that
/// switching providers does not discard the other providers' keys and models.
class SummaryProviderConfig {
  const SummaryProviderConfig({
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  SummaryProviderConfig copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
  }) => SummaryProviderConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
  );

  factory SummaryProviderConfig.fromJson(
    Map<String, dynamic> json,
    SummaryProviderConfig fallback,
  ) => SummaryProviderConfig(
    baseUrl: json['base_url'] as String? ?? fallback.baseUrl,
    model: json['model'] as String? ?? fallback.model,
    apiKey: json['api_key'] as String? ?? fallback.apiKey,
  );

  Map<String, dynamic> toJson() => {
    'base_url': baseUrl,
    'model': model,
    'api_key': apiKey,
  };
}

class AppSettings {
  const AppSettings({
    this.modalBaseUrl = '',
    this.apiKey = '',
    this.autoDeployModal = true,
    this.summaryProvider = SummaryProvider.ollama,
    this.summaryProviders = const {},
    this.matchThreshold = 0.75,
    this.enrichedMatchThreshold = 0.60,
    this.matchMargin = 0.25,
    this.longMeetingAlertEnabled = true,
    this.longMeetingAlertMinutes = 60,
    this.silenceAlertEnabled = true,
    this.silenceAlertMinutes = 5,
  });

  final String modalBaseUrl;
  final String apiKey;
  final bool autoDeployModal;
  final SummaryProvider summaryProvider;
  final Map<SummaryProvider, SummaryProviderConfig> summaryProviders;
  final double matchThreshold;
  final double enrichedMatchThreshold;
  final double matchMargin;
  final bool longMeetingAlertEnabled;
  final int longMeetingAlertMinutes;
  final bool silenceAlertEnabled;
  final int silenceAlertMinutes;

  bool get modalConfigured => modalBaseUrl.trim().isNotEmpty;

  /// Stored settings for [provider], falling back to its documented defaults.
  SummaryProviderConfig configFor(SummaryProvider provider) =>
      summaryProviders[provider] ?? provider.defaults;

  SummaryProviderConfig get summaryConfig => configFor(summaryProvider);

  AppSettings copyWith({
    String? modalBaseUrl,
    String? apiKey,
    bool? autoDeployModal,
    SummaryProvider? summaryProvider,
    Map<SummaryProvider, SummaryProviderConfig>? summaryProviders,
    double? matchThreshold,
    double? enrichedMatchThreshold,
    double? matchMargin,
    bool? longMeetingAlertEnabled,
    int? longMeetingAlertMinutes,
    bool? silenceAlertEnabled,
    int? silenceAlertMinutes,
  }) => AppSettings(
    modalBaseUrl: modalBaseUrl ?? this.modalBaseUrl,
    apiKey: apiKey ?? this.apiKey,
    autoDeployModal: autoDeployModal ?? this.autoDeployModal,
    summaryProvider: summaryProvider ?? this.summaryProvider,
    summaryProviders: summaryProviders ?? this.summaryProviders,
    matchThreshold: matchThreshold ?? this.matchThreshold,
    enrichedMatchThreshold:
        enrichedMatchThreshold ?? this.enrichedMatchThreshold,
    matchMargin: matchMargin ?? this.matchMargin,
    longMeetingAlertEnabled:
        longMeetingAlertEnabled ?? this.longMeetingAlertEnabled,
    longMeetingAlertMinutes:
        longMeetingAlertMinutes ?? this.longMeetingAlertMinutes,
    silenceAlertEnabled: silenceAlertEnabled ?? this.silenceAlertEnabled,
    silenceAlertMinutes: silenceAlertMinutes ?? this.silenceAlertMinutes,
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
      summaryProvider: SummaryProviderInfo.parse(
        json['summary_provider'] as String?,
      ),
      summaryProviders: _providersFromJson(json),
      matchThreshold: migrateOldDefault ? 0.75 : storedThreshold ?? 0.75,
      enrichedMatchThreshold:
          (json['enriched_match_threshold'] as num?)?.toDouble() ?? 0.60,
      matchMargin: (json['match_margin'] as num?)?.toDouble() ?? 0.25,
      longMeetingAlertEnabled:
          json['long_meeting_alert_enabled'] as bool? ?? true,
      longMeetingAlertMinutes:
          (json['long_meeting_alert_minutes'] as num?)?.round() ?? 60,
      silenceAlertEnabled: json['silence_alert_enabled'] as bool? ?? true,
      silenceAlertMinutes:
          (json['silence_alert_minutes'] as num?)?.round() ?? 5,
    );
  }

  /// Reads the per-provider map, promoting pre-provider `ollama_*` settings
  /// into the Ollama entry so existing installs keep their local model.
  static Map<SummaryProvider, SummaryProviderConfig> _providersFromJson(
    Map<String, dynamic> json,
  ) {
    final stored = json['summary_providers'] as Map<String, dynamic>?;
    final result = <SummaryProvider, SummaryProviderConfig>{};
    for (final provider in SummaryProvider.values) {
      final entry = stored?[provider.name] as Map<String, dynamic>?;
      if (entry != null) {
        result[provider] = SummaryProviderConfig.fromJson(
          entry,
          provider.defaults,
        );
      }
    }
    if (!result.containsKey(SummaryProvider.ollama)) {
      final legacyUrl = json['ollama_url'] as String?;
      final legacyModel = json['ollama_model'] as String?;
      if (legacyUrl != null || legacyModel != null) {
        result[SummaryProvider.ollama] = SummaryProvider.ollama.defaults
            .copyWith(baseUrl: legacyUrl, model: legacyModel);
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'modal_base_url': modalBaseUrl,
    'api_key': apiKey,
    'auto_deploy_modal': autoDeployModal,
    'summary_provider': summaryProvider.name,
    'summary_providers': {
      for (final entry in summaryProviders.entries)
        entry.key.name: entry.value.toJson(),
    },
    'match_threshold': matchThreshold,
    'enriched_match_threshold': enrichedMatchThreshold,
    'match_margin': matchMargin,
    'long_meeting_alert_enabled': longMeetingAlertEnabled,
    'long_meeting_alert_minutes': longMeetingAlertMinutes,
    'silence_alert_enabled': silenceAlertEnabled,
    'silence_alert_minutes': silenceAlertMinutes,
  };
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);
