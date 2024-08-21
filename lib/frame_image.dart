import 'dart:typed_data';

/// Corresponding parser should be called from frame_app.lua data_handler()
/// width(Uint16), height(Uint16), bpp(Uint8), numColors(Uint8), palette (Uint8 r, Uint8 g, Uint8 b)*numColors, data (length width x height x bpp/8)
List<int> makeImagePayload(int width, int height, int numColors, Uint8List paletteData, Uint8List imageData) {
  int widthMsb = width >> 8;
  int widthLsb = width & 0xFF;
  int heightMsb = height >> 8;
  int heightLsb = height & 0xFF;
  int bpp = 0;
  Uint8List packed;
  switch (numColors) {
    case <= 2:
      bpp = 1;
      packed = pack1Bit(imageData);
      break;
    case <= 4:
      bpp = 2;
      packed = pack2Bit(imageData);
      break;
    case <= 16:
      bpp = 4;
      packed = pack4Bit(imageData);
      break;
    default:
      throw Exception('Image must have 16 or fewer colors. Actual: $numColors');
  }

  // preallocate the list of bytes to send - header, palette, data
  // (packed.length already adds the extra byte if WxH is not divisible by 8)
  List<int> payload = List.filled(6 + numColors * 3 + packed.length, 0);

  // NB: palette data could be numColors=12 x 3 (RGB) bytes even if bpp is 4 (max 16 colors)
  // hence we provide both numColors and bpp here
  payload.setAll(0, [widthMsb, widthLsb, heightMsb, heightLsb, bpp, numColors]);
  payload.setAll(6, paletteData);
  payload.setAll(6 + numColors * 3, packed);

  return payload;
}


Uint8List pack1Bit(Uint8List bpp1) {
  int byteLength = (bpp1.length + 7) ~/ 8;  // Calculate the required number of bytes
  Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

  for (int i = 0; i < bpp1.length; i++) {
    int byteIndex = i ~/ 8;
    int bitIndex = i % 8;
    packed[byteIndex] |= (bpp1[i] & 0x01) << (7 - bitIndex);
  }

  return packed;
}

Uint8List pack2Bit(Uint8List bpp2) {
  int byteLength = (bpp2.length + 3) ~/ 4;  // Calculate the required number of bytes
  Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

  for (int i = 0; i < bpp2.length; i++) {
    int byteIndex = i ~/ 4;
    int bitOffset = (3 - (i % 4)) * 2;
    packed[byteIndex] |= (bpp2[i] & 0x03) << bitOffset;
  }

  return packed;
}

Uint8List pack4Bit(Uint8List bpp4) {
  int byteLength = (bpp4.length + 1) ~/ 2;  // Calculate the required number of bytes
  Uint8List packed = Uint8List(byteLength); // Create the Uint8List to hold packed bytes

  for (int i = 0; i < bpp4.length; i++) {
    int byteIndex = i ~/ 2;
    int bitOffset = (1 - (i % 2)) * 4;
    packed[byteIndex] |= (bpp4[i] & 0x0F) << bitOffset;
  }

  return packed;
}
