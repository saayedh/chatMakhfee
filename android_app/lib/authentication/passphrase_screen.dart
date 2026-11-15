/// Passphrase setup and unlock.
///
/// Deliberately minimal widgets: no preview of the passphrase, no autofill, no
/// clipboard menu, and the controller is cleared on lock by the parent.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'auth_service.dart';
import '../security/native_bridge.dart';
import '../app/theme.dart';
import 'lock_controller.dart';

class PassphraseScreen extends ConsumerStatefulWidget {
  const PassphraseScreen({this.insideCover = false, super.key});

  final bool insideCover;

  @override
  ConsumerState<PassphraseScreen> createState() => _PassphraseScreenState();
}

class _PassphraseScreenState extends ConsumerState<PassphraseScreen> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  bool _configured = false;
  bool _biometrics = false;
  bool _passphraseVerified = false;
  String? _error;
  String? _notice;
  StreamSubscription<String>? _lockSubscription;

  @override
  void initState() {
    super.initState();
    _prepare();
    _lockSubscription = ref.read(nativeBridgeProvider).lockRequests.listen((_) {
      _clearIntermediateAuthentication();
    });
  }

  Future<void> _prepare() async {
    final auth = ref.read(authServiceProvider);
    final configured = await auth.refreshConfigured();
    final biometrics = await auth.canUseBiometrics();
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _biometrics = biometrics;
    });
  }

  void _clearIntermediateAuthentication() {
    _passphrase.clear();
    _confirm.clear();
    if (_passphraseVerified) {
      _passphraseVerified = false;
      if (mounted) {
        setState(() {
          _notice = null;
          _error = 'Authentication was reset because the app was locked.';
        });
      }
    }
  }

  @override
  void dispose() {
    // Best effort: the controller's buffer is overwritten before disposal.
    _passphrase.clear();
    _confirm.clear();
    _lockSubscription?.cancel();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      if (!_configured) {
        final problem = _validateSetup();
        if (problem != null) {
          setState(() => _error = problem);
          return;
        }
        await auth.setPassphrase(_passphrase.text);
        if (!mounted) return;
        setState(() {
          _configured = true;
          _notice = 'Passphrase set. Keep it somewhere safe — it cannot be recovered.';
        });
        _passphrase.clear();
        _confirm.clear();
        return;
      }

      final result = await auth.unlockWithPassphrase(_passphrase.text);
      if (!mounted) return;
      if (!result.ok) {
        _passphrase.clear();
        setState(() => _error = result.message);
        return;
      }
      _passphrase.clear();
      if (_biometrics) {
        setState(() {
          _passphraseVerified = true;
          _notice = 'Passphrase accepted. Complete biometric verification to unlock.';
        });
        return;
      }
      ref.read(lockControllerProvider.notifier).markAuthenticated();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validateSetup() {
    if (_passphrase.text != _confirm.text)
      return 'The two passphrases do not match.';
    return PassphrasePolicy.validate(_passphrase.text);
  }

  Future<void> _biometric() async {
    if (!_passphraseVerified) {
      setState(() => _error = 'Enter your passphrase first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(authServiceProvider).unlockWithBiometrics();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      _passphraseVerified = false;
      ref.read(lockControllerProvider.notifier).markAuthenticated();
    } else {
      setState(() => _error = result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(lockControllerProvider, (previous, next) {
      if (next.isLocked && previous?.isLocked == false) {
        _clearIntermediateAuthentication();
      }
    });
    final reason = ref.watch(lockControllerProvider).reason;
    return Material(
      color: SpColors.privateInk,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 44,
                  color: SpColors.privateAccent,
                ),
                const SizedBox(height: 18),
                Text(
                  _configured
                      ? 'SecretPlay is locked'
                      : 'Create your private passphrase',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (_configured && reason != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    describeLockReason(reason),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF8C93A8)),
                  ),
                ],
                const SizedBox(height: 26),
                if (!_passphraseVerified) TextField(
                  controller: _passphrase,
                  obscureText: true,
                  autofocus: !_configured,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableInteractiveSelection: false,
                  decoration: const InputDecoration(
                    labelText: 'Passphrase',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (!_configured) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    enableInteractiveSelection: false,
                    decoration: const InputDecoration(
                      labelText: 'Confirm passphrase',
                      border: OutlineInputBorder(),
                      helperText: 'At least 12 characters. Argon2id, never stored in plaintext.',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: SpColors.coral)),
                ],
                if (_passphraseVerified) ...[
                  const Text(
                    'First factor verified. Complete the biometric check to continue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SpColors.privateAccent),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _notice!,
                    style: const TextStyle(color: SpColors.privateAccent),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy || _passphraseVerified ? null : _submit,
                  child: Text(_configured ? 'Verify passphrase' : 'Set passphrase'),
                ),
                if (_biometrics && _configured) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy || !_passphraseVerified ? null : _biometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Complete biometric verification'),
                  ),
                ],
                const SizedBox(height: 18),
                const Text(
                  'The game is part of SecretPlay, so unlocking opens both areas. '
                  'Leaving the app locks everything immediately.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF6C7488), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
