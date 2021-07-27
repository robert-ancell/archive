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

/// FIXME: Kill
const int LITERAL_CODER_SIZE = 0x300;

class LzmaDecoder {
  // Compressed data.
  late final RangeDecoder _input;

  // Uncompressed data.
  late final List<int> _output; // FIXME: Uint8List
  var _outputPosition = 0;

  late final int _positionMask;
  final int _literalPositionBits;
  final int _literalContextBits;

  // Probabilty trees
  // FIXME: uint16
  late final List<List<int>> is_match;
  late final List<int> is_rep;
  late final List<int> is_rep0;
  late final List<List<int>> is_rep0_long;
  late final List<int> is_rep1;
  late final List<int> is_rep2;

  late final List<List<int>> literal;

  late final LengthDecoder _matchLengthDecoder;
  late final LengthDecoder _repeatLengthDecoder;
  late final DistanceDecoder _distanceDecoder;

  // Distances used in matches that can be repeated.
  var rep0 = 0;
  var rep1 = 0;
  var rep2 = 0;
  var rep3 = 0;

  var state = LzmaState.Lit_Lit;

  /// Creates an LZMA decoder reading from [input] which contains data of length [uncompressedLength] compressed with the LZMA algorithm.
  LzmaDecoder(
      {required InputStreamBase input,
      required int uncompressedLength,
      required int literalPositionBits,
      required int literalContextBits,
      required int positionBits})
      : _literalPositionBits = literalPositionBits,
        _literalContextBits = literalContextBits {
    _input = RangeDecoder(input);

    _output = List<int>.filled(uncompressedLength, 0);

    _positionMask = (1 << positionBits) - 1;

    is_match = <List<int>>[];
    for (var i = 0; i < LzmaState.values.length; i++) {
      is_match.add(_input.makeProbabilityTree(16));
    }
    is_rep = _input.makeProbabilityTree(16);
    is_rep0 = _input.makeProbabilityTree(16);
    is_rep0_long = <List<int>>[];
    for (var i = 0; i < LzmaState.values.length; i++) {
      is_rep0_long.add(_input.makeProbabilityTree(16));
    }
    is_rep1 = _input.makeProbabilityTree(16);
    is_rep2 = _input.makeProbabilityTree(16);
    literal = <List<int>>[];
    var maxLiteralCodes = 1 << (literalPositionBits + literalContextBits);
    for (var i = 0; i < maxLiteralCodes; i++) {
      literal.add(_input.makeProbabilityTree(LITERAL_CODER_SIZE));
    }

    _matchLengthDecoder = LengthDecoder(_input, positionBits: positionBits);
    _repeatLengthDecoder = LengthDecoder(_input, positionBits: positionBits);
    _distanceDecoder = DistanceDecoder(_input);

    reset();
  }

  void reset() {
    state = LzmaState.Lit_Lit;
    rep0 = 0;
    rep1 = 0;
    rep2 = 0;
    rep3 = 0;

    for (var i = 0; i < LzmaState.values.length; i++) {
      _input.resetProbabilityTree(is_match[i]);
    }
    _input.resetProbabilityTree(is_rep);
    _input.resetProbabilityTree(is_rep0);
    for (var i = 0; i < LzmaState.values.length; i++) {
      _input.resetProbabilityTree(is_rep0_long[i]);
    }
    _input.resetProbabilityTree(is_rep1);
    _input.resetProbabilityTree(is_rep2);
    for (var i = 0; i < literal.length; i++) {
      _input.resetProbabilityTree(literal[i]);
    }

    _matchLengthDecoder.reset();
    _repeatLengthDecoder.reset();
    _distanceDecoder.reset();
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
    var positionMask = (1 << _literalPositionBits) - 1;
    var high = (_outputPosition & positionMask) << _literalContextBits;
    var probabilities = literal[low + high];

    int symbol;
    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
      case LzmaState.Match_Lit:
      case LzmaState.Rep_Lit:
      case LzmaState.ShortRep_Lit:
        symbol = _input.readBittree(probabilities, 0x100) & 0xff;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.Lit_LongRep:
      case LzmaState.Lit_ShortRep:
      case LzmaState.NonLit_Match:
      case LzmaState.NonLit_Rep:
        // Get the last byte before this match.
        var matchByte = _output[_outputPosition - rep0 - 1] << 1;

        symbol = 1;
        var offset = 0x100;
        while (true) {
          var matchBit = matchByte & offset;
          matchByte <<= 1;
          var i = offset + matchBit + symbol;

          var b = _input.readBit(probabilities, i);
          symbol = (symbol << 1) | b;
          if (b != 0) {
            offset &= matchBit;
          } else {
            offset &= matchBit ^ 0xffffffff;
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
        state = LzmaState.Rep_Lit;
        break;
      case LzmaState.Lit_ShortRep:
        state = LzmaState.ShortRep_Lit;
        break;
    }
  }

  void _decodeMatch(int posState) {
    var length = _matchLengthDecoder.readLength(posState);
    var distance = _distanceDecoder.readDistance(length);

    _repeatData(distance, length);

    rep3 = rep2;
    rep2 = rep1;
    rep1 = rep0;
    rep0 = distance;

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
    var literalState = LzmaState.Lit_LongRep;
    if (_input.readBit(is_rep0, state.index) == 0) {
      if (_input.readBit(is_rep0_long[state.index], posState) == 0) {
        literalState = LzmaState.Lit_ShortRep;
        length = 1;
        distance = rep0;
      } else {
        length = _repeatLengthDecoder.readLength(posState);
        distance = rep0;
      }
    } else if (_input.readBit(is_rep1, state.index) == 0) {
      length = _repeatLengthDecoder.readLength(posState);
      distance = rep1;
      rep1 = rep0;
      rep0 = distance;
    } else if (_input.readBit(is_rep2, state.index) == 0) {
      length = _repeatLengthDecoder.readLength(posState);
      distance = rep2;
      rep2 = rep1;
      rep1 = rep0;
      rep0 = distance;
    } else {
      length = _repeatLengthDecoder.readLength(posState);
      distance = rep3;
      rep3 = rep2;
      rep2 = rep1;
      rep1 = rep0;
      rep0 = distance;
    }

    _repeatData(distance, length);

    switch (state) {
      case LzmaState.Lit_Lit:
      case LzmaState.Match_Lit_Lit:
      case LzmaState.Rep_Lit_Lit:
      case LzmaState.ShortRep_Lit_Lit:
      case LzmaState.Match_Lit:
      case LzmaState.Rep_Lit:
      case LzmaState.ShortRep_Lit:
        state = literalState;
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
  }
}

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

const int MATCH_LEN_MIN = 2;

class LengthDecoder {
  static const int LEN_LOW_BITS = 3;
  static const int LEN_LOW_SYMBOLS = (1 << LEN_LOW_BITS);
  static const int LEN_MID_BITS = 3;
  static const int LEN_MID_SYMBOLS = (1 << LEN_MID_BITS);
  static const int LEN_HIGH_BITS = 8;
  static const int LEN_HIGH_SYMBOLS = (1 << LEN_HIGH_BITS);

  final RangeDecoder _input;

  // Probabilty trees for decoding lengths.
  late final List<int> lengthChoice;
  late final List<List<int>> low;
  late final List<List<int>> mid;
  late final List<int> high;

  LengthDecoder(this._input, {required int positionBits}) {
    lengthChoice = _input.makeProbabilityTree(2);
    low = <List<int>>[];
    mid = <List<int>>[];
    for (var i = 0; i < 1 << positionBits; i++) {
      low.add(_input.makeProbabilityTree(LEN_LOW_SYMBOLS));
      mid.add(_input.makeProbabilityTree(LEN_MID_SYMBOLS));
    }
    high = _input.makeProbabilityTree(LEN_HIGH_SYMBOLS);
    reset();
  }

  void reset() {
    _input.resetProbabilityTree(lengthChoice);
    for (var i = 0; i < low.length; i++) {
      _input.resetProbabilityTree(low[i]);
    }
    for (var i = 0; i < mid.length; i++) {
      _input.resetProbabilityTree(mid[i]);
    }
    _input.resetProbabilityTree(high);
  }

  int readLength(int posState) {
    int limit;
    List<int> probabilities;

    int minLength;
    if (_input.readBit(lengthChoice, 0) == 0) {
      minLength = MATCH_LEN_MIN;
      limit = LEN_LOW_SYMBOLS;
      probabilities = low[posState];
    } else if (_input.readBit(lengthChoice, 1) == 0) {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS;
      limit = LEN_MID_SYMBOLS;
      probabilities = mid[posState];
    } else {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS + LEN_MID_SYMBOLS;
      limit = LEN_HIGH_SYMBOLS;
      probabilities = high;
    }

    return minLength + _input.readBittree(probabilities, limit) - limit;
  }
}

class DistanceDecoder {
// FIXME: Kill
  static const int DIST_STATES = 4;
  static const int DIST_SLOT_BITS = 6;
  static const int DIST_SLOTS = (1 << DIST_SLOT_BITS);

  static const int DIST_MODEL_START = 4;
  static const int DIST_MODEL_END = 14;
  static const int FULL_DISTANCES_BITS = (DIST_MODEL_END ~/ 2);
  static const int FULL_DISTANCES = (1 << FULL_DISTANCES_BITS);

  static const int ALIGN_BITS = 4;
  static const int ALIGN_SIZE = (1 << ALIGN_BITS);

  final RangeDecoder _input;
  late final List<List<int>> dist_slot;
  late final List<int> dist_special;
  late final List<int> dist_align;

  DistanceDecoder(this._input) {
    dist_slot = <List<int>>[];
    for (var i = 0; i < DIST_STATES; i++) {
      dist_slot.add(_input.makeProbabilityTree(DIST_SLOTS));
    }
    dist_special = _input.makeProbabilityTree(FULL_DISTANCES - DIST_MODEL_END);
    dist_align = _input.makeProbabilityTree(ALIGN_SIZE);
  }

  void reset() {
    for (var i = 0; i < dist_slot.length; i++) {
      _input.resetProbabilityTree(dist_slot[i]);
    }
    _input.resetProbabilityTree(dist_special);
    _input.resetProbabilityTree(dist_align);
  }

  int readDistance(int length) {
    var distState = length < DIST_STATES + MATCH_LEN_MIN
        ? length - MATCH_LEN_MIN
        : DIST_STATES - 1;
    var probabilities = dist_slot[distState];
    var distSlot = _input.readBittree(probabilities, DIST_SLOTS) - DIST_SLOTS;

    if (distSlot < DIST_MODEL_START) {
      return distSlot;
    }

    var limit = (distSlot >> 1) - 1;
    var distance = 2 + (distSlot & 1);

    if (distSlot < DIST_MODEL_END) {
      distance <<= limit;
      return _input.readBittreeReverse(
          dist_special, distance - distSlot - 1, distance, limit);
    } else {
      distance = _input.readDirect(distance, limit - ALIGN_BITS);
      distance <<= ALIGN_BITS;
      return _input.readBittreeReverse(dist_align, 0, distance, ALIGN_BITS);
    }
  }
}
