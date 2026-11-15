/// Encrypted recovery.
///
/// Creating a package produces a text blob the user stores offline (password
/// manager or printed). It contains pair membership metadata only — no keys that
/// can read past messages, because such keys do not exist.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../core/ids.dart';
import '../security/secure_store.dart';
import 'recovery_service.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _package = TextEditingController();
  String? _output;
  String? _status;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _passphrase.clear();
    _package.clear();
    _passphrase.dispose();
    _package.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _output = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      final pairId = await store.read(SecureKeys.pairId);
      final role = await store.read(SecureKeys.role);
      final deviceId = await store.read(SecureKeys.deviceId);
      final peerDeviceId = await store.read(SecureKeys.peerDeviceId);
      final peerKey = await store.read(SecureKeys.peerPublicKey);
      final identity = await ref.read(identityProvider.future);

      if (pairId == null ||
          role == null ||
          deviceId == null ||
          peerDeviceId == null ||
          peerKey == null) {
        setState(
          () =>
              _error = 'Pair this device first: the package is tied to a pair.',
        );
        return;
      }

      final sealed = await ref
          .read(recoveryServiceProvider)
          .seal(
            passphrase: _passphrase.text,
            info: RecoveryInfo(
              pairId: pairId,
              role: role,
              oldDeviceId: deviceId,
              oldIdentityPublicKey: _standardBase64(identity.ed25519PublicKey),
              peerDeviceId: peerDeviceId,
              peerPublicKey: _standardBase64(peerKey),
              createdAt: DateTime.now().millisecondsSinceEpoch,
              recoveryId: 'r_${randomBase64u(12)}',
              label: 'Device $role',
            ),
          );
      setState(() {
        _output = sealed;
        _status = 'Package created. Store it somewhere offline — it is useless without the passphrase.';
      });
    } on RecoveryException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not create the package.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final info = await ref
          .read(recoveryServiceProvider)
          .open(sealedJson: _package.text.trim(), passphrase: _passphrase.text);
      final store = ref.read(secureStoreProvider);
      await store.write(SecureKeys.pairId, info.pairId);
      await store.write(SecureKeys.role, info.role);
      await store.write(SecureKeys.peerDeviceId, info.peerDeviceId);
      await store.write(SecureKeys.peerPublicKey, info.peerPublicKey);
      setState(
        () => _status =
            'Restored pair ${info.pairId}. This device has a new identity: the other phone must approve it '
            'and you must compare the security code before talking.',
      );
    } on RecoveryException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not open the package.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _standardBase64(String base64url) {
    final normalised = base64url.replaceAll('-', '+').replaceAll('_', '/');
    final padding = normalised.length % 4 == 0
        ? ''
        : '=' * (4 - normalised.length % 4);
    return '$normalised$padding';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Recovery')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text(
                'Create a recovery package',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Argon2id + XChaCha20-Poly1305 over a small metadata file: pair id, slot, public keys '
                'and timestamps. No messages, no session keys, no media.',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8C93A8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passphrase,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Recovery passphrase (12+ characters)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.lock_outline),
                label: const Text('Create encrypted package'),
              ),
              if (_output != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SpColors.privateSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SpColors.privateLine),
                  ),
                  child: SelectableText(
                    _output!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _output!));
                    if (!mounted) return;
                    setState(
                      () => _status =
                          'Copied. Store it offline, then clear the clipboard.',
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy package'),
                ),
              ],
              const SizedBox(height: 26),
              const Divider(color: SpColors.privateLine),
              const SizedBox(height: 16),
              const Text(
                'Restore on a new device',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Restoring tells this phone which pair to rejoin. It does not restore chat history '
                'and it does not make the other device trust it automatically.',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8C93A8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _package,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Paste the package',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore),
                label: const Text('Restore and continue'),
              ),
              if (_status != null) ...[
                const SizedBox(height: 14),
                Text(
                  _status!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SpColors.privateAccent,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: SpColors.coral),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
