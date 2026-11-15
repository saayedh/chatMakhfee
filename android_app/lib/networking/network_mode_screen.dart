/// Network mode and pairing.
///
/// Cloud mode: create a pair and show a QR, or scan the other device's QR.
/// Local mode: scan the laptop's QR (which carries the one-time invitation).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../cryptography/olm_service.dart';
import '../storage/prefs.dart';
import 'pairing_service.dart';
import 'protocol.dart';

class NetworkModeScreen extends ConsumerStatefulWidget {
  const NetworkModeScreen({super.key});

  @override
  ConsumerState<NetworkModeScreen> createState() => _NetworkModeScreenState();
}

class _NetworkModeScreenState extends ConsumerState<NetworkModeScreen> {
  final TextEditingController _cloudBase = TextEditingController();
  String? _qr;
  String? _status;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _cloudBase.dispose();
    super.dispose();
  }

  Future<void> _createCloudPair() async {
    await _run(() async {
      final identity = await ref.read(identityProvider.future);
      final created = await ref
          .read(pairingServiceProvider)
          .createCloud(cloudBaseUrl: _trimmedBase, identity: identity);
      setState(() {
        _qr = created.qrPayload;
        _status =
            'Show this code to the other phone. It expires in ten minutes.';
      });
    });
  }

  String get _trimmedBase =>
      _cloudBase.text.trim().replaceAll(RegExp(r'/+$'), '');

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } on PairingException catch (error) {
      setState(() => _error = error.message);
    } on OlmException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(
        () => _error =
            'Something went wrong. Check the relay address and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(networkModeProvider);
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Network & pairing')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              SegmentedButton<NetworkMode>(
                segments: const [
                  ButtonSegment(
                    value: NetworkMode.cloud,
                    label: Text('Cloud'),
                    icon: Icon(Icons.cloud_outlined),
                  ),
                  ButtonSegment(
                    value: NetworkMode.local,
                    label: Text('Local'),
                    icon: Icon(Icons.wifi_tethering),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (selection) {
                  ref
                      .read(networkModeProvider.notifier)
                      .select(selection.first);
                  setState(() {
                    _qr = null;
                    _status = null;
                  });
                },
              ),
              const SizedBox(height: 16),
              Text(
                mode == NetworkMode.cloud
                    ? 'Pair through the deployed Worker. The second phone scans the QR, then both devices confirm the security code.'
                    : 'Pair through the laptop on your network. Start run-local.bat, then scan the QR it prints.',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8C93A8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              if (mode == NetworkMode.cloud) ...[
                TextField(
                  controller: _cloudBase,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Worker URL',
                    hintText: 'https://secretplay.your-name.workers.dev',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy || _trimmedBase.isEmpty
                      ? null
                      : _createCloudPair,
                  icon: const Icon(Icons.add_link),
                  label: const Text('Create pair and show QR'),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).pushNamed('/vault/scan'),
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  mode == NetworkMode.cloud
                      ? 'Scan the other phone'
                      : 'Scan the laptop QR',
                ),
              ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(
                  _status!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SpColors.privateAccent,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: SpColors.coral),
                ),
              ],
              if (_qr != null) ...[
                const SizedBox(height: 18),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: QrImageView(data: _qr!, size: 220),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => ref.read(pairingServiceProvider).forget(),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Forget pairing on this device'),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const _LimitsCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LimitsCard extends StatelessWidget {
  const _LimitsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'What pairing allows',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              '• Exactly two devices. There is no third slot and no way to add one.\n'
              '• One-time invitations that expire and cannot be reused.\n'
              '• A six-digit code both people compare before trusting the link.\n'
              '• Revocation from Security settings, which frees the slot.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF8C93A8),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Payload preview used by the scanner and by tests.
PairingPayload? decodeScanned(String raw) => parsePairingPayload(raw);
