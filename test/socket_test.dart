import 'dart:async';

import 'package:pedantic/pedantic.dart';
import 'package:test/test.dart';

import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  const addr = 'ws://localhost:4001/socket/websocket';

  group('PhoenixSocket', () {
    test('can connect to a running Phoenix server', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect().then((_) {
        expect(socket.isConnected, isTrue);
      });
    });

    test('can connect to a running Phoenix server with params', () async {
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: {'user_id': 'this_is_a_userid'},
        ),
      );

      await socket.connect().then((_) {
        expect(socket.isConnected, isTrue);
      });
    });

    test('emits an "open" event', () async {
      final socket = PhoenixSocket(addr);

      unawaited(socket.connect());

      await for (final event in socket.openStream!) {
        expect(event, isA<PhoenixSocketOpenEvent>());
        socket.close();
        break;
      }
    });

    test('emits a "close" event after the connection was closed', () async {
      final completer = Completer();
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: {'user_id': 'this_is_a_userid'},
        ),
      );

      await socket.connect().then((_) {
        Timer(const Duration(milliseconds: 100), socket.close);
      });

      socket.closeStream!.listen((event) {
        expect(event, isA<PhoenixSocketCloseEvent>());
        completer.complete();
      });

      await completer.future;
    });

    test('reconnects automatically after a socket close', () async {
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: {'user_id': 'this_is_a_userid'},
        ),
      );

      await socket.connect();

      var i = 0;
      socket.openStream!.listen((event) async {
        if (i++ < 3) {
          await Future.delayed(const Duration(milliseconds: 50));
          socket.close(null, null, true);
        }
      });

      expect(
        socket.openStream,
        emitsInOrder([
          isA<PhoenixSocketOpenEvent>(),
          isA<PhoenixSocketOpenEvent>(),
          isA<PhoenixSocketOpenEvent>(),
        ]),
      );
    });
  });
}
