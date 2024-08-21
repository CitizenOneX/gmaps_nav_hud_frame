import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_notification_listener/flutter_notification_listener.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

import 'frame_helper.dart';
import 'frame_image.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  final List<NotificationEvent> _logList = [];
  ReceivePort port = ReceivePort();
  String _prevText = '';
  Uint8List _prevIcon = Uint8List(0);

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // we must use static method, to handle in background
  // prevent dart from stripping out this function on release build in Flutter 3.x
  @pragma('vm:entry-point')
  static void _callback(NotificationEvent evt) {
    _log.fine("send evt to ui: $evt");
    final SendPort? send = IsolateNameServer.lookupPortByName("_listener_");
    if (send == null) _log.severe("can't find the sender");
    send?.send(evt);
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    setState(() {
      ApplicationState.initializing;
    });

    _log.info('Initializing platform state');
    NotificationsListener.initialize(callbackHandle: _callback);

    // this can fix restart<debug> can't handle error
    IsolateNameServer.removePortNameMapping("_listener_");
    IsolateNameServer.registerPortWithName(port.sendPort, "_listener_");
    port.listen((message) => handleNotification(message));

    var isRunning = (await NotificationsListener.isRunning) ?? false;
    _log.info('Service is already running: $isRunning');

    setState(() {
      ApplicationState.ready;
    });
  }

  /// Extract the details from the notification and send to Frame
  void handleNotification(NotificationEvent event) async {
    _log.fine('onData: $event');

    // filter notifications for Maps
    if (event.packageName != null && event.packageName == "com.google.android.apps.maps") {
      setState(() {
        // TODO single latest notification, or list?
        _logList.add(event);
      });

      try {
        // send text to Frame
        String text = '${event.title}\n${event.text}\n${event.raw!["subText"]}';
        if (text != _prevText) {
          String wrappedText = FrameHelper.wrapText(text, 560, 4);
          await frame?.sendMessage(0x0a, utf8.encode(wrappedText));
          _prevText = text;
        }

        if (event.hasLargeIcon!) {
          Uint8List iconBytes = event.largeIcon!;
          _log.fine('Icon bytes: ${iconBytes.length}: $iconBytes');

          if (iconBytes != _prevIcon) {
            // TODO if the maps icons are all 2-color bitmaps, maybe we can pack them and send as an indexed file more easily than quantize()?
            final img.Image? image = img.decodeImage(iconBytes);

            // Ensure the image is loaded correctly
            if (image != null) {
              _log.severe('Image: ${image.width}x${image.height}, ${image.format}, ${image.hasAlpha}, ${image.hasPalette}, ${image.length}');
              _log.severe('Image bytes: ${image.toUint8List()}');

              // quantize the image for pack/send/display to frame
              final qImage = img.quantize(image, numberOfColors: 4, method: img.QuantizeMethod.binary, dither: img.DitherKernel.none, ditherSerpentine: false);
              Uint8List qImageBytes = qImage.toUint8List();
              _log.severe('QuantizedImage: ${qImage.width}x${qImage.height}, ${qImage.format}, ${qImage.hasAlpha}, ${qImage.hasPalette}, ${qImage.palette!.toUint8List()}, ${qImage.length}');
              _log.severe('QuantizedImage bytes: $qImageBytes');

              // send image message (header and image data) to Frame (split over several packets)
              var imagePayload = makeImagePayload(qImage.width, qImage.height, qImage.palette!.lengthInBytes ~/ 3, qImage.palette!.toUint8List(), qImageBytes);
              _log.severe('Image Payload: ${imagePayload.length} $imagePayload');

              await frame?.sendMessage(0x0d, imagePayload);
              _prevIcon = qImageBytes;
            }
          }
        }
      }
      catch (e) {
        _log.severe('Error processing notification: $e');
      }
    }
  }

  @override
  Future<void> run() async {
    _log.info("start listening");

    var hasPermission = (await NotificationsListener.hasPermission)!;
    _log.info("permission: $hasPermission");

    if (!hasPermission) {
      _log.info("no permission, so open settings");
      NotificationsListener.openPermissionSettings();
    }
    else {
      _log.info("has permission, so open settings anyway");
      // TODO seems not to update hasPermission to false after stopService
      // so force an openPermissionSettings on startListening every time
      NotificationsListener.openPermissionSettings();
    }

    var isRunning = (await NotificationsListener.isRunning)!;
    _log.info("running: $isRunning");

    if (!isRunning) {
      _log.info("not running: starting service");
      await NotificationsListener.startService(foreground: false);
    }

    setState(() {
      currentState = ApplicationState.running;
    });
  }

  @override
  Future<void> cancel() async {
    _log.info("stop listening");

    setState(() {
      currentState = ApplicationState.stopping;
    });

    bool stopped = (await NotificationsListener.stopService())!;
    _log.info("service stopped: $stopped");

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    // FIXME remove
    currentState = ApplicationState.ready;
    return MaterialApp(
      title: 'Frame Navigation HUD',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Navigation HUD'),
        ),
        body: Center(
          child: ListView.builder(
            itemCount: _logList.length,
            reverse: true,
            itemBuilder: (BuildContext context, int idx) {
              final entry = _logList[idx];
              return ListTile(
                trailing: entry.hasLargeIcon!
                    ? Image.memory(entry.largeIcon!, width: 126, height: 126)
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
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.navigation), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      )
    );
  }
}