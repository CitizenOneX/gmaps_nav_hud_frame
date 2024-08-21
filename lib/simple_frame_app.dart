import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'brilliant_bluetooth.dart';

/// basic State Machine for the app; mostly for bluetooth lifecycle,
/// all app activity expected to take place during "running" state
enum ApplicationState {
  initializing,
  disconnected,
  scanning,
  connecting,
  connected,
  ready,
  running,
  stopping,
  disconnecting,
}

final _log = Logger("SFA");

mixin SimpleFrameAppState<T extends StatefulWidget> on State<T> {
  // Frame to Phone flags
  static const batteryStatusFlag = 0x0c;

  ApplicationState currentState = ApplicationState.disconnected;
  int? _batt;

  // Use BrilliantBluetooth for communications with Frame
  BrilliantDevice? frame;
  StreamSubscription<BrilliantScannedDevice>? _scanStream;
  StreamSubscription<BrilliantDevice>? _deviceStateSubs;
  StreamSubscription<List<int>>? _rxAppData;
  StreamSubscription<String>? _rxStdOut;

  Future<void> scanForFrame() async {
    currentState = ApplicationState.scanning;
    if (mounted) setState(() {});

    await BrilliantBluetooth.requestPermission();

    await _scanStream?.cancel();
    _scanStream = BrilliantBluetooth.scan()
      .timeout(const Duration(seconds: 5), onTimeout: (sink) {
        // Scan timeouts can occur without having found a Frame, but also
        // after the Frame is found and being connected to, even though
        // the first step after finding the Frame is to stop the scan.
        // In those cases we don't want to change the application state back
        // to disconnected
        switch (currentState) {
          case ApplicationState.scanning:
            _log.fine('Scan timed out after 5 seconds');
            currentState = ApplicationState.disconnected;
            if (mounted) setState(() {});
            break;
          case ApplicationState.connecting:
            // found a device and started connecting, just let it play out
            break;
          case ApplicationState.connected:
          case ApplicationState.ready:
          case ApplicationState.running:
            // already connected, nothing to do
            break;
          default:
            _log.fine('Unexpected state on scan timeout: $currentState');
            if (mounted) setState(() {});
        }
      })
      .listen((device) {
        _log.fine('Frame found, connecting');
        currentState = ApplicationState.connecting;
        if (mounted) setState(() {});

        connectToScannedFrame(device);
      });
  }

  Future<void> connectToScannedFrame(BrilliantScannedDevice device) async {
    try {
      _log.fine('connecting to scanned device: $device');
      frame = await BrilliantBluetooth.connect(device);
      _log.fine('device connected: ${frame!.device.remoteId}');

      // subscribe to connection state for the device to detect disconnections
      // so we can transition the app to a disconnected state
      await _refreshDeviceStateSubs();

      // refresh subscriptions to String rx and Data rx
      _refreshRxSubs();

      try {
        // terminate the main.lua (if currently running) so we can run our lua code
        // TODO looks like if the signal comes too early after connection, it isn't registered
        await Future.delayed(const Duration(milliseconds: 500));
        await frame!.sendBreakSignal();

        // Frame is ready to go!
        currentState = ApplicationState.connected;
        if (mounted) setState(() {});

      } catch (e) {
        currentState = ApplicationState.disconnected;
        _log.fine('Error while sending break signal: $e');
        if (mounted) setState(() {});

        disconnectFrame();
      }
    } catch (e) {
      currentState = ApplicationState.disconnected;
      _log.fine('Error while connecting and/or discovering services: $e');
      if (mounted) setState(() {});
    }
  }

  Future<void> reconnectFrame() async {
    if (frame != null) {
      try {
        _log.fine('reconnecting to existing device: $frame');
        // TODO get the BrilliantDevice return value from the reconnect call?
        // TODO am I getting duplicate devices/subscriptions?
        // Rather than fromUuid(), can I just call connectedDevice.device.connect() myself?
        await BrilliantBluetooth.reconnect(frame!.uuid);
        _log.fine('device connected: $frame');

        // subscribe to connection state for the device to detect disconnections
        // and transition the app to a disconnected state
        await _refreshDeviceStateSubs();

        // refresh subscriptions to String rx and Data rx
        _refreshRxSubs();

        try {
          // terminate the main.lua (if currently running) so we can run our lua code
          // TODO looks like if the signal comes too early after connection, it isn't registered
          await Future.delayed(const Duration(milliseconds: 500));
          await frame!.sendBreakSignal();

          // Frame is ready to go!
          currentState = ApplicationState.connected;
          if (mounted) setState(() {});

        } catch (e) {
          currentState = ApplicationState.disconnected;
          _log.fine('Error while sending break signal: $e');
          if (mounted) setState(() {});

        disconnectFrame();
        }
      } catch (e) {
        currentState = ApplicationState.disconnected;
        _log.fine('Error while connecting and/or discovering services: $e');
        if (mounted) setState(() {});
      }
    }
    else {
      currentState = ApplicationState.disconnected;
      _log.fine('Current device is null, reconnection not possible');
      if (mounted) setState(() {});
    }
  }

  Future<void> scanOrReconnectFrame() async {
    if (frame != null) {
      return reconnectFrame();
    }
    else {
      return scanForFrame();
    }
  }

  Future<void> disconnectFrame() async {
    if (frame != null) {
      try {
        _log.fine('Disconnecting from Frame');
        // break first in case it's sleeping - otherwise the reset won't work
        await frame!.sendBreakSignal();
        _log.fine('Break signal sent');
        // TODO the break signal needs some more time to be processed before we can reliably send the reset signal, by the looks of it
        await Future.delayed(const Duration(milliseconds: 500));

        // cancel the stdout and data subscriptions
        _rxStdOut?.cancel();
        _log.fine('StdOut subscription canceled');
        _rxAppData?.cancel();
        _log.fine('AppData subscription canceled');

        // try to reset device back to running main.lua
        await frame!.sendResetSignal();
        _log.fine('Reset signal sent');
        // TODO the reset signal doesn't seem to be processed in time if we disconnect immediately, so we introduce a delay here to give it more time
        // The sdk's sendResetSignal actually already adds 100ms delay
        // perhaps it's not quite enough.
        await Future.delayed(const Duration(milliseconds: 500));

      } catch (e) {
          _log.fine('Error while sending reset signal: $e');
      }

      try{
          // try to disconnect cleanly if the device allows
          await frame!.disconnect();
      } catch (e) {
          _log.fine('Error while calling disconnect(): $e');
      }
    }
    else {
      _log.fine('Current device is null, disconnection not possible');
    }

    _batt = null;
    currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  Future<void> _refreshDeviceStateSubs() async {
    await _deviceStateSubs?.cancel();
    _deviceStateSubs = frame!.connectionState.listen((bd) {
      _log.fine('Frame connection state change: ${bd.state.name}');
      if (bd.state == BrilliantConnectionState.disconnected) {
        currentState = ApplicationState.disconnected;
        _log.fine('Frame disconnected');
        if (mounted) setState(() {});
      }
    });
  }

  void _refreshRxSubs() {
    _rxAppData?.cancel();
    _rxAppData = frame!.dataResponse.listen((data) {
      if (data.length > 1) {
        // at this stage simple frame app only handles battery level message 0x0c
        // let any other application-specific message be handled by the app when
        // they listen on dataResponse
        if (data[0] == batteryStatusFlag) {
          _batt = data[1];
          if (mounted) setState(() {});
        }
      }
    });

    // subscribe one listener to the stdout stream
    _rxStdOut?.cancel();
    _rxStdOut = frame!.stringResponse.listen((data) {});
  }

  Widget getBatteryWidget() {
    if (_batt == null) return Container();

    IconData i;
    if (_batt! > 87.5) {
      i = Icons.battery_full;
    }
    else if (_batt! > 75) {
      i = Icons.battery_6_bar;
    }
    else if (_batt! > 62.5) {
      i = Icons.battery_5_bar;
    }
    else if (_batt! > 50) {
      i = Icons.battery_4_bar;
    }
    else if (_batt! > 45) {
      i = Icons.battery_3_bar;
    }
    else if (_batt! > 25) {
      i = Icons.battery_2_bar;
    }
    else if (_batt! > 12.5) {
      i = Icons.battery_1_bar;
    }
    else {
      i = Icons.battery_0_bar;
    }

    return Row(children: [Text('$_batt%'), Icon(i, size: 16,)]);
  }

  List<Widget> getFooterButtonsWidget() {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;

      case ApplicationState.initializing:
      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.running:
      case ApplicationState.stopping:
      case ApplicationState.disconnecting:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;

      case ApplicationState.connected:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(TextButton(onPressed: startApplication, child: const Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Disconnect')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(TextButton(onPressed: stopApplication, child: const Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;
    }
    return pfb;
  }

    FloatingActionButton? getFloatingActionButtonWidget(Icon ready, Icon running) {
    return currentState == ApplicationState.ready ?
          FloatingActionButton(onPressed: run, child: ready) :
        currentState == ApplicationState.running ?
        FloatingActionButton(onPressed: cancel, child: running) : null;
  }

  /// the SimpleFrameApp subclass can override with application-specific code if necessary
  Future<void> startApplication() async {
    // try to get the Frame into a known state by making sure there's no main loop running
    frame!.sendBreakSignal();
    await Future.delayed(const Duration(milliseconds: 500));

    // only if there is a frame_app.lua companion app
    // TODO could load minified frame_app if one exists?
    bool hasFrameApp = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets().contains('assets/frame_app.lua');
    if (hasFrameApp) {
      // send our frame_app to the Frame
      await frame!.uploadScript('frame_app.lua', 'assets/frame_app.lua');
      await Future.delayed(const Duration(milliseconds: 500));

      // kick off the main application loop
      await frame!.sendString('require("frame_app")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  /// the SimpleFrameApp subclass can override with application-specific code if necessary
  Future<void> stopApplication() async {
    // send a break to stop the Lua app loop on Frame
    await frame!.sendBreakSignal();
    await Future.delayed(const Duration(milliseconds: 500));

    // only if there is a frame_app.lua companion app
    bool hasFrameApp = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets().contains('assets/frame_app.lua');
    if (hasFrameApp) {
      // clean up by deregistering any handler and deleting any prior script
      await frame!.sendString('frame.bluetooth.receive_callback(nil);frame.file.remove("frame_app.lua");print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
    }

    currentState = ApplicationState.connected;
    if (mounted) setState(() {});
  }


  /// the SimpleFrameApp subclass implements application-specific code
  Future<void> run();

  /// the SimpleFrameApp subclass implements application-specific code
  Future<void> cancel();
}
