import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lorraine/app_controller.dart';
import 'package:lorraine/main.dart';
import 'package:lorraine/models.dart';
import 'package:lorraine/repository.dart';

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
    expect(AppSettings.fromJson(settings.toJson()).autoDeployModal, isTrue);
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
}
