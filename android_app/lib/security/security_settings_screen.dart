/// Security settings: passphrase, biometrics, revocation, wipe.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../authentication/auth_service.dart';
import '../authentication/lock_controller.dart';
import 'secure_store.dart';
import '../storage/prefs.dart';

class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  String? _status;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.clear();
    _next.clear();
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _changePassphrase() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      final check = await auth.unlockWithPassphrase(_current.text);
      if (!check.ok) {
        setState(() => _error = check.message);
        return;
      }
      final problem = PassphrasePolicy.validate(_next.text);
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      await auth.setPassphrase(_next.text);
      setState(() => _status = 'Passphrase changed.');
      _current.clear();
      _next.clear();
    } catch (_) {
      setState(() => _error = 'Could not change the passphrase.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokePeer() async {
    final mode = ref.read(networkModeProvider);
    if (mode == NetworkMode.local) {
      setState(
        () => _error =
            'Local mode revocation is done from the laptop: POST /v1/admin/revoke with the console admin token, '
            'or restart the relay and re-pair. The console prints the exact command.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await ref
          .read(pairingServiceProvider)
          .revokePeerFromCloud();
      setState(() => _status = result);
    } catch (_) {
      setState(
        () => _error =
            'Revocation failed. Check the Worker URL and connectivity.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: SpColors.privateSurface,
        title: const Text('Forget this device?'),
        content: const Text(
          'This deletes the encrypted identity, passphrase verifier and pairing data from this phone. '
          'The pair on the relay is untouched; you would need a fresh invitation to return.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(secureStoreProvider).wipe();
    ref.read(lockControllerProvider.notifier).lockNow('device_wiped');
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(networkModeProvider);
    final store = ref.watch(secureStoreProvider);
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Security settings')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This device',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<String?>(
                        future: store.read(SecureKeys.deviceId),
                        builder: (context, snapshot) => Text(
                          'Device id: ${snapshot.data ?? '—'}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Mode: ${mode == NetworkMode.local ? 'local relay' : 'Cloudflare relay'}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8C93A8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Private keys live in the Android Keystore-protected store. They are never logged, '
                        'never uploaded, and not included in the recovery package.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6C7488),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Change passphrase',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _current,
                obscureText: true,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Current passphrase',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _next,
                obscureText: true,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'New passphrase',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _changePassphrase,
                child: const Text('Change passphrase'),
              ),
              const SizedBox(height: 24),
              const Text(
                'Other device',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Revoking frees the other slot and ends any active session immediately. '
                'The revoked device cannot reconnect, even with its old token.',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8C93A8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _revokePeer,
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Revoke the other device'),
              ),
              const SizedBox(height: 24),
              const Text(
                'Danger zone',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: SpColors.coral,
                ),
                onPressed: _wipe,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Forget this device'),
              ),
              const SizedBox(height: 16),
              if (_status != null)
                Text(
                  _status!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SpColors.privateAccent,
                  ),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: SpColors.coral),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
