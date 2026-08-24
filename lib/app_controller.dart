import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'repository.dart';
import 'services.dart';

enum RecordingAlertReason { longMeeting, silence }

/// A pending "are you still meeting?" prompt. The recording stops on its own
/// when [autoStopAt] passes without the user answering.
class RecordingAlert {
  RecordingAlert({
    required this.reason,
    required this.autoStopAt,
    required this.secondsRemaining,
  });

  final RecordingAlertReason reason;
  final DateTime autoStopAt;
  int secondsRemaining;
}

class AppController extends ChangeNotifier {
  AppController({
    AppRepository? repository,
    AudioCaptureService? capture,
    UploadPreparationService? uploadPreparation,
    SummaryService? summary,
    ModalDeploymentService? deployment,
    DateTime Function()? now,
  }) : repository = repository ?? AppRepository(),
       _capture = capture ?? AudioCaptureService(),
       _uploadPreparation = uploadPreparation ?? UploadPreparationService(),
       _summary = summary ?? SummaryService(),
       _deployment = deployment ?? ModalDeploymentService(),
       _now = now ?? DateTime.now;

  /// How long a watchdog prompt waits before stopping the recording itself.
  static const autoStopCountdown = Duration(minutes: 5);

  final AppRepository repository;
  final AudioCaptureService _capture;
  final UploadPreparationService _uploadPreparation;
  final SummaryService _summary;
  final ModalDeploymentService _deployment;
  final DateTime Function() _now;
  final _uuid = const Uuid();
  final Set<String> _polling = {};

  bool initialized = false;
  bool captureSupported = false;
  bool isRecording = false;
  bool isStoppingRecording = false;
  bool isSummarizing = false;
  String? notice;
  ModalDeploymentState modalDeploymentState = ModalDeploymentState.idle;
  String? modalDeploymentMessage;
  Duration recordingElapsed = Duration.zero;
  RecordingAlert? recordingAlert;
  Timer? _timer;
  bool _ticking = false;
  DateTime? _recordingStartedAt;
  String? _recordingId;
  String? _recordingTitle;
  String? _recordingPath;
  Duration _longMeetingAlertBaseline = Duration.zero;
  Duration _silenceAlertSnoozedUntil = Duration.zero;

  List<Meeting> get meetings => repository.meetings;
  List<SpeakerProfile> get profiles => repository.profiles;
  AppSettings get settings => repository.settings;
  Iterable<({Meeting meeting, MeetingSpeaker speaker})>
  get unknownVoices sync* {
    for (final meeting in meetings) {
      for (final speaker in meeting.speakers) {
        if (speaker.profileId == null) {
          yield (meeting: meeting, speaker: speaker);
        }
      }
    }
  }

  Future<void> initialize() async {
    await repository.initialize();
    captureSupported = await _capture.isSupported();
    initialized = true;
    notifyListeners();
    if (settings.autoDeployModal) {
      unawaited(deployModal());
    }
    for (final meeting in meetings.where(
      (item) => item.status == MeetingStatus.processing && item.jobId != null,
    )) {
      unawaited(_poll(meeting.id, meeting.jobId!));
    }
  }

  Future<void> deployModal() async {
    if (modalDeploymentState == ModalDeploymentState.deploying ||
        modalDeploymentState == ModalDeploymentState.checking) {
      return;
    }
    modalDeploymentState = ModalDeploymentState.checking;
    modalDeploymentMessage = 'Checking Modal CLI and authentication…';
    notifyListeners();
    try {
      modalDeploymentState = ModalDeploymentState.deploying;
      modalDeploymentMessage = 'Deploying the WhisperX service to Modal…';
      notifyListeners();
      final result = await _deployment.deploy(repository.root);
      repository.settings = settings.copyWith(modalBaseUrl: result.endpoint);
      await repository.save();
      modalDeploymentState = ModalDeploymentState.ready;
      modalDeploymentMessage = 'Modal endpoint is ready: ${result.endpoint}';
    } on ModalCliUnavailable catch (error) {
      modalDeploymentState = ModalDeploymentState.unavailable;
      modalDeploymentMessage = error.message;
    } catch (error) {
      modalDeploymentState = ModalDeploymentState.failed;
      modalDeploymentMessage = 'Automatic Modal deployment failed: $error';
    }
    notifyListeners();
  }

  Meeting? meetingById(String id) {
    for (final meeting in meetings) {
      if (meeting.id == id) return meeting;
    }
    return null;
  }

  SpeakerProfile? profileById(String? id) {
    if (id == null) return null;
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  String speakerName(Meeting meeting, String speakerId) {
    final speaker = meeting.speakers
        .where((item) => item.id == speakerId)
        .firstOrNull;
    final profile = profileById(speaker?.profileId);
    return profile?.name ?? speakerId.replaceFirst('SPEAKER_', 'Speaker ');
  }

  Future<void> startRecording(String title) async {
    notice = null;
    if (!captureSupported) {
      notice =
          'System + microphone capture currently requires macOS 15 or newer.';
      notifyListeners();
      return;
    }
    final id = _uuid.v4();
    final path = repository.recordingPath(id);
    try {
      await _capture.start(path);
      _recordingId = id;
      _recordingPath = path;
      _recordingTitle = title.trim().isEmpty
          ? 'Untitled meeting'
          : title.trim();
      _recordingStartedAt = _now();
      recordingElapsed = Duration.zero;
      recordingAlert = null;
      _longMeetingAlertBaseline = Duration.zero;
      _silenceAlertSnoozedUntil = Duration.zero;
      isRecording = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_tick());
      });
      notifyListeners();
    } catch (error) {
      notice = 'Could not start recording: $error';
      notifyListeners();
    }
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      if (!isRecording || isStoppingRecording) return;
      await checkRecordingWatchdogs();
      notifyListeners();
    } finally {
      _ticking = false;
    }
  }

  /// Raises, refreshes, or resolves the "still meeting?" prompt. Runs once per
  /// recording timer tick; visible so tests can drive it with a fake clock.
  @visibleForTesting
  Future<void> checkRecordingWatchdogs() async {
    if (!isRecording || isStoppingRecording) return;
    recordingElapsed = _now().difference(_recordingStartedAt!);
    final settings = this.settings;
    final alert = recordingAlert;
    if (alert != null) {
      if (alert.reason == RecordingAlertReason.silence) {
        final silence = await _capture.silenceSeconds();
        if (silence != null && silence < settings.silenceAlertMinutes * 60) {
          // Someone spoke again — withdraw the prompt without snoozing.
          recordingAlert = null;
          return;
        }
      }
      final remaining = alert.autoStopAt.difference(_now());
      alert.secondsRemaining = remaining.inSeconds.clamp(
        0,
        autoStopCountdown.inSeconds,
      );
      if (remaining > Duration.zero) return;
      final title = _recordingTitle;
      recordingAlert = null;
      final stoppedId = await stopRecording();
      if (stoppedId != null) {
        notice = switch (alert.reason) {
          RecordingAlertReason.silence =>
            'Stopped "$title" automatically after '
                '${settings.silenceAlertMinutes} minutes without speech. '
                'The recording is saved.',
          RecordingAlertReason.longMeeting =>
            'Stopped "$title" automatically — the '
                '${settings.longMeetingAlertMinutes}-minute check-in went '
                'unanswered. The recording is saved.',
        };
      }
      return;
    }
    if (settings.longMeetingAlertEnabled &&
        recordingElapsed - _longMeetingAlertBaseline >=
            Duration(minutes: settings.longMeetingAlertMinutes)) {
      _raiseRecordingAlert(RecordingAlertReason.longMeeting);
      return;
    }
    if (settings.silenceAlertEnabled &&
        recordingElapsed >= _silenceAlertSnoozedUntil) {
      final silence = await _capture.silenceSeconds();
      if (silence != null && silence >= settings.silenceAlertMinutes * 60) {
        _raiseRecordingAlert(RecordingAlertReason.silence);
      }
    }
  }

  void _raiseRecordingAlert(RecordingAlertReason reason) {
    recordingAlert = RecordingAlert(
      reason: reason,
      autoStopAt: _now().add(autoStopCountdown),
      secondsRemaining: autoStopCountdown.inSeconds,
    );
    // A chime, because Lorraine is usually behind the meeting app. Sound is
    // best-effort; the visible countdown is the real prompt.
    unawaited(
      SystemSound.play(SystemSoundType.alert).catchError((Object _) {}),
    );
  }

  /// The user answered "keep recording": clear the prompt and snooze its
  /// trigger so it re-arms a full interval from now instead of immediately.
  void dismissRecordingAlert() {
    final alert = recordingAlert;
    if (alert == null) return;
    recordingAlert = null;
    switch (alert.reason) {
      case RecordingAlertReason.longMeeting:
        _longMeetingAlertBaseline = recordingElapsed;
      case RecordingAlertReason.silence:
        _silenceAlertSnoozedUntil =
            recordingElapsed + Duration(minutes: settings.silenceAlertMinutes);
    }
    notifyListeners();
  }

  Future<String?> stopRecording() async {
    if (!isRecording || isStoppingRecording) return null;
    isStoppingRecording = true;
    recordingAlert = null;
    _timer?.cancel();
    notifyListeners();
    try {
      final nativePath = await _capture.stop();
      final meeting = Meeting(
        id: _recordingId!,
        title: _recordingTitle!,
        createdAt: _recordingStartedAt!,
        audioPath: nativePath.isEmpty ? _recordingPath! : nativePath,
        durationSeconds: recordingElapsed.inSeconds,
        status: MeetingStatus.recorded,
      );
      repository.meetings.insert(0, meeting);
      await repository.save();
      isRecording = false;
      isStoppingRecording = false;
      notifyListeners();
      if (settings.modalConfigured) unawaited(transcribe(meeting.id));
      return meeting.id;
    } catch (error) {
      isStoppingRecording = false;
      notice = 'Could not finish recording: $error';
      notifyListeners();
      return null;
    }
  }

  /// Renames [meetingId]. The title is local-only metadata that is never
  /// uploaded, so this is safe at any status. A blank or unchanged title is
  /// ignored rather than overwriting the existing one.
  Future<void> renameMeeting(String meetingId, String title) async {
    final meeting = meetingById(meetingId);
    final trimmed = title.trim();
    if (meeting == null || trimmed.isEmpty || trimmed == meeting.title) return;
    await _replaceMeeting(meeting.copyWith(title: trimmed));
  }

  Future<void> transcribe(String meetingId) async {
    final meeting = meetingById(meetingId);
    if (meeting == null) return;
    if (!settings.modalConfigured) {
      notice = 'Add your Modal endpoint in Settings before transcribing.';
      notifyListeners();
      return;
    }
    await _replaceMeeting(
      meeting.copyWith(
        status: MeetingStatus.uploading,
        error: null,
        processingStage: 'Optimizing audio for transcription',
        progress: 0.01,
      ),
    );
    PreparedAudio? prepared;
    try {
      prepared = await _uploadPreparation.prepare(meeting, repository.root);
      final uploadMegabytes = (await prepared.file.length() / (1024 * 1024))
          .toStringAsFixed(1);
      var lastUploadPercent = -1;
      final jobId = await ModalClient(settings).submit(
        meeting,
        profiles,
        audioFile: prepared.file,
        onUploadProgress: (value) {
          final percent = (value * 100).floor();
          if (percent == lastUploadPercent) return;
          lastUploadPercent = percent;
          _updateProgressInMemory(
            meetingId,
            stage: 'Uploading $uploadMegabytes MB copy — $percent%',
            progress: 0.02 + (value * 0.08),
          );
        },
      );
      await prepared.dispose();
      prepared = null;
      await _replaceMeeting(
        meeting.copyWith(
          status: MeetingStatus.processing,
          jobId: jobId,
          error: null,
          processingStage: 'Queued for GPU',
          progress: 0.1,
        ),
      );
      await _poll(meetingId, jobId);
    } catch (error) {
      final current = meetingById(meetingId) ?? meeting;
      await _replaceMeeting(
        current.copyWith(
          status: MeetingStatus.failed,
          error: error.toString(),
          processingStage: 'Failed',
        ),
      );
    } finally {
      await prepared?.dispose();
    }
  }

  Future<void> _poll(String meetingId, String jobId) async {
    if (!_polling.add(meetingId)) return;
    try {
      final deadline = DateTime.now().add(const Duration(hours: 3));
      while (DateTime.now().isBefore(deadline)) {
        final result = await ModalClient(settings).job(jobId);
        final status = result['status'] as String? ?? 'processing';
        if (status == 'failed') {
          final meeting = meetingById(meetingId);
          if (meeting != null) {
            await _replaceMeeting(
              meeting.copyWith(
                status: MeetingStatus.failed,
                error: result['error']?.toString() ?? 'Transcription failed',
                processingStage: 'Failed',
              ),
            );
          }
          return;
        }
        if (status == 'complete') {
          await _applyResult(meetingId, result);
          return;
        }
        await _applyProgress(meetingId, result);
        await Future<void>.delayed(const Duration(seconds: 4));
      }
      throw TimeoutException('Transcription did not complete within 3 hours.');
    } catch (error) {
      final meeting = meetingById(meetingId);
      if (meeting != null) {
        await _replaceMeeting(
          meeting.copyWith(
            status: MeetingStatus.failed,
            error: error.toString(),
            processingStage: 'Failed',
          ),
        );
      }
    } finally {
      _polling.remove(meetingId);
    }
  }

  Future<void> _applyResult(
    String meetingId,
    Map<String, dynamic> result,
  ) async {
    final meeting = meetingById(meetingId);
    if (meeting == null) return;
    final speakers = <MeetingSpeaker>[];
    for (final raw in result['speakers'] as List<dynamic>? ?? const []) {
      final item = raw as Map<String, dynamic>;
      String? samplePath;
      final sample = item['sample_base64'] as String?;
      if (sample != null && sample.isNotEmpty) {
        samplePath = await repository.writeSpeakerSample(
          meetingId,
          item['id'] as String,
          Uint8List.fromList(base64Decode(sample)),
        );
      }
      speakers.add(
        MeetingSpeaker(
          id: item['id'] as String,
          embedding: (item['embedding'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toDouble())
              .toList(),
          samplePath: samplePath,
          profileId: item['matched_profile_id'] as String?,
          matchConfidence: (item['match_confidence'] as num?)?.toDouble(),
        ),
      );
    }
    await _replaceMeeting(
      meeting.copyWith(
        status: MeetingStatus.ready,
        language: result['language'] as String?,
        segments: (result['segments'] as List<dynamic>? ?? const [])
            .map(
              (item) =>
                  TranscriptSegment.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        speakers: speakers,
        error: null,
        processingStage: 'Complete',
        progress: 1,
      ),
    );
  }

  Future<void> _applyProgress(
    String meetingId,
    Map<String, dynamic> result,
  ) async {
    final meeting = meetingById(meetingId);
    if (meeting == null) return;
    final rawStage = result['stage']?.toString() ?? 'processing';
    final stage = switch (rawStage) {
      'queued' => 'Queued for GPU',
      'starting' => 'Starting GPU worker',
      'transcribing' => 'Transcribing speech',
      'aligning' => 'Aligning words and timestamps',
      'diarizing' => 'Identifying distinct speakers',
      'voices' => 'Creating voice fingerprints and samples',
      'finalizing' => 'Saving transcript',
      _ => 'Processing meeting',
    };
    final progress = ((result['progress'] as num?)?.toDouble() ?? 0.1).clamp(
      0.1,
      0.99,
    );
    if (meeting.processingStage == stage && meeting.progress == progress) {
      return;
    }
    await _replaceMeeting(
      meeting.copyWith(processingStage: stage, progress: progress),
    );
  }

  void _updateProgressInMemory(
    String meetingId, {
    required String stage,
    required double progress,
  }) {
    final index = meetings.indexWhere((meeting) => meeting.id == meetingId);
    if (index < 0) return;
    meetings[index] = meetings[index].copyWith(
      processingStage: stage,
      progress: progress.clamp(0, 1),
    );
    notifyListeners();
  }

  SpeakerProfile? suggestedProfile({
    required String name,
    required String email,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isNotEmpty) {
      final emailMatch = profiles
          .where(
            (profile) => profile.email.trim().toLowerCase() == normalizedEmail,
          )
          .firstOrNull;
      if (emailMatch != null) return emailMatch;
    }
    final normalizedName = name.trim().toLowerCase();
    if (normalizedName.isEmpty) return null;
    return profiles
        .where((profile) => profile.name.trim().toLowerCase() == normalizedName)
        .firstOrNull;
  }

  Future<void> identifySpeaker({
    required String meetingId,
    required String speakerId,
    required String name,
    required String email,
    String? mergeWithProfileId,
  }) async {
    final meeting = meetingById(meetingId);
    if (meeting == null) return;
    final speaker = meeting.speakers
        .where((item) => item.id == speakerId)
        .first;
    final existing = mergeWithProfileId == null
        ? null
        : profileById(mergeWithProfileId);
    if (mergeWithProfileId != null && existing == null) {
      throw StateError('The selected voice profile no longer exists.');
    }
    late final SpeakerProfile profile;
    if (existing == null) {
      profile = SpeakerProfile(
        id: _uuid.v4(),
        name: name.trim(),
        email: email.trim(),
        embeddings: [speaker.embedding],
        samplePath: speaker.samplePath ?? '',
        createdAt: DateTime.now(),
      );
      repository.profiles.add(profile);
    } else {
      profile = existing.enroll(speaker.embedding);
      final profileIndex = profiles.indexWhere(
        (item) => item.id == existing.id,
      );
      repository.profiles[profileIndex] = profile;
    }
    final updatedSpeakers = meeting.speakers
        .map(
          (item) => item.id == speakerId
              ? item.copyWith(profileId: profile.id, identityConfirmed: true)
              : item,
        )
        .toList();
    await _replaceMeeting(meeting.copyWith(speakers: updatedSpeakers));
    if (repository.reconcileAutomaticSpeakerMatches()) {
      await repository.save();
      notifyListeners();
    }
  }

  Future<void> summarize(String meetingId) async {
    final meeting = meetingById(meetingId);
    if (meeting == null || meeting.segments.isEmpty || isSummarizing) return;
    isSummarizing = true;
    notice = null;
    notifyListeners();
    try {
      final speakerNames = <String, String>{};
      for (final speaker in meeting.speakers) {
        final profile = profileById(speaker.profileId);
        if (profile != null && profile.name.trim().isNotEmpty) {
          speakerNames[speaker.id] = profile.name.trim();
        }
      }
      final summary = await _summary.summarize(
        meeting,
        settings,
        speakerNames: speakerNames,
        onProgress: (update) {
          final progress = update.progress;
          notice = progress == null
              ? update.message
              : '${update.message} ${(progress * 100).round()}%';
          notifyListeners();
        },
      );
      await _replaceMeeting(meeting.copyWith(summary: summary));
      notice = null;
    } catch (error) {
      notice = 'Summary failed: $error';
    } finally {
      isSummarizing = false;
      notifyListeners();
    }
  }

  Future<void> saveSettings(AppSettings value) async {
    repository.settings = value;
    repository.reconcileAutomaticSpeakerMatches();
    await repository.save();
    notifyListeners();
  }

  Future<void> _replaceMeeting(Meeting value) async {
    final index = meetings.indexWhere((item) => item.id == value.id);
    if (index < 0) return;
    meetings[index] = value;
    await repository.save();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
