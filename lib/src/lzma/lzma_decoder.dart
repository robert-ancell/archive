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

const int POS_STATES_MAX = (1 << 4);

const int LITERAL_CODER_SIZE = 0x300;
const int LITERAL_CODERS_MAX = (1 << 4);

const int DIST_STATES = 4;
const int DIST_SLOT_BITS = 6;
const int DIST_SLOTS = (1 << DIST_SLOT_BITS);

const int DIST_MODEL_START = 4;
const int DIST_MODEL_END = 14;
const int FULL_DISTANCES_BITS = (DIST_MODEL_END ~/ 2);
const int FULL_DISTANCES = (1 << FULL_DISTANCES_BITS);

const int MATCH_LEN_MIN = 2;
const int LEN_LOW_BITS = 3;
const int LEN_LOW_SYMBOLS = (1 << LEN_LOW_BITS);
const int LEN_MID_BITS = 3;
const int LEN_MID_SYMBOLS = (1 << LEN_MID_BITS);
const int LEN_HIGH_BITS = 8;
const int LEN_HIGH_SYMBOLS = (1 << LEN_HIGH_BITS);

const int ALIGN_BITS = 4;
const int ALIGN_SIZE = (1 << ALIGN_BITS);

class LzmaDecoder {
  // Compressed data.
  late final RangeDecoder _input;

  // Uncompressed data.
  late final List<int> _output; // FIXME: Uint8List
  var _outputPosition = 0;

  final int _literalContextBits;
  late final int _positionMask;
  late final int _literalPositionMask;

  // Probabilty trees
  // FIXME: uint16
  late final List<List<int>> is_match;
  late final List<int> is_rep;
  late final List<int> is_rep0;
  late final List<int> is_rep0_long;
  late final List<int> is_rep1;
  late final List<int> is_rep2;

  late final List<List<int>> literal;

  late final List<List<int>> dist_slot;
  late final List<int> dist_special;
  late final List<int> dist_align;

  // Probabilty trees for decoding lengths.
  late final List<int> lengthChoice;
  late final List<List<int>> low;
  late final List<List<int>> mid;
  late final List<int> high;

  // Last four distances used in matches.
  var rep0 = 0;
  var rep1 = 0;
  var rep2 = 0;
  var rep3 = 0;

  var state = LzmaState.Lit_Lit;

  LzmaDecoder(
      {required InputStreamBase input,
      required int uncompressedLength,
      required int literalContextBits,
      required int literalPositionBits,
      required int positionBits})
      : _literalContextBits = literalContextBits {
    _input = RangeDecoder(input);

    _output = List<int>.filled(uncompressedLength, 0);

    _positionMask = (1 << positionBits) - 1;
    _literalPositionMask = (1 << literalPositionBits) - 1;

    var defaultProb = RC_BIT_MODEL_TOTAL ~/ 2;
    is_match = <List<int>>[];
    for (var i = 0; i < LzmaState.values.length; i++) {
      is_match.add(List<int>.filled(16, defaultProb));
    }
    is_rep = List<int>.filled(16, defaultProb);
    is_rep0 = List<int>.filled(16, defaultProb);
    is_rep0_long = List<int>.filled(16, defaultProb);
    is_rep1 = List<int>.filled(16, defaultProb);
    is_rep2 = List<int>.filled(16, defaultProb);
    literal = <List<int>>[];
    for (var i = 0; i < LITERAL_CODERS_MAX; i++) {
      literal.add(List<int>.filled(LITERAL_CODER_SIZE, defaultProb));
    }
    dist_slot = <List<int>>[];
    for (var i = 0; i < DIST_STATES; i++) {
      dist_slot.add(List<int>.filled(DIST_SLOTS, defaultProb));
    }
    dist_special =
        List<int>.filled(FULL_DISTANCES - DIST_MODEL_END, defaultProb);
    dist_align = List<int>.filled(ALIGN_SIZE, defaultProb);
    lengthChoice = [defaultProb, defaultProb];
    low = <List<int>>[];
    mid = <List<int>>[];
    for (var i = 0; i < POS_STATES_MAX; i++) {
      low.add(List<int>.filled(LEN_LOW_SYMBOLS, defaultProb));
      mid.add(List<int>.filled(LEN_MID_SYMBOLS, defaultProb));
    }
    high = List<int>.filled(LEN_HIGH_SYMBOLS, defaultProb);
  }

  List<int> decode() {
    while (_outputPosition < _output.length) {
      var posState = _outputPosition & _positionMask;
      if (_input.readBit(is_match[state.index], posState) == 0) {
        _decodeLiteral();
      } else if (_input.readBit(is_rep, state.index) == 0) {
        _decodeMatch(posState);
      } else {
        _decodeRepeat(posState);
      }
    }

    return _output;
  }

  void _decodeLiteral() {
    // Get probabilities based on previous byte written.
    var prevByte = _outputPosition > 0 ? _output[_outputPosition - 1] : 0;
    var low = prevByte >> (8 - _literalContextBits);
    var high = (_outputPosition & _literalPositionMask) << _literalContextBits;
    var probs = literal[low + high];

    int symbol;
    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
      case LzmaState.Match_Lit:
      case LzmaState.Rep_Lit:
      case LzmaState.ShortRep_Lit:
        symbol = _input.readBittree(probs, 0x100) & 0xff;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.Lit_LongRep:
      case LzmaState.Lit_ShortRep:
      case LzmaState.NonLit_Match:
      case LzmaState.NonLit_Rep:
        symbol = 1;
        var matchByte = _output[_outputPosition - rep0 - 1] << 1;
        var offset = 0x100;

        while (true) {
          var matchBit = matchByte & offset;
          matchByte <<= 1;
          var i = offset + matchBit + symbol;

          var b = _input.readBit(probs, i);
          symbol = (symbol << 1) | b;
          if (b != 0) {
            offset &= matchBit;
          } else {
            offset &= ~matchBit;
          }
          if (symbol >= 0x100) {
            symbol &= 0xff;
            break;
          }
        }
        break;
    }

    // Add new byte to the output.
    _output[_outputPosition] = symbol;
    _outputPosition++;
    print('LITERAL ' + symbol.toRadixString(16).padLeft(2, '0'));

    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
        state = LzmaState.Lit_Lit;
        break;
      case LzmaState.Match_Lit:
        state = LzmaState.Match_Lit_Lit;
        break;
      case LzmaState.Rep_Lit:
        state = LzmaState.Rep_Lit_Lit;
        break;
      case LzmaState.ShortRep_Lit:
        state = LzmaState.ShortRep_Lit_Lit;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.NonLit_Match:
        state = LzmaState.Match_Lit;
        break;
      case LzmaState.Lit_LongRep:
      case LzmaState.NonLit_Rep:
        state = LzmaState.Rep_Lit; // FIXME: Or ShortRep_Lit?
        break;
      case LzmaState.Lit_ShortRep:
        state = LzmaState.ShortRep_Lit;
        break;
    }
  }

  void _decodeMatch(int posState) {
    var length = _readLength(posState);

    var distState = length < DIST_STATES + MATCH_LEN_MIN
        ? length - MATCH_LEN_MIN
        : DIST_STATES - 1;
    var probs = dist_slot[distState];
    var distSlot = _input.readBittree(probs, DIST_SLOTS) - DIST_SLOTS;

    int distance;
    if (distSlot < DIST_MODEL_START) {
      distance = distSlot;
    } else {
      var limit = (distSlot >> 1) - 1;
      distance = 2 + (distSlot & 1);

      if (distSlot < DIST_MODEL_END) {
        distance <<= limit;
        distance = _input.readBittreeReverse(
            dist_special, distance - distSlot - 1, distance, limit);
      } else {
        distance = _input.readDirect(distance, limit - ALIGN_BITS);
        distance <<= ALIGN_BITS;
        distance = _input.readBittreeReverse(dist_align, 0, distance, limit);
      }
    }

    print('MATCH distance=$distance length=$length');

    _repeatData(distance, length);

    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
      case LzmaState.Match_Lit:
      case LzmaState.Rep_Lit:
      case LzmaState.ShortRep_Lit:
        state = LzmaState.Lit_Match;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.Lit_LongRep:
      case LzmaState.Lit_ShortRep:
      case LzmaState.NonLit_Match:
      case LzmaState.NonLit_Rep:
        state = LzmaState.NonLit_Match;
        break;
    }
  }

  void _decodeRepeat(int posState) {
    int length;
    int distance;
    if (_input.readBit(is_rep0, state.index) == 0) {
      if (_input.readBit(is_rep0_long, 0) == 0) {
        length = 1;
        distance = 0;
      } else {
        length = _readLength(posState);
        distance = 0; // FIXME
      }
    } else if (_input.readBit(is_rep1, state.index) == 0) {
      length = _readLength(posState);
      distance = rep1;
    } else if (_input.readBit(is_rep2, state.index) == 0) {
      length = _readLength(posState);
      distance = rep2;
    } else {
      length = _readLength(posState);
      distance = rep3;
    }

    print('REPEAT distance=$distance length=$length');
    _repeatData(distance, length);

    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
      case LzmaState.Match_Lit:
      case LzmaState.Rep_Lit:
      case LzmaState.ShortRep_Lit:
        state = length == 1 && distance == 0
            ? LzmaState.Lit_ShortRep
            : LzmaState.Lit_LongRep;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.Lit_LongRep:
      case LzmaState.Lit_ShortRep:
      case LzmaState.NonLit_Match:
      case LzmaState.NonLit_Rep:
        state = LzmaState.NonLit_Rep;
        break;
    }
  }

  // Repeat decompressed data, starting [distance] bytes back from the end of the buffer and copying [length] bytes.
  void _repeatData(int distance, int length) {
    var start = _outputPosition - distance - 1;
    for (var i = 0; i < length; i++) {
      _output[_outputPosition] = _output[start + i];
      _outputPosition++;
    }

    rep3 = rep2;
    rep2 = rep1;
    rep1 = rep0;
    rep0 = distance;
  }

  int _readLength(int posState) {
    int minLength;
    int limit;
    List<int> probs;

    if (_input.readBit(lengthChoice, 0) == 0) {
      minLength = MATCH_LEN_MIN;
      limit = LEN_LOW_SYMBOLS;
      probs = low[posState];
    } else if (_input.readBit(lengthChoice, 1) == 0) {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS;
      limit = LEN_MID_SYMBOLS;
      probs = mid[posState];
    } else {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS + LEN_MID_SYMBOLS;
      limit = LEN_HIGH_SYMBOLS;
      probs = high;
    }

    return minLength + _input.readBittree(probs, limit) - limit;
  }
}

class RangeDecoder {
  final InputStreamBase _input;
  var range = 0xfffffffe;
  var code = 0;

  RangeDecoder(this._input) {
    // Load first five bytes into the range decoder.
    for (var i = 0; i < 5; i++) {
      code = (code << 8 | _input.readByte()) & 0xffffffff;
    }
  }

  int readBit(List<int> probabilities, int index) {
    if (range < RC_TOP_VALUE) {
      range <<= RC_SHIFT_BITS;
      code = (code << RC_SHIFT_BITS) | _input.readByte();
    }

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
      range >>= 1;
      code -= range;
      var mask = 0 - (code >> 31); // FIXME?
      code += range & mask;
      value = (value << 1) + (mask + 1);
      limit--;
      if (limit <= 0) {
        return value;
      }
    }
  }
}
