import '../util/input_stream.dart';

class RangeDecoder {
  static const int RC_SHIFT_BITS = 8;
  static const int RC_TOP_BITS = 24;
  static const int RC_TOP_VALUE = (1 << RC_TOP_BITS);
  static const int RC_BIT_MODEL_TOTAL_BITS = 11;
  static const int RC_BIT_MODEL_TOTAL = (1 << RC_BIT_MODEL_TOTAL_BITS);
  static const int RC_MOVE_BITS = 5;
  static const int DEFAULT_PROB = RC_BIT_MODEL_TOTAL ~/ 2;

  final InputStreamBase _input;
  var range = 0xffffffff;
  var code = 0;

  RangeDecoder(this._input) {
    // Load first five bytes into the range decoder.
    for (var i = 0; i < 5; i++) {
      code = (code << 8 | _input.readByte()) & 0xffffffff;
    }
  }

  // FIXME: uint16
  List<int> makeProbabilityTree(int length) {
    return List<int>.filled(length, DEFAULT_PROB);
  }

  void resetProbabilityTree(List<int> probabilities) {
    probabilities.fillRange(0, probabilities.length, DEFAULT_PROB);
  }

  int readBit(List<int> probabilities, int index) {
    _normalize();

    var p = probabilities[index];
    var bound = (range >> RC_BIT_MODEL_TOTAL_BITS) * p;
    if (code < bound) {
      range = bound;
      probabilities[index] += (RC_BIT_MODEL_TOTAL - p) >> RC_MOVE_BITS;
      return 0;
    } else {
      range -= bound;
      code -= bound;
      probabilities[index] -= p >> RC_MOVE_BITS;
      return 1;
    }
  }

  int readBittree(List<int> probabilities, int limit) {
    var symbol = 1;
    while (true) {
      var b = readBit(probabilities, symbol);
      symbol = (symbol << 1) | b;
      if (symbol >= limit) {
        return symbol;
      }
    }
  }

  int readBittreeReverse(
      List<int> probabilities, int offset, int value, int limit) {
    var symbol = 1;
    for (var i = 0; i < limit; i++) {
      var b = readBit(probabilities, offset + symbol);
      symbol = (symbol << 1) | b;
      value |= b << i;
    }

    return value;
  }

  int readDirect(int value, int limit) {
    while (true) {
      _normalize();
      range >>= 1;
      code -= range;
      value <<= 1;
      if (code & 0x80000000 != 0) {
        code += range;
      } else {
        value++;
      }
      limit--;
      if (limit <= 0) {
        return value;
      }
    }
  }

  void _normalize() {
    if (range < RC_TOP_VALUE) {
      range <<= RC_SHIFT_BITS;
      code = (code << RC_SHIFT_BITS) | _input.readByte();
    }
  }
}
