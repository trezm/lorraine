import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class AppRepository {
  AppRepository({Directory? supportDirectory, Directory? legacyRoot})
    : _supportDirectory = supportDirectory,
      _legacyRoot = legacyRoot;

  static const _bundleIdentifier = 'com.lorraine.meeting.lorraine';

  final Directory? _supportDirectory;
  final Directory? _legacyRoot;
  late final Directory root;
  late final Directory recordingsDirectory;
  late final Directory samplesDirectory;
  late final File _stateFile;

  List<Meeting> meetings = [];
  List<SpeakerProfile> profiles = [];
  AppSettings settings = const AppSettings();

  Future<void> initialize() async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    root = Directory('${support.path}/Lorraine');
    recordingsDirectory = Directory('${root.path}/recordings');
    samplesDirectory = Directory('${root.path}/speaker_samples');
    await recordingsDirectory.create(recursive: true);
    await samplesDirectory.create(recursive: true);
    _stateFile = File('${root.path}/state.json');
    final hadCurrentState = await _stateFile.exists();
    if (hadCurrentState) {
      _loadState(
        jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>,
      );
    }
    await _migrateLegacySandbox(hadCurrentState: hadCurrentState);
    var stateChanged = _learnConfirmedSpeakers();
    if (reconcileAutomaticSpeakerMatches()) stateChanged = true;
    if (_recoverInterruptedTranscriptions()) stateChanged = true;
    if (stateChanged) await save();
  }

  void _loadState(Map<String, dynamic> raw) {
    meetings = (raw['meetings'] as List<dynamic>? ?? const [])
        .map((item) => Meeting.fromJson(item as Map<String, dynamic>))
        .toList();
    profiles = (raw['profiles'] as List<dynamic>? ?? const [])
        .map((item) => SpeakerProfile.fromJson(item as Map<String, dynamic>))
        .toList();
    settings = AppSettings.fromJson(
      raw['settings'] as Map<String, dynamic>? ?? const {},
    );
  }

  Future<void> _migrateLegacySandbox({required bool hadCurrentState}) async {
    final legacyRoot = _legacyRoot ?? _defaultLegacyRoot();
    if (legacyRoot == null || legacyRoot.path == root.path) return;

    final marker = File('${root.path}/.legacy_sandbox_migrated');
    final legacyState = File('${legacyRoot.path}/state.json');
    if (await marker.exists() || !await legacyState.exists()) return;

    final raw =
        jsonDecode(await legacyState.readAsString()) as Map<String, dynamic>;
    final legacyMeetings = (raw['meetings'] as List<dynamic>? ?? const [])
        .map((item) => Meeting.fromJson(item as Map<String, dynamic>))
        .toList();
    final legacyProfiles = (raw['profiles'] as List<dynamic>? ?? const [])
        .map((item) => SpeakerProfile.fromJson(item as Map<String, dynamic>))
        .toList();

    final existingMeetingIds = meetings.map((meeting) => meeting.id).toSet();
    for (final meeting in legacyMeetings) {
      if (existingMeetingIds.add(meeting.id)) {
        meetings.add(await _relocateMeeting(meeting));
      }
    }
    meetings.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final existingProfileIds = profiles.map((profile) => profile.id).toSet();
    for (final profile in legacyProfiles) {
      if (existingProfileIds.add(profile.id)) {
        profiles.add(await _relocateProfile(profile));
      }
    }

    if (!hadCurrentState) {
      settings = AppSettings.fromJson(
        raw['settings'] as Map<String, dynamic>? ?? const {},
      );
    }
    await save();
    await marker.writeAsString(DateTime.now().toIso8601String(), flush: true);
  }

  Directory? _defaultLegacyRoot() {
    if (!Platform.isMacOS) return null;
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    return Directory(
      '$home/Library/Containers/$_bundleIdentifier/Data/Library/'
      'Application Support/$_bundleIdentifier/Lorraine',
    );
  }

  Future<Meeting> _relocateMeeting(Meeting meeting) async {
    final audioPath = await _copyLegacyFile(
      meeting.audioPath,
      recordingsDirectory,
    );
    final speakers = <MeetingSpeaker>[];
    for (final speaker in meeting.speakers) {
      final samplePath = speaker.samplePath;
      speakers.add(
        samplePath == null
            ? speaker
            : speaker.copyWith(
                samplePath: await _copyLegacyFile(samplePath, samplesDirectory),
              ),
      );
    }
    return Meeting(
      id: meeting.id,
      title: meeting.title,
      createdAt: meeting.createdAt,
      audioPath: audioPath,
      durationSeconds: meeting.durationSeconds,
      status: meeting.status,
      jobId: meeting.jobId,
      language: meeting.language,
      summary: meeting.summary,
      error: meeting.error,
      segments: meeting.segments,
      speakers: speakers,
    );
  }

  Future<SpeakerProfile> _relocateProfile(SpeakerProfile profile) async =>
      SpeakerProfile(
        id: profile.id,
        name: profile.name,
        email: profile.email,
        embeddings: profile.embeddings,
        samplePath: await _copyLegacyFile(profile.samplePath, samplesDirectory),
        createdAt: profile.createdAt,
      );

  bool _learnConfirmedSpeakers() {
    var changed = false;
    for (final meeting in meetings) {
      for (final speaker in meeting.speakers) {
        final profileId = speaker.profileId;
        if (!speaker.identityConfirmed || profileId == null) continue;
        final index = profiles.indexWhere((profile) => profile.id == profileId);
        if (index < 0) continue;
        final enrolled = profiles[index].enroll(speaker.embedding);
        if (enrolled.enrollmentCount != profiles[index].enrollmentCount) {
          profiles[index] = enrolled;
          changed = true;
        }
      }
    }
    return changed;
  }

  bool reconcileAutomaticSpeakerMatches() {
    var changed = false;
    for (var meetingIndex = 0; meetingIndex < meetings.length; meetingIndex++) {
      final meeting = meetings[meetingIndex];
      var meetingChanged = false;
      final speakers = meeting.speakers.map((speaker) {
        if (speaker.identityConfirmed) return speaker;
        final match = matchVoiceProfile(
          speaker.embedding,
          profiles,
          threshold: settings.matchThreshold,
          enrichedThreshold: settings.enrichedMatchThreshold,
          requiredMargin: settings.matchMargin,
        );
        final profileId = (match?.accepted ?? false) ? match!.profile.id : null;
        final confidence = match?.score;
        if (speaker.profileId == profileId &&
            speaker.matchConfidence == confidence) {
          return speaker;
        }
        meetingChanged = true;
        return speaker.copyWith(
          profileId: profileId,
          matchConfidence: confidence,
        );
      }).toList();
      if (meetingChanged) {
        meetings[meetingIndex] = meeting.copyWith(speakers: speakers);
        changed = true;
      }
    }
    return changed;
  }

  bool _recoverInterruptedTranscriptions() {
    var changed = false;
    for (var index = 0; index < meetings.length; index++) {
      final meeting = meetings[index];
      final interruptedBeforeJob =
          meeting.status == MeetingStatus.uploading ||
          (meeting.status == MeetingStatus.processing && meeting.jobId == null);
      if (!interruptedBeforeJob) continue;
      meetings[index] = meeting.copyWith(
        status: MeetingStatus.failed,
        error:
            'Local preparation or upload was interrupted before Modal returned '
            'a job ID. The original recording is safe; retry transcription.',
        processingStage: 'Interrupted — ready to retry',
        progress: 0,
      );
      changed = true;
    }
    return changed;
  }

  Future<String> _copyLegacyFile(
    String sourcePath,
    Directory destination,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) return sourcePath;
    final name = source.uri.pathSegments.last;
    final target = File('${destination.path}/$name');
    if (!await target.exists()) await source.copy(target.path);
    return target.path;
  }

  String recordingPath(String id) => '${recordingsDirectory.path}/$id.m4a';

  Future<String> writeSpeakerSample(
    String meetingId,
    String speakerId,
    Uint8List bytes,
  ) async {
    final safeSpeaker = speakerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${samplesDirectory.path}/$meetingId-$safeSpeaker.wav');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> save() async {
    final state = prettyJson({
      'version': 2,
      'meetings': meetings.map((meeting) => meeting.toJson()).toList(),
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
      'settings': settings.toJson(),
    });
    final temporary = File('${_stateFile.path}.tmp');
    await temporary.writeAsString(state, flush: true);
    await temporary.rename(_stateFile.path);
  }
}
