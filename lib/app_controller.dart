import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'repository.dart';
import 'services.dart';

class AppController extends ChangeNotifier {
  AppController({
    AppRepository? repository,
    AudioCaptureService? capture,
    UploadPreparationService? uploadPreparation,
    LocalSummaryService? summary,
    ModalDeploymentService? deployment,
  }) : repository = repository ?? AppRepository(),
       _capture = capture ?? AudioCaptureService(),
       _uploadPreparation = uploadPreparation ?? UploadPreparationService(),
       _summary = summary ?? LocalSummaryService(),
       _deployment = deployment ?? ModalDeploymentService();

  final AppRepository repository;
  final AudioCaptureService _capture;
  final UploadPreparationService _uploadPreparation;
  final LocalSummaryService _summary;
  final ModalDeploymentService _deployment;
  final _uuid = const Uuid();
  final Set<String> _polling = {};

  bool initialized = false;
  bool captureSupported = false;
  bool isRecording = false;
  bool busy = false;
  String? notice;
  ModalDeploymentState modalDeploymentState = ModalDeploymentState.idle;
  String? modalDeploymentMessage;
  Duration recordingElapsed = Duration.zero;
  Timer? _timer;
  DateTime? _recordingStartedAt;
  String? _recordingId;
  String? _recordingTitle;
  String? _recordingPath;

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
      _recordingStartedAt = DateTime.now();
      recordingElapsed = Duration.zero;
      isRecording = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        recordingElapsed = DateTime.now().difference(_recordingStartedAt!);
        notifyListeners();
      });
      notifyListeners();
    } catch (error) {
      notice = 'Could not start recording: $error';
      notifyListeners();
    }
  }

  Future<String?> stopRecording() async {
    if (!isRecording) return null;
    busy = true;
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
      busy = false;
      notifyListeners();
      if (settings.modalConfigured) unawaited(transcribe(meeting.id));
      return meeting.id;
    } catch (error) {
      busy = false;
      notice = 'Could not finish recording: $error';
      notifyListeners();
      return null;
    }
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

  Future<void> identifySpeaker({
    required String meetingId,
    required String speakerId,
    required String name,
    required String email,
  }) async {
    final meeting = meetingById(meetingId);
    if (meeting == null) return;
    final speaker = meeting.speakers
        .where((item) => item.id == speakerId)
        .first;
    var existing = profiles
        .where(
          (item) =>
              email.isNotEmpty &&
              item.email.toLowerCase() == email.toLowerCase(),
        )
        .firstOrNull;
    existing ??= profiles
        .where((item) => item.name.toLowerCase() == name.trim().toLowerCase())
        .firstOrNull;
    final profile =
        existing ??
        SpeakerProfile(
          id: _uuid.v4(),
          name: name.trim(),
          email: email.trim(),
          embedding: speaker.embedding,
          samplePath: speaker.samplePath ?? '',
          createdAt: DateTime.now(),
        );
    if (existing == null) repository.profiles.add(profile);
    final updatedSpeakers = meeting.speakers
        .map(
          (item) => item.id == speakerId
              ? item.copyWith(profileId: profile.id)
              : item,
        )
        .toList();
    await _replaceMeeting(meeting.copyWith(speakers: updatedSpeakers));
  }

  Future<void> summarize(String meetingId) async {
    final meeting = meetingById(meetingId);
    if (meeting == null || meeting.segments.isEmpty) return;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final summary = await _summary.summarize(meeting, settings);
      await _replaceMeeting(meeting.copyWith(summary: summary));
    } catch (error) {
      notice = 'Local summary failed: $error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> saveSettings(AppSettings value) async {
    repository.settings = value;
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
