/// Voice call UI.
///
/// While a call is active Android shows a microphone indicator and a
/// foreground-service notification. That is deliberate and cannot be disabled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../security/native_bridge.dart';
import 'call_controller.dart';

class VoiceCallScreen extends ConsumerWidget {
  const VoiceCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final controller = ref.read(callProvider.notifier);
    final bridge = ref.watch(nativeBridgeProvider);

    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Voice call')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                _Avatar(active: call.phase == CallPhase.active),
                const SizedBox(height: 20),
                Text(
                  _title(call),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitle(call),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8C93A8),
                    height: 1.4,
                  ),
                ),
                if (call.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    call.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: SpColors.coral, fontSize: 12),
                  ),
                ],
                const Spacer(),
                if (call.phase == CallPhase.incoming)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: controller.rejectCall,
                          icon: const Icon(Icons.call_end),
                          label: const Text('Reject'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: controller.acceptCall,
                          icon: const Icon(Icons.call),
                          label: const Text('Accept'),
                        ),
                      ),
                    ],
                  )
                else if (call.isBusy)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundAction(
                        icon: call.muted ? Icons.mic_off : Icons.mic,
                        label: call.muted ? 'Unmute' : 'Mute',
                        active: call.muted,
                        onTap: controller.toggleMute,
                      ),
                      _RoundAction(
                        icon: call.speaker
                            ? Icons.volume_up
                            : Icons.phone_in_talk,
                        label: call.speaker ? 'Speaker' : 'Earpiece',
                        active: call.speaker,
                        onTap: controller.toggleSpeaker,
                      ),
                      _RoundAction(
                        icon: Icons.call_end,
                        label: 'End',
                        danger: true,
                        onTap: controller.hangUp,
                      ),
                    ],
                  )
                else
                  FilledButton.icon(
                    onPressed: () async {
                      final granted = await bridge
                          .requestMicrophonePermission();
                      if (!granted) return;
                      await controller.startCall();
                    },
                    icon: const Icon(Icons.call),
                    label: const Text('Start call'),
                  ),
                const SizedBox(height: 18),
                const _AudioNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _title(CallState call) => switch (call.phase) {
    CallPhase.idle => 'Ready to call',
    CallPhase.outgoing => 'Calling…',
    CallPhase.incoming => 'Incoming call',
    CallPhase.connecting => 'Connecting audio…',
    CallPhase.active => _format(call.duration),
    CallPhase.ended => 'Call ended',
  };

  String _subtitle(CallState call) {
    if (call.phase == CallPhase.idle) {
      return 'Audio is sent directly between the two phones, protected by WebRTC DTLS-SRTP.\nNothing is recorded or transcribed.';
    }
    if (call.phase == CallPhase.active)
      return 'Direct connection · encrypted media';
    if (call.phase == CallPhase.ended) return 'Microphone released.';
    return 'Signalling is encrypted with the same Olm session as your messages.';
  }

  String _format(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: active
              ? [
                  SpColors.privateAccent.withValues(alpha: 0.7),
                  const Color(0xFF1E3B33),
                ]
              : [const Color(0xFF1B2334), const Color(0xFF11151F)],
        ),
        border: Border.all(color: SpColors.privateLine),
      ),
      child: Icon(
        active ? Icons.graphic_eq : Icons.person_outline,
        size: 46,
        color: active ? SpColors.privateInk : const Color(0xFF6C7488),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? SpColors.coral
        : active
        ? SpColors.privateAccent
        : const Color(0xFF8C93A8);
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Icon(icon, color: color),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}

class _AudioNote extends StatelessWidget {
  const _AudioNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.info_outline,
          size: 14,
          color: Colors.white.withValues(alpha: 0.35),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Bluetooth headsets route automatically when connected. '
            'If the call fails to connect, the networks may need the optional TURN relay.',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ),
      ],
    );
  }
}

/// Exposed for the security checklist: a call must never outlive a lock.
bool callSurvivesLock(CallState call, bool locked) => !(locked && call.isBusy);
