import '../util/input_stream.dart';

enum LzmaState {
  Lit_Lit,
  Match_Lit_Lit,
  Rep_Lit_Lit,
  ShortRep_Lit_Lit,
  Match_Lit,
  Rep_Lit,
  ShortRep_Lit,
  Lit_Match,
  Lit_LongRep,
  Lit_ShortRep,
  NonLit_Match,
  NonLit_Rep
}

const int RC_SHIFT_BITS = 8;
const int RC_TOP_BITS = 24;
const int RC_TOP_VALUE = (1 << RC_TOP_BITS);
const int RC_BIT_MODEL_TOTAL_BITS = 11;
const int RC_BIT_MODEL_TOTAL = (1 << RC_BIT_MODEL_TOTAL_BITS);
const int RC_MOVE_BITS = 5;

const int LITERAL_CODER_SIZE = 0x300;
const int LITERAL_CODERS_MAX = (1 << 4);

class LzmaDecoder {
  late final RangeDecoder input;
  final int uncompressedLength;

  final int literalContextBits;
  final int literalPositionStateBits;
  final int positionStateBits;

  late final int literalPositionStateMask;

  late final List<List<int>> is_match;
  late final List<int> is_rep;
  late final List<int> literal;

  var state = LzmaState.Lit_Lit;

  LzmaDecoder(
      {required InputStreamBase input,
      required this.uncompressedLength,
      required this.literalContextBits,
      required this.literalPositionStateBits,
      required this.positionStateBits}) {
    this.input = RangeDecoder(input);

    literalPositionStateMask = (1 << literalPositionStateBits) - 1;

    is_match = <List<int>>[];
    for (var i = 0; i < LzmaState.values.length; i++) {
      is_match.add(List<int>.filled(16, RC_BIT_MODEL_TOTAL ~/ 2));
    }
    is_rep = List<int>.filled(16, RC_BIT_MODEL_TOTAL ~/ 2);
  }

  List<int> decode() {
    return List<int>.filled(uncompressedLength, 0);

    while (true) {
      // 0xxxxxxxx    - LIT
      // 10           - MATCH
      //   0xxx         - length 2-9
      //   10xxx        - length 10-17
      //   11xxxxxxxx   - length 18-273
      // 1100         - SHORTREP
      var posState = 0; // FIXME
      if (input.readBit(is_match[state.index], posState) == 0) {
        //var prev_byte = 0;//dict_get(&s->dict, 0);
        //var low = prev_byte >> (8 - literalContextBits);
        //var high = (0/*s->dict.pos*/ & literalPositionStateMask) << literalContextBits;
        //var probs = literal[low + high];

        var byte = input.readByte(); //input.readBittree([], 0x100) & 0xff;
        print('LIT ' + byte.toRadixString(16).padLeft(2, '0'));
      } else if (input.readBit(is_rep, state.index) == 0) {
        var len = input.readLength([], 0);
        var dist = -1;
        print('MATCH $len $dist');
      } else if (input.readBit([], 0) == 0) {
        if (input.readBit([], 0) == 0) {
          print('SHORTREP');
        } else {
          var len = input.readLength([], 0);
          print('LONGREP[0] $len');
        }
      } else if (input.readBit([], 0) == 0) {
        var len = input.readLength([], 0);
        print('LONGREP[1] $len');
      } else if (input.readBit([], 0) == 0) {
        var len = input.readLength([], 0);
        print('LONGREP[2] $len');
      } else {
        var len = input.readLength([], 0);
        print('LONGREP[3] $len');
      }
    }

    return List<int>.filled(uncompressedLength, 0);
  }
}

class RangeDecoder {
  final InputStreamBase input;
  var range = 0xfffffffe;
  var code = 0;

  RangeDecoder(this.input) {
    // Load first five bytes into the range decoder.
    for (var i = 0; i < 5; i++) {
      code = (code << 8 | input.readByte()) & 0xffffffff;
    }
  }

  int readBit(List<int> probabilities, int index) {
    if (range < RC_TOP_VALUE) {
      range <<= RC_SHIFT_BITS;
      code = (code << RC_SHIFT_BITS) | input.readByte();
    }

    var p = probabilities[index];
    var bound = (range >> RC_BIT_MODEL_TOTAL_BITS) * p;
    print('code=$code bound=$bound');
    if (code < bound) {
      range = bound;
      probabilities[index] += (RC_BIT_MODEL_TOTAL - p) >> RC_MOVE_BITS;
      print('0');
      return 0;
    } else {
      range -= bound;
      code -= bound;
      probabilities[index] -= p >> RC_MOVE_BITS;
      print('1');
      return 1;
    }
  }

  int readTribit() {
    return readBit([], 0) << 2 | readBit([], 0) << 1 | readBit([], 0);
  }

  int readByte() {
    return readBit([], 0) << 7 |
        readBit([], 0) << 6 |
        readBit([], 0) << 5 |
        readBit([], 0) << 4 |
        readBit([], 0) << 3 |
        readBit([], 0) << 2 |
        readBit([], 0) << 1 |
        readBit([], 0);
  }

  int readLength(List<int> probabilities, int index) {
    if (readBit([], 0) == 0) {
      return 2 + readTribit();
    } else if (readBit([], 0) == 0) {
      return 10 + readTribit();
    } else {
      return 18 + readByte();
    }
  }
}
