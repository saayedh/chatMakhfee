/// QR pairing scanner.
///
/// The camera is used only while this screen is open. It accepts a single
/// SecretPlay payload, then stops scanning so a stray QR cannot re-pair.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../storage/prefs.dart';
import 'pairing_service.dart';
import 'protocol.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        raw = value;
        break;
      }
    }
    if (raw == null) return;

    final payload = parsePairingPayload(raw);
    if (payload == null || payload.isExpired) {
      setState(
        () =>
            _error = 'That is not a valid SecretPlay code, or it has expired.',
      );
      return;
    }
    _handled = true;
    setState(() {
      _error = null;
      _status = 'Redeeming invitation…';
    });
    await _controller.stop();

    try {
      final identity = await ref.read(identityProvider.future);
      final service = ref.read(pairingServiceProvider);
      final mode = ref.read(networkModeProvider);

      if (payload.isLocal) {
        final credentials = await service.joinLocal(
          payload: payload,
          identity: identity,
        );
        await ref.read(prefsProvider).setNetworkMode(NetworkMode.local);
        ref.read(networkModeProvider.notifier).select(NetworkMode.local);
        setState(
          () =>
              _status = 'Paired as ${credentials.role}. Open chat to connect.',
        );
      } else {
        // wss://host/v1/ws -> https://host
        final uri = Uri.parse(payload.wsUrl);
        final base = 'https://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        final credentials = await service.joinCloud(
          cloudBaseUrl: base,
          payload: payload,
          identity: identity,
        );
        await ref.read(prefsProvider).setNetworkMode(NetworkMode.cloud);
        ref.read(networkModeProvider.notifier).select(NetworkMode.cloud);
        setState(
          () =>
              _status = 'Paired as ${credentials.role}. Open chat to connect.',
        );
      }
    } on PairingException catch (error) {
      _handled = false;
      setState(() {
        _status = null;
        _error = error.message;
      });
      await _controller.start();
    } catch (_) {
      _handled = false;
      setState(() {
        _status = null;
        _error = 'Pairing failed. Check the code and try again.';
      });
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Scan pairing code')),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Camera unavailable (${error.errorCode.name}). '
                          'Grant camera permission to scan, or use the laptop console QR.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFF8C93A8)),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: SpColors.privateAccent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              color: SpColors.privateSurface,
              child: Column(
                children: [
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: SpColors.coral,
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Point the camera at the QR shown by the other device or the laptop. '
                    'The code is single-use and expires.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Color(0xFF6C7488)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small helper so the QR payload type is part of this screen's contract.
PairingPayload? decodePayload(String raw) => parsePairingPayload(raw);
