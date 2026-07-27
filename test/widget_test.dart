import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lorraine/app_controller.dart';
import 'package:lorraine/main.dart';
import 'package:lorraine/models.dart';
import 'package:lorraine/repository.dart';
import 'package:lorraine/services.dart';

void main() {
  testWidgets('shows the empty meetings workspace', (tester) async {
    final controller = AppController(repository: AppRepository());
    await tester.pumpWidget(LorraineApp(controller: controller));

    expect(find.text('Meetings'), findsWidgets);
    expect(find.text('No meetings yet'), findsOneWidget);
    expect(find.text('Record meeting'), findsOneWidget);
  });

  test('meeting transcript survives JSON round trip', () {
    final source = Meeting(
      id: 'meeting-1',
      title: 'Planning',
      createdAt: DateTime.utc(2026, 7, 23),
      audioPath: '/tmp/meeting.m4a',
      durationSeconds: 90,
      status: MeetingStatus.ready,
      processingStage: 'Complete',
      progress: 1,
      segments: const [
        TranscriptSegment(
          start: 0,
          end: 2.5,
          speakerId: 'SPEAKER_00',
          text: 'Hello there.',
        ),
      ],
    );

    final decoded = Meeting.fromJson(source.toJson());

    expect(decoded.title, 'Planning');
    expect(decoded.segments.single.speakerId, 'SPEAKER_00');
    expect(decoded.status, MeetingStatus.ready);
    expect(decoded.processingStage, 'Complete');
    expect(decoded.progress, 1);
  });

  test('Modal automatic deployment defaults on and persists', () {
    const settings = AppSettings();

    expect(settings.autoDeployModal, isTrue);
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.autoDeployModal, isTrue);
    expect(restored.matchThreshold, 0.75);
    expect(restored.enrichedMatchThreshold, 0.60);
    expect(restored.matchMargin, 0.25);

    final migrated = AppSettings.fromJson({'match_threshold': 0.72});
    expect(migrated.matchThreshold, 0.75);
  });

  testWidgets('settings page switches summarization provider and saves it', (
    tester,
  ) async {
    // testWidgets runs in a fake-async zone where real file I/O never
    // completes, so this repository keeps settings in memory instead.
    final repository = _InMemoryRepository();
    final controller = AppController(repository: repository);

    // The settings list is taller than the default test viewport.
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(LorraineApp(controller: controller));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Ollama is the default and hides the API key field.
    expect(find.text('Ollama (on this Mac)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);

    await tester.tap(find.text('Ollama (on this Mac)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();

    // Anthropic's defaults populate, and its key field appears.
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Base URL'))
          .controller!
          .text,
      'https://api.anthropic.com/v1',
    );
    expect(find.widgetWithText(TextField, 'API key'), findsNWidgets(2));

    await tester.enterText(
      find.widgetWithText(TextField, 'API key').last,
      'sk-ant-typed',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();

    // Saved settings carry the new provider, and the untouched Ollama entry
    // survived the switch.
    final saved = repository.settings;
    expect(saved.summaryProvider, SummaryProvider.anthropic);
    expect(saved.summaryConfig.apiKey, 'sk-ant-typed');
    expect(saved.summaryConfig.model, 'claude-opus-4-8');
    expect(saved.configFor(SummaryProvider.ollama).model, 'gemma3:4b');
  });

  test('imports meetings and recordings from the old macOS sandbox', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'lorraine-migration-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final support = Directory('${temporary.path}/support');
    final legacy = Directory('${temporary.path}/legacy');
    final legacyRecordings = Directory('${legacy.path}/recordings');
    await legacyRecordings.create(recursive: true);
    final legacyAudio = File('${legacyRecordings.path}/meeting-1.m4a');
    await legacyAudio.writeAsBytes([1, 2, 3]);
    await File('${legacy.path}/state.json').writeAsString(
      jsonEncode({
        'version': 1,
        'meetings': [
          Meeting(
            id: 'meeting-1',
            title: 'Recovered meeting',
            createdAt: DateTime.utc(2026, 7, 23),
            audioPath: legacyAudio.path,
            durationSeconds: 35,
            status: MeetingStatus.recorded,
          ).toJson(),
        ],
        'profiles': <Object>[],
        'settings': const AppSettings().toJson(),
      }),
    );
    final repository = AppRepository(
      supportDirectory: support,
      legacyRoot: legacy,
    );

    await repository.initialize();

    expect(repository.meetings.single.title, 'Recovered meeting');
    final migratedAudio = File(repository.meetings.single.audioPath);
    expect(migratedAudio.path, contains('/Lorraine/recordings/meeting-1.m4a'));
    expect(await migratedAudio.readAsBytes(), [1, 2, 3]);

    final reloaded = AppRepository(
      supportDirectory: support,
      legacyRoot: legacy,
    );
    await reloaded.initialize();
    expect(reloaded.meetings, hasLength(1));
  });

  test('same-name identities merge only when explicitly selected', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'lorraine-identity-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final repository = AppRepository(
      supportDirectory: Directory('${temporary.path}/support'),
      legacyRoot: Directory('${temporary.path}/legacy'),
    );
    await repository.initialize();
    final existing = SpeakerProfile(
      id: 'profile-existing',
      name: 'Alex Smith',
      email: 'alex@example.com',
      embeddings: const [
        [1, 0],
      ],
      samplePath: '/tmp/alex.wav',
      createdAt: DateTime.utc(2026, 7, 24),
    );
    repository.profiles.add(existing);
    repository.meetings.add(
      Meeting(
        id: 'meeting-identity',
        title: 'Identity test',
        createdAt: DateTime.utc(2026, 7, 24),
        audioPath: '/tmp/meeting.m4a',
        durationSeconds: 30,
        status: MeetingStatus.ready,
        speakers: const [
          MeetingSpeaker(id: 'SPEAKER_00', embedding: [0.9, 0.1]),
          MeetingSpeaker(id: 'SPEAKER_01', embedding: [0.8, 0.2]),
        ],
      ),
    );
    final controller = AppController(repository: repository);

    expect(
      controller.suggestedProfile(name: 'alex smith', email: ''),
      same(existing),
    );
    await controller.identifySpeaker(
      meetingId: 'meeting-identity',
      speakerId: 'SPEAKER_00',
      name: 'Alex Smith',
      email: 'different@example.com',
    );
    expect(repository.profiles, hasLength(2));
    expect(
      repository.meetings.single.speakers.first.profileId,
      isNot(existing.id),
    );

    await controller.identifySpeaker(
      meetingId: 'meeting-identity',
      speakerId: 'SPEAKER_01',
      name: 'Alex Smith',
      email: '',
      mergeWithProfileId: existing.id,
    );
    expect(repository.profiles, hasLength(2));
    expect(repository.meetings.single.speakers.last.profileId, existing.id);
    expect(
      repository.profiles
          .firstWhere((profile) => profile.id == existing.id)
          .enrollmentCount,
      2,
    );
  });

  test('legacy voice profiles migrate to multi-sample enrollment', () {
    final profile = SpeakerProfile.fromJson({
      'id': 'legacy-profile',
      'name': 'Pete',
      'email': '',
      'embedding': [3, 4],
      'sample_path': '/tmp/pete.wav',
      'created_at': '2026-07-24T00:00:00.000Z',
    });

    expect(profile.enrollmentCount, 1);
    expect(profile.embedding[0], closeTo(0.6, 0.0001));
    expect(profile.embedding[1], closeTo(0.8, 0.0001));
    expect(profile.toApiJson()['embeddings'], hasLength(1));
  });

  test('confirmed historical speakers enrich their voice profile', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'lorraine-enrollment-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final support = Directory('${temporary.path}/support');
    final root = Directory('${support.path}/Lorraine');
    await root.create(recursive: true);
    final profile = SpeakerProfile(
      id: 'profile-pete',
      name: 'Pete',
      email: '',
      embeddings: const [
        [1, 0],
      ],
      samplePath: '/tmp/pete.wav',
      createdAt: DateTime.utc(2026, 7, 24),
    );
    final meeting = Meeting(
      id: 'meeting-confirmed',
      title: 'Confirmed speaker',
      createdAt: DateTime.utc(2026, 7, 24),
      audioPath: '/tmp/meeting.m4a',
      durationSeconds: 30,
      status: MeetingStatus.ready,
      speakers: const [
        MeetingSpeaker(
          id: 'SPEAKER_00',
          embedding: [0, 1],
          profileId: 'profile-pete',
          identityConfirmed: true,
        ),
      ],
    );
    await File('${root.path}/state.json').writeAsString(
      jsonEncode({
        'version': 2,
        'meetings': [meeting.toJson()],
        'profiles': [profile.toJson()],
        'settings': const AppSettings().toJson(),
      }),
    );
    final repository = AppRepository(
      supportDirectory: support,
      legacyRoot: Directory('${temporary.path}/legacy'),
    );

    await repository.initialize();

    expect(repository.profiles.single.enrollmentCount, 2);
    expect(repository.profiles.single.embedding[0], closeTo(0.7071, 0.001));
    expect(repository.profiles.single.embedding[1], closeTo(0.7071, 0.001));
  });

  test(
    'multi-sample profile can match below the strict threshold with a clear margin',
    () {
      final pete = SpeakerProfile(
        id: 'profile-pete',
        name: 'Pete',
        email: '',
        embeddings: const [
          [1, 0, 0],
          [0.9, 0, 0.4359],
        ],
        samplePath: '/tmp/pete.wav',
        createdAt: DateTime.utc(2026, 7, 24),
      );
      final other = SpeakerProfile(
        id: 'profile-other',
        name: 'Other',
        email: '',
        embeddings: const [
          [0, 0, 1],
        ],
        samplePath: '/tmp/other.wav',
        createdAt: DateTime.utc(2026, 7, 24),
      );

      final match = matchVoiceProfile(
        const [0.6, 0.8, 0],
        [pete, other],
        threshold: 0.72,
      );

      expect(match, isNotNull);
      expect(match!.score, closeTo(0.6, 0.01));
      expect(match.profile.id, pete.id);
      expect(match.accepted, isTrue);
    },
  );

  test('single-sample profile still requires the strict threshold', () {
    final profile = SpeakerProfile(
      id: 'profile-pete',
      name: 'Pete',
      email: '',
      embeddings: const [
        [1, 0, 0],
      ],
      samplePath: '/tmp/pete.wav',
      createdAt: DateTime.utc(2026, 7, 24),
    );

    final match = matchVoiceProfile(
      const [0.6, 0.8, 0],
      [profile],
      threshold: 0.72,
    );

    expect(match, isNotNull);
    expect(match!.accepted, isFalse);
  });

  test('enriched matching sensitivity can be tightened', () {
    final profile = SpeakerProfile(
      id: 'profile-pete',
      name: 'Pete',
      email: '',
      embeddings: const [
        [1, 0, 0],
        [0.9, 0, 0.4359],
      ],
      samplePath: '/tmp/pete.wav',
      createdAt: DateTime.utc(2026, 7, 24),
    );

    final match = matchVoiceProfile(
      const [0.6, 0.8, 0],
      [profile],
      threshold: 0.72,
      enrichedThreshold: 0.62,
      requiredMargin: 0.25,
    );

    expect(match, isNotNull);
    expect(match!.score, closeTo(0.6, 0.01));
    expect(match.accepted, isFalse);
  });

  test('startup rematches unknown voices against enriched profiles', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'lorraine-rematch-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final support = Directory('${temporary.path}/support');
    final root = Directory('${support.path}/Lorraine');
    await root.create(recursive: true);
    final pete = SpeakerProfile(
      id: 'profile-pete',
      name: 'Pete',
      email: '',
      embeddings: const [
        [1, 0, 0],
        [0.9, 0, 0.4359],
      ],
      samplePath: '/tmp/pete.wav',
      createdAt: DateTime.utc(2026, 7, 24),
    );
    final meeting = Meeting(
      id: 'meeting-test2',
      title: 'test2',
      createdAt: DateTime.utc(2026, 7, 24),
      audioPath: '/tmp/test2.m4a',
      durationSeconds: 11,
      status: MeetingStatus.ready,
      speakers: const [
        MeetingSpeaker(id: 'SPEAKER_00', embedding: [0.6, 0.8, 0]),
      ],
    );
    await File('${root.path}/state.json').writeAsString(
      jsonEncode({
        'version': 2,
        'meetings': [meeting.toJson()],
        'profiles': [pete.toJson()],
        'settings': const AppSettings().toJson(),
      }),
    );
    final repository = AppRepository(
      supportDirectory: support,
      legacyRoot: Directory('${temporary.path}/legacy'),
    );

    await repository.initialize();

    final speaker = repository.meetings.single.speakers.single;
    expect(speaker.profileId, pete.id);
    expect(speaker.matchConfidence, closeTo(0.6, 0.01));
    expect(speaker.identityConfirmed, isFalse);
  });

  test('startup makes interrupted pre-upload meetings retryable', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'lorraine-interrupted-upload-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final support = Directory('${temporary.path}/support');
    final root = Directory('${support.path}/Lorraine');
    await root.create(recursive: true);
    final meeting = Meeting(
      id: 'meeting-interrupted',
      title: 'Interrupted upload',
      createdAt: DateTime.utc(2026, 7, 24),
      audioPath: '/tmp/original.m4a',
      durationSeconds: 3300,
      status: MeetingStatus.uploading,
      processingStage: 'Optimizing audio for transcription',
      progress: 0.01,
    );
    await File('${root.path}/state.json').writeAsString(
      jsonEncode({
        'version': 2,
        'meetings': [meeting.toJson()],
        'profiles': <Object>[],
        'settings': const AppSettings().toJson(),
      }),
    );
    final repository = AppRepository(
      supportDirectory: support,
      legacyRoot: Directory('${temporary.path}/legacy'),
    );

    await repository.initialize();

    final recovered = repository.meetings.single;
    expect(recovered.status, MeetingStatus.failed);
    expect(recovered.processingStage, 'Interrupted — ready to retry');
    expect(recovered.error, contains('original recording is safe'));
    expect(recovered.audioPath, meeting.audioPath);
  });

  test(
    'local model download does not put recording controls in stopping state',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'lorraine-independent-operations-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final repository = AppRepository(
        supportDirectory: Directory('${temporary.path}/support'),
        legacyRoot: Directory('${temporary.path}/legacy'),
      );
      await repository.initialize();
      repository.meetings.add(
        Meeting(
          id: 'meeting-summary',
          title: 'Earlier meeting',
          createdAt: DateTime.utc(2026, 7, 24),
          audioPath: '/tmp/earlier.m4a',
          durationSeconds: 10,
          status: MeetingStatus.ready,
          segments: const [
            TranscriptSegment(
              start: 0,
              end: 1,
              speakerId: 'SPEAKER_00',
              text: 'Summarize me.',
            ),
          ],
        ),
      );
      final summary = _PendingSummaryService();
      final controller = AppController(
        repository: repository,
        capture: _FakeAudioCaptureService(),
        summary: summary,
      )..captureSupported = true;
      await controller.startRecording('Active recording');

      final summaryFuture = controller.summarize('meeting-summary');
      await Future<void>.delayed(Duration.zero);

      expect(controller.isRecording, isTrue);
      expect(controller.isSummarizing, isTrue);
      expect(controller.isStoppingRecording, isFalse);

      summary.complete('# Summary\nDone');
      await summaryFuture;
      expect(controller.isSummarizing, isFalse);
      expect(controller.isRecording, isTrue);
      await controller.stopRecording();
    },
  );
}

class _FakeAudioCaptureService extends AudioCaptureService {
  @override
  Future<void> start(String outputPath) async {}

  @override
  Future<String> stop() async => '/tmp/active-recording.m4a';
}

class _PendingSummaryService extends SummaryService {
  final _completer = Completer<String>();

  void complete(String value) => _completer.complete(value);

  @override
  Future<String> summarize(
    Meeting meeting,
    AppSettings settings, {
    ValueChanged<SummaryProgress>? onProgress,
  }) {
    onProgress?.call(
      const SummaryProgress(
        message: 'Downloading gemma3:4b…',
        progress: 0.5,
      ),
    );
    return _completer.future;
  }
}

/// An [AppRepository] with no disk access, for widget tests.
class _InMemoryRepository extends AppRepository {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> save() async {}
}
