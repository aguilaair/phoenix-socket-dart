import 'dart:async';
import 'dart:core';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pedantic/pedantic.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'events.dart';
import 'exceptions.dart';
import 'message.dart';
import 'push.dart';
import 'socket_options.dart';

part '_stream_router.dart';

/// State of a [PhoenixSocket].
enum SocketState {
  /// The connection is closed
  closed,

  /// The connection is closing
  closing,

  /// The connection is opening
  connecting,

  /// The connection is established
  connected,
}

final Logger _logger = Logger('phoenix_socket.socket');

final Random _random = Random();

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets.
class PhoenixSocket {
  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixSocket(
    /// The URL of the Phoenix server.
    String endpoint, {

    /// The options used when initiating and maintaining the
    /// websocket connection.
    PhoenixSocketOptions? socketOptions,
  }) : _endpoint = endpoint {
    _options = socketOptions ?? PhoenixSocketOptions();

    _reconnects = _options.reconnectDelays;

    _messageStream =
        _receiveStreamController.stream.map(_options.serializer.decode);

    _openStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketOpenEvent)
        .cast<PhoenixSocketOpenEvent>();

    _closeStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketCloseEvent)
        .cast<PhoenixSocketCloseEvent>();

    _errorStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketErrorEvent)
        .cast<PhoenixSocketErrorEvent>();

    _subscriptions = [
      _messageStream!.listen(_onMessage),
      _openStream!.listen((_) => _startHeartbeat()),
      _closeStream!.listen((_) => _cancelHeartbeat())
    ];
  }

  final Map<String?, Completer<Message>> _pendingMessages = {};
  final Map<String?, Stream<Message>> _topicStreams = {};

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();
  final StreamController<String> _receiveStreamController =
      StreamController.broadcast();
  final String _endpoint;
  final StreamController<Message> _topicMessages = StreamController();

  Uri? _mountPoint;
  SocketState? _socketState;

  WebSocketChannel? _ws;

  Stream<PhoenixSocketOpenEvent>? _openStream;
  Stream<PhoenixSocketCloseEvent>? _closeStream;
  Stream<PhoenixSocketErrorEvent>? _errorStream;
  Stream<Message>? _messageStream;
  _StreamRouter<Message>? _router;

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent>? get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent>? get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent>? get errorStream => _errorStream;

  /// Stream of all [Message] instances received.
  Stream<Message>? get messageStream => _messageStream;

  /// Reconnection durations, increasing in length.
  late List<Duration> _reconnects;

  List<StreamSubscription> _subscriptions = [];

  int _ref = 0;
  String? _nextHeartbeatRef;
  Timer? _heartbeatTimeout;

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  String get nextRef => '${_ref++}';

  int _reconnectAttempts = 0;

  bool _shouldReconnect = true;
  bool _reconnecting = false;

  /// [Map] of topic names to [PhoenixChannel] instances being
  /// maintained and tracked by the socket.
  Map<String?, PhoenixChannel> channels = {};

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  bool _disposed = false;

  _StreamRouter<Message> get _streamRouter =>
      _router ??= _StreamRouter<Message>(_topicMessages.stream);

  /// A stream yielding [Message] instances for a given topic.
  ///
  /// The [PhoenixChannel] for this topic may not be open yet, it'll still
  /// eventually yield messages when the channel is open and it receives
  /// messages.
  Stream<Message> streamForTopic(String? topic) => _topicStreams.putIfAbsent(
      topic, () => _streamRouter.route((event) => event.topic == topic));

  /// The string URL of the remote Phoenix server.
  String get endpoint => _endpoint;

  /// The [Uri] containing all the parameters and options for the
  /// remote connection to occue.
  Uri? get mountPoint => _mountPoint;

  /// Whether the underlying socket is connected of not.
  bool get isConnected =>
      _ws is WebSocketChannel && _socketState == SocketState.connected;

  /// Attempts to make a WebSocket connection to the Phoenix backend.
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by retryAfterIntervalMS
  Future<PhoenixSocket?> connect() async {
    if (_ws != null) {
      _logger.warning(
          'Calling connect() on already connected or connecting socket.');
      return this;
    }

    _shouldReconnect = true;

    if (_disposed) {
      throw StateError('PhoenixSocket cannot connect after being disposed.');
    }

    _mountPoint = await _buildMountPoint(_endpoint, _options);
    _logger.finest(() => 'Attempting to connect to $_mountPoint');

    final completer = Completer<PhoenixSocket?>();

    try {
      _ws = WebSocketChannel.connect(_mountPoint!);
      _ws!.stream
          .where(_shouldPipeMessage)
          .listen(_onSocketData, cancelOnError: true)
            ..onError(_onSocketError)
            ..onDone(_onSocketClosed);
    } catch (error, stacktrace) {
      _onSocketError(error, stacktrace);
    }

    _socketState = SocketState.connecting;

    try {
      _socketState = SocketState.connected;
      _logger.finest('Waiting for initial heartbeat roundtrip');
      if (await _sendHeartbeat(_heartbeatTimeout)) {
        _stateStreamController.add(PhoenixSocketOpenEvent());
        _logger.info('Socket open');
        completer.complete(this);
      } else {
        throw PhoenixException();
      }
    } on PhoenixException catch (_) {
      final durationIdx = _reconnectAttempts++;
      _ws = null;
      _socketState = SocketState.closed;

      Duration duration;
      if (durationIdx >= _reconnects.length) {
        duration = _reconnects.last;
      } else {
        duration = _reconnects[durationIdx];
      }

      // Some random number to prevent many clients from retrying to
      // connect at exactly the same time.
      duration += Duration(milliseconds: _random.nextInt(1000));

      completer.complete(_delayedReconnect(duration));
    }

    return completer.future;
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    reconnect = false,
  ]) {
    _shouldReconnect = reconnect;
    if (isConnected) {
      _socketState = SocketState.closing;
      _ws!.sink.close(code, reason);
    } else if (!_shouldReconnect) {
      dispose();
    }
  }

  /// Dispose of the socket.
  ///
  /// Don't forget to call this at the end of the lifetime of
  /// a socket.
  void dispose() {
    _shouldReconnect = false;
    if (_disposed) return;

    _disposed = true;
    _ws?.sink.close();

    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    _pendingMessages.clear();

    final disposedChannels = channels.values.toList();
    channels.clear();

    for (final channel in disposedChannels) {
      channel.close();
    }

    _topicMessages.close();
    _topicStreams.clear();

    _stateStreamController.close();
    _receiveStreamController.close();
  }

  /// Wait for an expected message to arrive.
  ///
  /// Used internally when expecting a message like a heartbeat
  /// reply, a join reply, etc. If you need to wait for the
  /// reply of message you sent on a channel, you would usually
  /// use wait the returned [Push.future].
  Future<Message> waitForMessage(Message message) {
    if (_pendingMessages.containsKey(message.ref)) {
      return _pendingMessages[message.ref]!.future;
    }
    return Future.error(
      ArgumentError(
        "Message hasn't been sent using this socket.",
      ),
    );
  }

  /// Send a channel on the socket.
  ///
  /// Used internall to send prepared message. If you need to send
  /// a message on a channel, you would usually use [PhoenixChannel.push]
  /// instead.
  Future<Message> sendMessage(Message message) {
    if (_ws?.sink is! WebSocketSink) {
      return Future.error(PhoenixException(
        socketClosed: PhoenixSocketCloseEvent(),
      ));
    }
    _ws!.sink.add(_options.serializer.encode(message));
    _pendingMessages[message.ref] = Completer<Message>();
    return _pendingMessages[message.ref]!.future;
  }

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    required String topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  }) {
    PhoenixChannel? channel;
    if (channels.isNotEmpty) {
      final foundChannels =
          channels.entries.where((element) => element.value.topic == topic);
      channel = foundChannels.isNotEmpty ? foundChannels.first.value : null;
    }

    if (channel is! PhoenixChannel) {
      channel = PhoenixChannel.fromSocket(
        this,
        topic: topic,
        parameters: parameters,
        timeout: timeout ?? defaultTimeout,
      );

      channels[channel.reference] = channel;
      _logger.finer(() => 'Adding channel ${channel!.topic}');
    } else {
      _logger.finer(() => 'Reusing existing channel ${channel!.topic}');
    }
    return channel;
  }

  /// Stop managing and tracking a channel on this phoenix
  /// socket.
  ///
  /// Used internally by PhoenixChannel to remove itself after
  /// leaving the channel.
  void removeChannel(PhoenixChannel channel) {
    _logger.finer(() => 'Removing channel ${channel.topic}');
    if (channels.remove(channel.reference) is PhoenixChannel) {
      _topicStreams.remove(channel.topic);
    }
  }

  bool _shouldPipeMessage(dynamic event) {
    if (event is WebSocketChannelException) {
      return true;
    } else if (_socketState != SocketState.closed) {
      return true;
    } else {
      _logger.warning(
        'Message from socket dropped because PhoenixSocket is closed',
        '  $event',
      );
      return false;
    }
  }

  static Future<Uri> _buildMountPoint(
      String endpoint, PhoenixSocketOptions options) async {
    var decodedUri = Uri.parse(endpoint);
    final params = await options.getParams();
    if (params != null) {
      final queryParams = decodedUri.queryParameters.entries.toList()
        ..addAll(params.entries.toList());

      decodedUri =
          decodedUri.replace(queryParameters: Map.fromEntries(queryParams));
    }
    return decodedUri;
  }

  void _startHeartbeat() {
    _reconnectAttempts = 0;
    _heartbeatTimeout ??= Timer.periodic(
      _options.heartbeat,
      _sendHeartbeat,
    );
  }

  void _cancelHeartbeat() {
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
  }

  Future<bool> _sendHeartbeat(Timer? timer) async {
    if (!isConnected) return false;
    if (_nextHeartbeatRef != null) {
      _nextHeartbeatRef = null;
      unawaited(_ws!.sink.close(normalClosure, 'heartbeat timeout'));
      return false;
    }
    try {
      await sendMessage(_heartbeatMessage());
      _logger.fine('[phoenix_socket] Heartbeat completed');
      return true;
    } on PhoenixException catch (err, stacktrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed with error',
        err,
        stacktrace,
      );
      return false;
    } on WebSocketChannelException catch (err, stacktrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed with error',
        err,
        stacktrace,
      );
      _triggerChannelExceptions(PhoenixException(
        socketError: PhoenixSocketErrorEvent(
          error: err,
          stacktrace: stacktrace,
        ),
      ));
      return false;
    }
  }

  void _triggerChannelExceptions(PhoenixException exception) {
    _logger.fine(
      () => 'Trigger channel exceptions on ${channels.length} channels',
    );
    for (final channel in channels.values) {
      _logger.finer(
        () => 'Trigger channel exceptions on ${channel.topic}',
      );
      channel.triggerError(exception);
    }
  }

  Message _heartbeatMessage() => Message.heartbeat(_nextHeartbeatRef = nextRef);

  void _onMessage(Message message) {
    if (_nextHeartbeatRef == message.ref) {
      _nextHeartbeatRef = null;
    }

    if (_pendingMessages.containsKey(message.ref)) {
      final completer = _pendingMessages[message.ref]!;
      _pendingMessages.remove(message.ref);
      completer.complete(message);
    }

    if (message.topic != null && message.topic!.isNotEmpty) {
      _topicMessages.add(message);
    }
  }

  void _onSocketData(message) {
    if (message is String) {
      if (_receiveStreamController is StreamController &&
          !_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    } else {
      throw ArgumentError('Received a non-string');
    }
  }

  void _onSocketError(dynamic error, dynamic stacktrace) {
    if (_socketState == SocketState.closing ||
        _socketState == SocketState.closed) {
      return;
    }
    final socketError = PhoenixSocketErrorEvent(
      error: error,
      stacktrace: stacktrace,
    );

    if (_stateStreamController is StreamController &&
        !_stateStreamController.isClosed) {
      _stateStreamController.add(socketError);
    }

    for (final completer in _pendingMessages.values) {
      completer.completeError(error, stacktrace);
    }

    _logger.severe('Error on socket', error, stacktrace);
    _triggerChannelExceptions(PhoenixException(socketError: socketError));
    _pendingMessages.clear();

    _onSocketClosed();
  }

  void _onSocketClosed() {
    if (_shouldReconnect) {
      _delayedReconnect();
    }

    if (_socketState == SocketState.closed) {
      return;
    }

    final ev = PhoenixSocketCloseEvent(
      reason: _ws?.closeReason ?? 'WebSocket could not establish a connection',
      code: _ws?.closeCode,
    );
    final exc = PhoenixException(socketClosed: ev);
    _ws = null;

    if (_stateStreamController is StreamController &&
        !_stateStreamController.isClosed) {
      _stateStreamController.add(ev);
    }

    if (_socketState == SocketState.closing) {
      if (!_shouldReconnect) {
        dispose();
      }
      return;
    } else {
      _logger.info(
        'Socket closed with reason ${ev.reason} and code ${ev.code}',
      );
      _triggerChannelExceptions(exc);
    }
    _socketState = SocketState.closed;

    for (final completer in _pendingMessages.values) {
      completer.completeError(exc);
    }
    _pendingMessages.clear();
  }

  Future<PhoenixSocket?> _delayedReconnect([Duration? delay]) async {
    if (_reconnecting) return null;

    _reconnecting = true;
    await Future.delayed(delay ?? _options.reconnectDelays.first);

    if (!_disposed) {
      _reconnecting = false;
      return connect();
    }

    return null;
  }
}
