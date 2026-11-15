/// Chat message model.
///
/// This object is never serialised to disk, never logged, and never sent to a
/// server in plaintext. It exists in a list in memory for the duration of a
/// session and is dropped when the session ends.
library;

enum MessageDirection { incoming, outgoing }

enum MessageStatus { sending, sent, delivered, failed }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.direction,
    required this.text,
    required this.at,
    this.status = MessageStatus.sending,
  });

  final String id;
  final MessageDirection direction;
  final String text;
  final DateTime at;
  MessageStatus status;

  bool get isMine => direction == MessageDirection.outgoing;

  /// Explicitly refuse accidental logging of content.
  @override
  String toString() => 'ChatMessage($id, $direction, ${text.length} chars)';
}

/// Hard cap so a long session cannot grow memory without bound. Dropping the
/// oldest entries is correct here: they are not persisted anywhere either.
const int kMaxMessagesInMemory = 200;
