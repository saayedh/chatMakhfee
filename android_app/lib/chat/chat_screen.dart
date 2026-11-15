/// Session-only private chat.
///
/// There is no history to load: on open the list is empty, and it is empty again
/// after a lock. The screen keeps the input controller local and clears it on
/// dispose.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../authentication/lock_controller.dart';
import '../app/theme.dart';
import '../networking/pairing_service.dart';
import '../sessions/session_controller.dart';
import '../sessions/session_state.dart';
import '../storage/prefs.dart';
import 'message_model.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _input.clear();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final mode = ref.read(networkModeProvider);
      final credentials = await ref.read(pairingServiceProvider).loadSaved();
      if (credentials == null) {
        setState(
          () => _error = 'No paired device yet. Open Network & pairing.',
        );
        return;
      }
      await ref
          .read(sessionProvider.notifier)
          .connect(
            credentials: credentials,
            cloudMode: mode == NetworkMode.cloud,
          );
    } on PairingException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not open the session.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await ref.read(sessionProvider.notifier).sendText(text);
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final snapshot = session.snapshot;
    final connected =
        snapshot.phase != SessionPhase.idle &&
        snapshot.phase != SessionPhase.ended;

    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Private chat'),
          actions: [
            IconButton(
              tooltip: 'Voice call',
              onPressed: () => Navigator.of(context).pushNamed('/vault/call'),
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'Lock',
              onPressed: () =>
                  ref.read(lockControllerProvider.notifier).lockNow('user_exit'),
              icon: const Icon(Icons.lock_outline),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              _Banner(snapshot: snapshot, notice: session.notice),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: SpColors.coral, fontSize: 12),
                  ),
                ),
              Expanded(
                child: session.messages.isEmpty
                    ? _Empty(
                        connected: connected,
                        onConnect: _connecting ? null : _connect,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        itemCount: session.messages.length,
                        itemBuilder: (context, index) =>
                            _Bubble(message: session.messages[index]),
                      ),
              ),
              _Composer(
                controller: _input,
                enabled: session.canSend,
                onSend: _send,
                hint: session.canSend
                    ? 'Encrypted message'
                    : snapshot.peerPresent
                    ? 'Waiting for the relay…'
                    : 'The other device is not connected',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.snapshot, required this.notice});

  final SessionSnapshot snapshot;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final text = switch (snapshot.phase) {
      SessionPhase.idle => 'No session. Connect when you are both ready.',
      SessionPhase.connecting => 'Opening the relay…',
      SessionPhase.waitingForPeer =>
        'Authenticated. Waiting for the other device.',
      SessionPhase.active => 'Live session. Nothing is stored on either side.',
      SessionPhase.ended => 'Session ended. Messages were cleared.',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: SpColors.privateSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3B8)),
          ),
          if (notice != null) ...[
            const SizedBox(height: 4),
            Text(
              notice!,
              style: const TextStyle(fontSize: 11, color: SpColors.sun),
            ),
          ],
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.connected, required this.onConnect});

  final bool connected;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_clock, size: 40, color: Color(0xFF41506B)),
            const SizedBox(height: 14),
            Text(
              connected
                  ? 'Nothing here yet.\nMessages appear only while both devices are connected.'
                  : 'Start a session to talk.\nHistory is never saved — not on the relay, not on this phone.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8C93A8),
                height: 1.5,
                fontSize: 13,
              ),
            ),
            if (!connected) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF14332C) : SpColors.privateSurface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: Border.all(color: SpColors.privateLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              message.status == MessageStatus.failed
                  ? 'not sent'
                  : '${message.at.hour.toString().padLeft(2, '0')}:${message.at.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 9,
                color: message.status == MessageStatus.failed
                    ? SpColors.coral
                    : const Color(0xFF6C7488),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.hint,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: SpColors.privateSurface,
        border: Border(top: BorderSide(color: SpColors.privateLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                filled: true,
                fillColor: SpColors.privateInk,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
