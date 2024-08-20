import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_notification_listener/flutter_notification_listener.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const NotificationsLog(),
      theme: ThemeData.dark(),
    );
  }
}

class NotificationsLog extends StatefulWidget {
  const NotificationsLog({super.key});

  @override
  State<NotificationsLog> createState() => _NotificationsLogState();
}

class _NotificationsLogState extends State<NotificationsLog> {
  final List<NotificationEvent> _log = [];
  bool started = false;
  bool _loading = false;

  ReceivePort port = ReceivePort();

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // we must use static method, to handle in background
  @pragma('vm:entry-point') // prevent dart from stripping out this function on release build in Flutter 3.x
  static void _callback(NotificationEvent evt) {
    print("send evt to ui: $evt");
    final SendPort? send = IsolateNameServer.lookupPortByName("_listener_");
    if (send == null) print("can't find the sender");
    send?.send(evt);
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    NotificationsListener.initialize(callbackHandle: _callback);

    // this can fix restart<debug> can't handle error
    IsolateNameServer.removePortNameMapping("_listener_");
    IsolateNameServer.registerPortWithName(port.sendPort, "_listener_");
    port.listen((message) => onData(message));

    // don't use the default receivePort
    // NotificationsListener.receivePort.listen((evt) => onData(evt));

    var isRunning = (await NotificationsListener.isRunning) ?? false;
    print("""Service is ${!isRunning ? "not " : ""}already running""");

    setState(() {
      started = isRunning;
    });
  }

  void onData(NotificationEvent event) {
    print(event.toString());

    if (event.packageName != null && event.packageName == "com.google.android.apps.maps") {
      setState(() {
        _log.add(event);
      });
    }
  }

  void startListening() async {
    print("start listening");
    setState(() {
      _loading = true;
    });

    var hasPermission = (await NotificationsListener.hasPermission) ?? false;

    if (!hasPermission) {
      print("no permission, so open settings");
      NotificationsListener.openPermissionSettings();
      setState(() {
        _loading = false;
      });
      return;
    }
    else {
      print("permission: $hasPermission");
      // TODO seems not to update hasPermission to false after stopService
      // so force an openPermissionSettings on startListening every time
      NotificationsListener.openPermissionSettings();
    }

    var isRunning = (await NotificationsListener.isRunning) ?? false;

    if (!isRunning) {
      await NotificationsListener.startService(foreground: false);
    }

    setState(() {
      started = true;
      _loading = false;
    });
  }

  void stopListening() async {
    print("stop listening");

    setState(() {
      _loading = true;
    });

    await NotificationsListener.stopService();

    setState(() {
      started = false;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Frame Navigation HUD'),
      ),
      body: Center(
        child: ListView.builder(
          itemCount: _log.length,
          reverse: true,
          itemBuilder: (BuildContext context, int idx) {
            final entry = _log[idx];
            return ListTile(
              trailing: entry.hasLargeIcon!
                  ? Image.memory(entry.largeIcon!, width: 80, height: 80)
                  : Text(entry.packageName.toString().split('.').last),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title ?? "<<no title>>",
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
                  Text(entry.text ?? "<<no text>>",
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
                  Text(entry.raw!["subText"] ?? "<<no subText>>",
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
                  Text(entry.createAt.toString().substring(0, 19),
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ));
          })),
      floatingActionButton: FloatingActionButton(
        onPressed: started ? stopListening : startListening,
        child: _loading
            ? const Icon(Icons.close)
            : (started ? const Icon(Icons.stop) : const Icon(Icons.play_arrow)),
      ),
    );
  }
}