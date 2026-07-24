import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'app_controller.dart';
import 'models.dart';
import 'services.dart';

class LorraineShell extends StatefulWidget {
  const LorraineShell({required this.controller, super.key});

  final AppController controller;

  @override
  State<LorraineShell> createState() => _LorraineShellState();
}

class _LorraineShellState extends State<LorraineShell> {
  int page = 0;
  String? selectedMeetingId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final selected = selectedMeetingId == null
            ? null
            : widget.controller.meetingById(selectedMeetingId!);
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                backgroundColor: const Color(0xFFEEF0E8),
                selectedIndex: page,
                onDestinationSelected: (value) => setState(() => page = value),
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.only(top: 16, bottom: 28),
                  child: _Logo(),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.library_books_outlined),
                    selectedIcon: Icon(Icons.library_books),
                    label: Text('Meetings'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.graphic_eq_outlined),
                    selectedIcon: Icon(Icons.graphic_eq),
                    label: Text('Voices'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('Settings'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Stack(
                  children: [
                    if (page == 0)
                      selected == null
                          ? MeetingsPage(
                              controller: widget.controller,
                              onSelect: (id) =>
                                  setState(() => selectedMeetingId = id),
                            )
                          : MeetingPage(
                              controller: widget.controller,
                              meetingId: selected.id,
                              onBack: () =>
                                  setState(() => selectedMeetingId = null),
                            )
                    else if (page == 1)
                      VoicesPage(controller: widget.controller)
                    else
                      SettingsPage(controller: widget.controller),
                    if (widget.controller.isRecording)
                      RecordingBar(
                        elapsed: widget.controller.recordingElapsed,
                        stopping: widget.controller.busy,
                        onStop: () async {
                          final id = await widget.controller.stopRecording();
                          if (id != null) {
                            setState(() {
                              page = 0;
                              selectedMeetingId = id;
                            });
                          }
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(13),
    ),
    alignment: Alignment.center,
    child: const Text(
      'L',
      style: TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class MeetingsPage extends StatelessWidget {
  const MeetingsPage({
    required this.controller,
    required this.onSelect,
    super.key,
  });

  final AppController controller;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'Meetings',
      subtitle: 'Your recordings stay on this device.',
      trailing: FilledButton.icon(
        onPressed: controller.isRecording ? null : () => _startDialog(context),
        icon: const Icon(Icons.mic),
        label: const Text('Record meeting'),
      ),
      notice: controller.notice,
      child: controller.meetings.isEmpty
          ? _EmptyState(
              icon: Icons.mic_none_rounded,
              title: 'No meetings yet',
              body:
                  'Record system audio and your microphone, then send the result to WhisperX.',
              action: FilledButton(
                onPressed: () => _startDialog(context),
                child: const Text('Start recording'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 120),
              itemCount: controller.meetings.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final meeting = controller.meetings[index];
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    leading: _StatusIcon(status: meeting.status),
                    title: Text(
                      meeting.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '${_date(meeting.createdAt)}  •  ${_duration(meeting.durationSeconds)}  •  ${_status(meeting.status)}',
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onSelect(meeting.id),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _startDialog(BuildContext context) async {
    final title = TextEditingController(
      text: 'Meeting ${_date(DateTime.now())}',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Record a meeting'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Meeting title'),
              ),
              const SizedBox(height: 14),
              const Text(
                'macOS will ask for microphone and Screen Recording permission. The screen image is never stored; that permission is needed to capture speaker audio.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start recording'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.startRecording(title.text);
  }
}

class MeetingPage extends StatelessWidget {
  const MeetingPage({
    required this.controller,
    required this.meetingId,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final String meetingId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final meeting = controller.meetingById(meetingId);
    if (meeting == null) return const SizedBox.shrink();
    final canTranscribe =
        meeting.status == MeetingStatus.recorded ||
        meeting.status == MeetingStatus.failed;
    return _Page(
      title: meeting.title,
      subtitle:
          '${_date(meeting.createdAt)}  •  ${_duration(meeting.durationSeconds)}',
      leading: IconButton(
        onPressed: onBack,
        icon: const Icon(Icons.arrow_back),
      ),
      notice: meeting.error ?? controller.notice,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canTranscribe)
            OutlinedButton.icon(
              onPressed: () => controller.transcribe(meeting.id),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(
                meeting.status == MeetingStatus.failed ? 'Retry' : 'Transcribe',
              ),
            ),
          if (meeting.segments.isNotEmpty) ...[
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: controller.busy
                  ? null
                  : () => controller.summarize(meeting.id),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Summarize locally'),
            ),
          ],
        ],
      ),
      child:
          meeting.status == MeetingStatus.uploading ||
              meeting.status == MeetingStatus.processing
          ? _Processing(status: meeting.status)
          : meeting.segments.isEmpty
          ? _EmptyState(
              icon: Icons.description_outlined,
              title: 'Recording saved',
              body: controller.settings.modalConfigured
                  ? 'Ready to send to your private Modal endpoint.'
                  : 'Configure the Modal endpoint in Settings, then transcribe this recording.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 100),
              children: [
                if (meeting.summary != null && meeting.summary!.isNotEmpty) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: MarkdownBody(data: meeting.summary!),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Text(
                  'Transcript',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                ...meeting.segments.map(
                  (segment) => _TranscriptRow(
                    controller: controller,
                    meeting: meeting,
                    segment: segment,
                  ),
                ),
              ],
            ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({
    required this.controller,
    required this.meeting,
    required this.segment,
  });

  final AppController controller;
  final Meeting meeting;
  final TranscriptSegment segment;

  @override
  Widget build(BuildContext context) {
    final speaker = meeting.speakers
        .where((item) => item.id == segment.speakerId)
        .firstOrNull;
    final known = speaker?.profileId != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              _timestamp(segment.start),
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          SizedBox(
            width: 150,
            child: Align(
              alignment: Alignment.topLeft,
              child: ActionChip(
                avatar: Icon(
                  known ? Icons.person : Icons.person_outline,
                  size: 16,
                ),
                label: Text(
                  controller.speakerName(meeting, segment.speakerId),
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: speaker == null
                    ? null
                    : () => _identifyDialog(
                        context,
                        controller,
                        meeting,
                        speaker,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SelectableText(
              segment.text,
              style: const TextStyle(fontSize: 15.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class VoicesPage extends StatefulWidget {
  const VoicesPage({required this.controller, super.key});

  final AppController controller;

  @override
  State<VoicesPage> createState() => _VoicesPageState();
}

class _VoicesPageState extends State<VoicesPage> {
  final player = AudioPlayer();

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unknown = widget.controller.unknownVoices.toList();
    return _Page(
      title: 'Voice library',
      subtitle:
          'Identify a voice once; future meetings can recognize it automatically.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 100),
        children: [
          Text(
            'Unrecognized voices (${unknown.length})',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (unknown.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No unrecognized voices.'),
              ),
            )
          else
            ...unknown.map(
              (entry) => _VoiceCard(
                title: widget.controller.speakerName(
                  entry.meeting,
                  entry.speaker.id,
                ),
                subtitle: entry.meeting.title,
                samplePath: entry.speaker.samplePath,
                onPlay: () => _play(entry.speaker.samplePath),
                onIdentify: () => _identifyDialog(
                  context,
                  widget.controller,
                  entry.meeting,
                  entry.speaker,
                ),
              ),
            ),
          const SizedBox(height: 30),
          Text(
            'Known people (${widget.controller.profiles.length})',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (widget.controller.profiles.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Known people will appear here after you identify a voice.',
                ),
              ),
            )
          else
            ...widget.controller.profiles.map(
              (profile) => _VoiceCard(
                title: profile.name,
                subtitle: profile.email.isEmpty ? 'No email' : profile.email,
                samplePath: profile.samplePath,
                onPlay: () => _play(profile.samplePath),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _play(String? path) async {
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    await player.play(DeviceFileSource(path));
  }
}

class _VoiceCard extends StatelessWidget {
  const _VoiceCard({
    required this.title,
    required this.subtitle,
    required this.samplePath,
    required this.onPlay,
    this.onIdentify,
  });
  final String title;
  final String subtitle;
  final String? samplePath;
  final VoidCallback onPlay;
  final VoidCallback? onIdentify;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: CircleAvatar(
        child: Icon(onIdentify == null ? Icons.person : Icons.question_mark),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: samplePath == null ? null : onPlay,
            tooltip: 'Play sample',
            icon: const Icon(Icons.play_arrow),
          ),
          if (onIdentify != null)
            FilledButton.tonal(
              onPressed: onIdentify,
              child: const Text('Identify'),
            ),
        ],
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.controller, super.key});
  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController modal;
  late final TextEditingController apiKey;
  late final TextEditingController ollama;
  late final TextEditingController model;
  late double threshold;
  late bool autoDeployModal;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    modal = TextEditingController(text: settings.modalBaseUrl);
    apiKey = TextEditingController(text: settings.apiKey);
    ollama = TextEditingController(text: settings.ollamaUrl);
    model = TextEditingController(text: settings.ollamaModel);
    threshold = settings.matchThreshold;
    autoDeployModal = settings.autoDeployModal;
  }

  @override
  void dispose() {
    modal.dispose();
    apiKey.dispose();
    ollama.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (modal.text.isEmpty &&
        widget.controller.settings.modalBaseUrl.isNotEmpty) {
      modal.text = widget.controller.settings.modalBaseUrl;
    }
    return _Page(
      title: 'Settings',
      subtitle: 'Connect transcription and local summarization.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 100),
        children: [
          _SettingsCard(
            title: 'Modal + WhisperX',
            subtitle: 'Lorraine can deploy its bundled backend with Modal CLI.',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Deploy automatically on startup'),
                subtitle: const Text(
                  'Uses the authenticated Modal CLI installed on this computer.',
                ),
                value: autoDeployModal,
                onChanged: (value) => setState(() => autoDeployModal = value),
              ),
              if (widget.controller.modalDeploymentMessage != null) ...[
                const SizedBox(height: 8),
                _DeploymentStatus(
                  state: widget.controller.modalDeploymentState,
                  message: widget.controller.modalDeploymentMessage!,
                ),
                const SizedBox(height: 14),
              ],
              TextField(
                controller: modal,
                decoration: const InputDecoration(
                  labelText: 'Modal endpoint',
                  hintText: 'https://your-workspace--lorraine-api.modal.run',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: apiKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key (optional)',
                ),
              ),
              const SizedBox(height: 18),
              Text('Voice match threshold: ${threshold.toStringAsFixed(2)}'),
              Slider(
                value: threshold,
                min: 0.55,
                max: 0.90,
                divisions: 35,
                onChanged: (value) => setState(() => threshold = value),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed:
                      widget.controller.modalDeploymentState ==
                          ModalDeploymentState.deploying
                      ? null
                      : widget.controller.deployModal,
                  icon: const Icon(Icons.rocket_launch_outlined),
                  label: const Text('Deploy now'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsCard(
            title: 'Local summary',
            subtitle:
                'Uses Ollama on this computer; transcript text never leaves the device.',
            children: [
              TextField(
                controller: ollama,
                decoration: const InputDecoration(labelText: 'Ollama URL'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: model,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText: 'gemma3:4b',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Recordings, transcripts, voice fingerprints, and samples are stored in the app support folder on this Mac. They are not encrypted by Lorraine.',
                    ),
                  ),
                  FilledButton(
                    onPressed: () async {
                      await widget.controller.saveSettings(
                        AppSettings(
                          modalBaseUrl: modal.text.trim(),
                          apiKey: apiKey.text,
                          autoDeployModal: autoDeployModal,
                          ollamaUrl: ollama.text.trim(),
                          ollamaModel: model.text.trim(),
                          matchThreshold: threshold,
                        ),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Settings saved')),
                      );
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeploymentStatus extends StatelessWidget {
  const _DeploymentStatus({required this.state, required this.message});

  final ModalDeploymentState state;
  final String message;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      ModalDeploymentState.ready => (
        Icons.check_circle_outline,
        Colors.green.shade700,
      ),
      ModalDeploymentState.failed => (Icons.error_outline, Colors.red.shade700),
      ModalDeploymentState.unavailable => (
        Icons.info_outline,
        Colors.orange.shade800,
      ),
      ModalDeploymentState.checking ||
      ModalDeploymentState.deploying => (Icons.sync, Colors.blueGrey),
      ModalDeploymentState.idle => (Icons.cloud_outlined, Colors.blueGrey),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(message)),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(subtitle),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
}

class RecordingBar extends StatelessWidget {
  const RecordingBar({
    required this.elapsed,
    required this.stopping,
    required this.onStop,
    super.key,
  });
  final Duration elapsed;
  final bool stopping;
  final VoidCallback onStop;
  @override
  Widget build(BuildContext context) => Positioned(
    left: 28,
    right: 28,
    bottom: 24,
    child: Material(
      elevation: 12,
      color: const Color(0xFF1D2921),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFF6B61),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Recording system audio + microphone',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              _duration(elapsed.inSeconds),
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFFE6E2),
                foregroundColor: const Color(0xFF7D1E16),
              ),
              onPressed: stopping ? null : onStop,
              icon: stopping
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    this.leading,
    this.notice,
  });
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;
  final Widget? leading;
  final String? notice;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 30, 32, 20),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(color: Colors.grey.shade700)),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
      if (notice != null)
        Container(
          margin: const EdgeInsets.fromLTRB(32, 0, 32, 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE9D3),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(notice!),
        ),
      Expanded(child: child),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 50, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 18),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 480,
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.5),
            ),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

class _Processing extends StatelessWidget {
  const _Processing({required this.status});
  final MeetingStatus status;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 38,
          child: CircularProgressIndicator(),
        ),
        const SizedBox(height: 18),
        Text(
          status == MeetingStatus.uploading
              ? 'Uploading recording…'
              : 'WhisperX is transcribing and finding speakers…',
        ),
        const SizedBox(height: 8),
        const Text(
          'You can leave this page; Lorraine will keep checking the job.',
        ),
      ],
    ),
  );
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final MeetingStatus status;
  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      MeetingStatus.ready => (Icons.check_rounded, const Color(0xFF4F7659)),
      MeetingStatus.failed => (Icons.error_outline, Colors.red.shade600),
      MeetingStatus.uploading ||
      MeetingStatus.processing => (Icons.sync, Colors.blueGrey),
      MeetingStatus.recorded => (Icons.mic, Colors.deepOrange.shade400),
    };
    return CircleAvatar(
      backgroundColor: color.withValues(alpha: .12),
      foregroundColor: color,
      child: Icon(icon),
    );
  }
}

Future<void> _identifyDialog(
  BuildContext context,
  AppController controller,
  Meeting meeting,
  MeetingSpeaker speaker,
) async {
  final name = TextEditingController();
  final email = TextEditingController();
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Identify this voice'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: email,
              decoration: const InputDecoration(labelText: 'Email (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, name.text.trim().isNotEmpty),
          child: const Text('Save identity'),
        ),
      ],
    ),
  );
  if (accepted == true) {
    await controller.identifySpeaker(
      meetingId: meeting.id,
      speakerId: speaker.id,
      name: name.text,
      email: email.text,
    );
  }
}

String _status(MeetingStatus status) => switch (status) {
  MeetingStatus.recorded => 'Saved locally',
  MeetingStatus.uploading => 'Uploading',
  MeetingStatus.processing => 'Transcribing',
  MeetingStatus.ready => 'Ready',
  MeetingStatus.failed => 'Needs attention',
};
String _duration(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
String _timestamp(double seconds) => _duration(seconds.floor());
String _date(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}, ${date.year}';
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
