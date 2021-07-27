import '../util/input_stream.dart';

const int RC_BIT_MODEL_TOTAL_BITS = 11;
const int RC_BIT_MODEL_TOTAL = (1 << RC_BIT_MODEL_TOTAL_BITS);
const int DEFAULT_PROB = RC_BIT_MODEL_TOTAL ~/ 2;

class RangeDecoderProbabilities {
  // FIXME: uint16
  final List<int> probabilities;

  RangeDecoderProbabilities(int length)
      : probabilities = List<int>.filled(length, DEFAULT_PROB);

  void reset() {
    probabilities.fillRange(0, probabilities.length, DEFAULT_PROB);
  }
}

class RangeDecoder {
  static const int RC_SHIFT_BITS = 8;
  static const int RC_TOP_BITS = 24;
  static const int RC_TOP_VALUE = (1 << RC_TOP_BITS);
  static const int RC_MOVE_BITS = 5;

  final InputStreamBase _input;
  var range = 0xffffffff;
  var code = 0;

  RangeDecoder(this._input) {
    // Load first five bytes into the range decoder.
    for (var i = 0; i < 5; i++) {
      code = (code << 8 | _input.readByte()) & 0xffffffff;
    }
  }

  int readBit(RangeDecoderProbabilities probabilities, int index) {
    _normalize();

    var p = probabilities.probabilities[index];
    var bound = (range >> RC_BIT_MODEL_TOTAL_BITS) * p;
    if (code < bound) {
      range = bound;
      probabilities.probabilities[index] +=
          (RC_BIT_MODEL_TOTAL - p) >> RC_MOVE_BITS;
      return 0;
    } else {
      range -= bound;
      code -= bound;
      probabilities.probabilities[index] -= p >> RC_MOVE_BITS;
      return 1;
    }
  }

  int readBittree(RangeDecoderProbabilities probabilities, int count) {
    var symbol = 0;
    var x = 1; // FIXME: Why is this here?
    for (var i = 0; i < count; i++) {
      var b = readBit(probabilities, x | symbol);
      symbol = (symbol << 1) | b;
      x <<= 1;
    }

    return symbol;
  }

  int readBittreeReverse(RangeDecoderProbabilities probabilities, int count) {
    var symbol = 1;
    var value = 0;
    for (var i = 0; i < count; i++) {
      var b = readBit(probabilities, symbol);
      symbol = (symbol << 1) | b;
      value |= b << i;
    }

    return value;
  }

  // Read [count] bits directly from the decoder.
  int readDirect(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      _normalize();
      range >>= 1;
      code -= range;
      value <<= 1;
      if (code & 0x80000000 != 0) {
        code += range;
      } else {
        value++;
      }
    }

    return value;
  }

  void _normalize() {
    if (range < RC_TOP_VALUE) {
      range <<= RC_SHIFT_BITS;
      code = (code << RC_SHIFT_BITS) | _input.readByte();
    }
  }
}
