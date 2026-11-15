/// WebSocket transport used for both cloud (`wss://`) and local (`ws://`) mode.
///
/// One transport per session, deliberately: there is no automatic reconnect and
/// no outgoing queue. If the socket dies, the session is over and the user must
/// authenticate again. That is the product requirement, not an omission.
library;

import 'dart:async';
import 'dart:io';

import 'protocol.dart';

sealed class TransportEvent {
  const TransportEvent();
}

class FrameReceived extends TransportEvent {
  const FrameReceived(this.frame);

  final ServerFrame frame;
}

class TransportClosed extends TransportEvent {
  const TransportClosed(this.reason);

  final String? reason;
}

class RelayTransport {
  RelayTransport({required this.url});

  final String url;
  WebSocket? _socket;
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  bool _closed = false;

  Stream<TransportEvent> get events => _events.stream;
  bool get isConnected => _socket != null && !_closed;

  /// Opens the socket and sends the hello frame as the first message.
  Future<void> connect(Frame hello) async {
    if (_closed) throw StateError('transport already closed');
    if (url.startsWith('wss://')) {
      // dart:io validates certificates against the system trust store; there is
      // deliberately no "accept bad certificate" escape hatch.
    } else if (!url.startsWith('ws://')) {
      throw ArgumentError('relay URL must be ws:// or wss://');
    }

    final socket = await WebSocket.connect(
      url,
      compression: CompressionOptions.compressionOff,
    ).timeout(const Duration(seconds: 10));
    socket.pingInterval = const Duration(seconds: 10);
    _socket = socket;

    socket.listen(
      (data) {
        if (data is String) {
          _events.add(FrameReceived(parseServerFrame(data)));
        }
      },
      onDone: () {
        _socket = null;
        _events.add(TransportClosed(socket.closeReason));
      },
      onError: (Object error) {
        _socket = null;
        _events.add(const TransportClosed('transport_error'));
      },
      cancelOnError: true,
    );

    socket.add(hello.encode());
  }

  void send(Frame frame) {
    final socket = _socket;
    if (socket == null) throw StateError('relay is not connected');
    socket.add(frame.encode());
  }

  Future<void> close({int code = 1000, String reason = 'client_close'}) async {
    _closed = true;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(code, reason);
      } catch (_) {
        // already gone
      }
    }
    await _events.close();
  }
}
