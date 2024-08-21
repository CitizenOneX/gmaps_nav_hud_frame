import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _log = Logger("Bluetooth");

class BrilliantBluetoothException implements Exception {
  final String msg;
  const BrilliantBluetoothException(this.msg);
  @override
  String toString() => 'BrilliantBluetoothException: $msg';
}

enum BrilliantConnectionState {
  connected,
  disconnected,
}

class BrilliantScannedDevice {
  BluetoothDevice device;
  int? rssi;

  BrilliantScannedDevice({
    required this.device,
    required this.rssi,
  });
}

class BrilliantDevice {
  BluetoothDevice device;
  BrilliantConnectionState state;
  int? maxStringLength;
  int? maxDataLength;

  BluetoothCharacteristic? _txChannel;
  BluetoothCharacteristic? _rxChannel;

  BrilliantDevice({
    required this.state,
    required this.device,
    this.maxStringLength,
    this.maxDataLength,
  });

  // to enable reconnect()
  String get uuid => device.remoteId.str;

  Stream<BrilliantDevice> get connectionState {
    // changed to only listen for connectionState data coming from the Frame device rather than all events from all devices as before
    return device.connectionState
        .where((event) =>
            event == BluetoothConnectionState.connected ||
            (event == BluetoothConnectionState.disconnected &&
                device.disconnectReason != null &&
                device.disconnectReason!.code != 23789258))
        .asyncMap((event) async {
      if (event == BluetoothConnectionState.connected) {
        _log.info("Connection state stream: Connected");
        try {
          return await BrilliantBluetooth._enableServices(device);
        } catch (error) {
          _log.warning("Connection state stream: Invalid due to $error");
          return Future.error(BrilliantBluetoothException(error.toString()));
        }
      }
      _log.info(
          "Connection state stream: Disconnected due to ${device.disconnectReason!.description}");
      // Note: automatic reconnection isn't suitable for all cases, so it might
      // be better to leave this up to the sdk user to specify. iOS appears to
      // use FBP's native autoconnect, so if Android behaviour would change then
      // iOS probably should as well
      // if (Platform.isAndroid) {
      //   event.device.connect(timeout: const Duration(days: 365));
      // }
      return BrilliantDevice(
        state: BrilliantConnectionState.disconnected,
        device: device,
      );
    });
  }

  // logs each string message (messages without the 0x01 first byte) and provides a stream of the utf8-decoded strings
  Stream<String> get stringResponse {
    // changed to only listen for data coming through the Frame's rx characteristic, not all attached devices as before
    return _rxChannel!.onValueReceived
        .where((event) => event[0] != 0x01)
        .map((event) {
      if (event[0] != 0x02) {
        _log.info("Received string: ${utf8.decode(event)}");
      }
      return utf8.decode(event);
    });
  }

  Stream<List<int>> get dataResponse {
    // changed to only listen for data coming through the Frame's rx characteristic, not all attached devices as before
    return _rxChannel!.onValueReceived
        .where((event) => event[0] == 0x01)
        .map((event) {
      _log.fine("Received data: ${event.sublist(1)}");
      return event.sublist(1);
    });
  }

  Future<void> disconnect() async {
    _log.info("Disconnecting");
    try {
      await device.disconnect();
    } catch (_) {}
  }

  Future<void> sendBreakSignal() async {
    _log.info("Sending break signal");
    await sendString("\x03", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> sendResetSignal() async {
    _log.info("Sending reset signal");
    await sendString("\x04", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<String?> sendString(
    String string, {
    bool awaitResponse = true,
    bool log = true,
  }) async {
    try {
      if (log) {
        _log.info("Sending string: $string");
      }

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (string.length > maxStringLength!) {
        throw ("Payload exceeds allowed length of $maxStringLength");
      }

      await _txChannel!.write(utf8.encode(string), withoutResponse: true);

      if (awaitResponse == false) {
        return null;
      }

      final response = await _rxChannel!.onValueReceived
          .timeout(const Duration(seconds: 10))
          .first;

      return utf8.decode(response);
    } catch (error) {
      _log.warning("Couldn't send string. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  Future<void> sendData(List<int> data) async {
    try {
      _log.info("Sending ${data.length} bytes of plain data");
      _log.fine(data);

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (data.length > maxDataLength!) {
        throw ("Payload exceeds allowed length of $maxDataLength");
      }

      var finalData = data.toList()..insert(0, 0x01);

      await _txChannel!.write(finalData, withoutResponse: true);
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Same as sendData but user includes the 0x01 header byte to avoid extra memory allocation
  Future<void> sendDataRaw(List<int> data) async {
    try {
      _log.info("Sending ${data.length-1} bytes of plain data");
      _log.fine(data);

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (data.length > maxDataLength!+1) {
        throw ("Payload exceeds allowed length of ${maxDataLength!+1}");
      }

      if (data[0] != 0x01) {
        throw ("Data packet missing 0x01 header");
      }

      // TODO check throughput difference using withoutResponse: false
      await _txChannel!.write(data, withoutResponse: true);
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Sends a typed message as a series of messages to Frame as chunks marked by
  /// [0x01 (dataFlag), messageFlag & 0xFF, {first packet: length(Uint16)}, payload(chunked)]
  /// until all data in the payload is sent. Payload data cannot exceed 65536 bytes in length.
  /// Can be received by a corresponding Lua function on Frame.
  Future<void> sendMessage(int messageFlag, List<int> payload) async {
    if (payload.length > 65536) {
      return Future.error(const BrilliantBluetoothException('Payload length exceeds 65536 bytes'));
    }

    int lengthMsb = payload.length >> 8;
    int lengthLsb = payload.length & 0xFF;
    int sentBytes = 0;
    bool firstPacket = true;
    int bytesRemaining = payload.length;
    int chunksize = maxDataLength! - 1;
    // the full sized packet buffer to prepare. If we are sending a full sized packet,
    // set packetToSend to point to packetBuffer. If we are sending a smaller (final) packet,
    // instead point packetToSend to an UnmodifiableListView range within packetBuffer
    List<int> packetBuffer = List.filled(maxDataLength! + 1, 0x00);
    List<int> packetToSend = packetBuffer;

    while (sentBytes < payload.length) {
      if (firstPacket) {
        firstPacket = false;

        if (bytesRemaining < chunksize - 2) {
          // first and final chunk - small payload
          packetBuffer[0] = 0x01;
          packetBuffer[1] = messageFlag & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend = UnmodifiableListView(packetBuffer.getRange(0, bytesRemaining + 4));
        }
        else if (bytesRemaining == chunksize - 2) {
          // first and final chunk - small payload, exact packet size match
          packetBuffer[0] = 0x01;
          packetBuffer[1] = messageFlag & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend = packetBuffer;
        }
        else {
          // first of many chunks
          packetBuffer[0] = 0x01;
          packetBuffer[1] = messageFlag & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(4, payload.getRange(sentBytes, sentBytes + chunksize - 2));
          sentBytes += chunksize - 2;
          packetToSend = packetBuffer;
        }
      }
      else {
        // not the first packet
        if (bytesRemaining < chunksize) {
          // final data chunk, smaller than chunksize
          packetBuffer[0] = 0x01;
          packetBuffer[1] = messageFlag & 0xFF;
          packetBuffer.setAll(2, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend = UnmodifiableListView(packetBuffer.getRange(0, bytesRemaining + 2));
        }
        else  {
          // non-final data chunk or final chunk with exact packet size match
          packetBuffer[0] = 0x01;
          packetBuffer[1] = messageFlag & 0xFF;
          packetBuffer.setAll(2, payload.getRange(sentBytes, sentBytes + chunksize));
          sentBytes += chunksize;
          packetToSend = packetBuffer;
        }
      }

      // send the chunk
      await sendDataRaw(packetToSend);

      bytesRemaining = payload.length - sentBytes;
    }
  }

  Future<void> uploadScript(String fileName, String filePath) async {
    try {
      _log.info("Uploading script: $fileName");

      String file = await rootBundle.loadString(filePath);

      file = file.replaceAll('\\', '\\\\');
      file = file.replaceAll("\n", "\\n");
      file = file.replaceAll("'", "\\'");
      file = file.replaceAll('"', '\\"');

      var resp = await sendString(
          "f=frame.file.open('$fileName', 'w');print('\x02')",
          log: false);

      if (resp != "\x02") {
        throw ("Error opening file: $resp");
      }

      int index = 0;
      int chunkSize = maxStringLength! - 22;

      while (index < file.length) {
        // Don't go over the end of the string
        if (index + chunkSize > file.length) {
          chunkSize = file.length - index;
        }

        // Don't split on an escape character
        if (file[index + chunkSize - 1] == '\\') {
          chunkSize -= 1;
        }

        String chunk = file.substring(index, index + chunkSize);

        resp = await sendString("f:write('$chunk');print('\x02')", log: false);

        if (resp != "\x02") {
          throw ("Error writing file: $resp");
        }

        index += chunkSize;
      }

      resp = await sendString("f:close();print('\x02')", log: false);

      if (resp != "\x02") {
        throw ("Error closing file: $resp");
      }
    } catch (error) {
      _log.warning("Couldn't upload script. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }
}

class BrilliantBluetooth {
  static Future<void> requestPermission() async {
    try {
      await FlutterBluePlus.startScan();
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't obtain Bluetooth permission. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Stream<BrilliantScannedDevice> scan() async* {
    try {
      _log.info("Starting to scan for devices");

      await FlutterBluePlus.startScan(
        withServices: [
          Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
          Guid('fe59'),
        ],
        // note: adding a shorter scan period to reflect
        // that it might be used for a short period at the
        // beginning of an app but not running in the background
        timeout: const Duration(seconds: 10),
        continuousUpdates: false,
        removeIfGone: null,
      );
    } catch (error) {
      _log.warning("Scanning failed. $error");
      throw BrilliantBluetoothException(error.toString());
    }

    yield* FlutterBluePlus.scanResults
        .where((results) => results.isNotEmpty)
        // TODO filter by name: "Frame"
        .map((results) {
      ScanResult nearestDevice = results[0];
      for (int i = 0; i < results.length; i++) {
        if (results[i].rssi > nearestDevice.rssi) {
          nearestDevice = results[i];
        }
      }

      _log.fine(
          "Found ${nearestDevice.device.advName} rssi: ${nearestDevice.rssi}");

      return BrilliantScannedDevice(
        device: nearestDevice.device,
        rssi: nearestDevice.rssi,
      );
    });
  }

  static Future<void> stopScan() async {
    try {
      _log.info("Stopping scan for devices");
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't stop scanning. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> connect(BrilliantScannedDevice scanned) async {
    try {
      _log.info("Connecting");

      await FlutterBluePlus.stopScan();

      await scanned.device.connect(
        autoConnect: Platform.isIOS ? true : false,
        mtu: null,
      );

      final connectionState = await scanned.device.connectionState
          .firstWhere((event) => event == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 3));

      if (connectionState == BluetoothConnectionState.connected) {
        return await _enableServices(scanned.device);
      }

      throw ("${scanned.device.disconnectReason?.description}");
    } catch (error) {
      await scanned.device.disconnect();
      _log.warning("Couldn't connect. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> reconnect(String uuid) async {
    try {
      _log.info("Will re-connect to device: $uuid once found");

      BluetoothDevice device = BluetoothDevice.fromId(uuid);

      await device.connect(
        // note: changed so that sdk users (apps) directly specify reconnect behaviour
        // otherwise there are spurious reconnects even after programmatically disconnecting
        timeout: const Duration(seconds: 5),
        autoConnect: false,
        mtu: null,
      );

      final connectionState = await device.connectionState.firstWhere((state) =>
          state == BluetoothConnectionState.connected ||
          (state == BluetoothConnectionState.disconnected &&
              device.disconnectReason != null));

      _log.info("Found reconnectable device: $uuid");

      if (connectionState == BluetoothConnectionState.connected) {
        return await _enableServices(device);
      }

      throw ("${device.disconnectReason?.description}");
    } catch (error) {
      _log.warning("Couldn't reconnect. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> _enableServices(BluetoothDevice device) async {
    if (Platform.isAndroid) {
      await device.requestMtu(512);
    }

    BrilliantDevice finalDevice = BrilliantDevice(
      device: device,
      state: BrilliantConnectionState.disconnected,
    );

    List<BluetoothService> services = await device.discoverServices();

    for (var service in services) {
      // If Frame
      if (service.serviceUuid == Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')) {
        _log.fine("Found Frame service");
        for (var characteristic in service.characteristics) {
          if (characteristic.characteristicUuid ==
              Guid('7a230002-5475-a6a4-654c-8431f6ad49c4')) {
            _log.fine("Found Frame TX characteristic");
            finalDevice._txChannel = characteristic;
          }
          if (characteristic.characteristicUuid ==
              Guid('7a230003-5475-a6a4-654c-8431f6ad49c4')) {
            _log.fine("Found Frame RX characteristic");
            finalDevice._rxChannel = characteristic;

            await characteristic.setNotifyValue(true);
            _log.fine("Enabled RX notifications");

            finalDevice.maxStringLength = device.mtuNow - 3;
            finalDevice.maxDataLength = device.mtuNow - 4;
            _log.fine("Max string length: ${finalDevice.maxStringLength}");
            _log.fine("Max data length: ${finalDevice.maxDataLength}");
          }
        }
      }
    }

    if (finalDevice._txChannel != null && finalDevice._rxChannel != null) {
      finalDevice.state = BrilliantConnectionState.connected;
      return finalDevice;
    }

    throw ("Incomplete set of services found");
  }
}