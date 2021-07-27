import '../util/input_stream.dart';

import 'range_decoder.dart';

enum _LzmaState {
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

  // Number of bits used from [_outputPosition] for probabilities.
  final int _positionBits;

  // Number of bits used from [_outputPosition] for literal probabilities.
  final int _literalPositionBits;

  // Number of bits used from [_output] for literal probabilities.
  final int _literalContextBits;

  // Probabilty trees
  // FIXME: uint16
  late final List<List<int>> is_match;
  late final List<int> _repeatProbabilities;
  late final List<int> _repeat0Probabilities;
  late final List<List<int>> _longRepeat0Probabilities;
  late final List<int> _repeat1Probabilities;
  late final List<int> _repeat2Probabilities;

  late final List<List<int>> _literalProbabilities;

  late final LengthDecoder _matchLengthDecoder;
  late final LengthDecoder _repeatLengthDecoder;
  late final DistanceDecoder _distanceDecoder;

  // Distances used in matches that can be repeated.
  var distance0 = 0;
  var distance1 = 0;
  var distance2 = 0;
  var distance3 = 0;

  var state = _LzmaState.Lit_Lit;

  /// Creates an LZMA decoder reading from [input] which contains data of length [uncompressedLength] compressed with the LZMA algorithm.
  LzmaDecoder(
      {required InputStreamBase input,
      required int uncompressedLength,
      required int positionBits,
      required int literalPositionBits,
      required int literalContextBits})
      : _positionBits = positionBits,
        _literalPositionBits = literalPositionBits,
        _literalContextBits = literalContextBits {
    _input = RangeDecoder(input);

    _output = List<int>.filled(uncompressedLength, 0);

    is_match = <List<int>>[];
    for (var i = 0; i < _LzmaState.values.length; i++) {
      is_match.add(_input.makeProbabilityTree(16));
    }
    _repeatProbabilities = _input.makeProbabilityTree(16);
    _repeat0Probabilities = _input.makeProbabilityTree(16);
    _longRepeat0Probabilities = <List<int>>[];
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _longRepeat0Probabilities.add(_input.makeProbabilityTree(16));
    }
    _repeat1Probabilities = _input.makeProbabilityTree(16);
    _repeat2Probabilities = _input.makeProbabilityTree(16);
    _literalProbabilities = <List<int>>[];
    var maxLiteralCodes = 1 << (literalPositionBits + literalContextBits);
    for (var i = 0; i < maxLiteralCodes; i++) {
      _literalProbabilities.add(_input.makeProbabilityTree(LITERAL_CODER_SIZE));
    }

    _matchLengthDecoder = LengthDecoder(_input, positionBits: positionBits);
    _repeatLengthDecoder = LengthDecoder(_input, positionBits: positionBits);
    _distanceDecoder = DistanceDecoder(_input);

    reset();
  }

  void reset() {
    state = _LzmaState.Lit_Lit;
    distance0 = 0;
    distance1 = 0;
    distance2 = 0;
    distance3 = 0;

    for (var i = 0; i < _LzmaState.values.length; i++) {
      _input.resetProbabilityTree(is_match[i]);
    }
    _input.resetProbabilityTree(_repeatProbabilities);
    _input.resetProbabilityTree(_repeat0Probabilities);
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _input.resetProbabilityTree(_longRepeat0Probabilities[i]);
    }
    _input.resetProbabilityTree(_repeat1Probabilities);
    _input.resetProbabilityTree(_repeat2Probabilities);
    for (var i = 0; i < _literalProbabilities.length; i++) {
      _input.resetProbabilityTree(_literalProbabilities[i]);
    }

    _matchLengthDecoder.reset();
    _repeatLengthDecoder.reset();
    _distanceDecoder.reset();
  }

  List<int> decode() {
    while (_outputPosition < _output.length) {
      var positionMask = (1 << _positionBits) - 1;
      var posState = _outputPosition & positionMask;
      if (_input.readBit(is_match[state.index], posState) == 0) {
        _decodeLiteral();
      } else if (_input.readBit(_repeatProbabilities, state.index) == 0) {
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
    var probabilities = _literalProbabilities[low + high];

    int symbol;
    switch (state) {
      case _LzmaState.Lit_Lit:
      case _LzmaState.Match_Lit_Lit:
      case _LzmaState.Rep_Lit_Lit:
      case _LzmaState.ShortRep_Lit_Lit:
      case _LzmaState.Match_Lit:
      case _LzmaState.Rep_Lit:
      case _LzmaState.ShortRep_Lit:
        symbol = _input.readBittree(probabilities, 0x100) & 0xff;
        break;
      case _LzmaState.Lit_Match:
      case _LzmaState.Lit_LongRep:
      case _LzmaState.Lit_ShortRep:
      case _LzmaState.NonLit_Match:
      case _LzmaState.NonLit_Rep:
        // Get the last byte before this match.
        var matchByte = _output[_outputPosition - distance0 - 1] << 1;

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
      case _LzmaState.Lit_Lit:
      case _LzmaState.Match_Lit_Lit:
      case _LzmaState.Rep_Lit_Lit:
      case _LzmaState.ShortRep_Lit_Lit:
        state = _LzmaState.Lit_Lit;
        break;
      case _LzmaState.Match_Lit:
        state = _LzmaState.Match_Lit_Lit;
        break;
      case _LzmaState.Rep_Lit:
        state = _LzmaState.Rep_Lit_Lit;
        break;
      case _LzmaState.ShortRep_Lit:
        state = _LzmaState.ShortRep_Lit_Lit;
        break;
      case _LzmaState.Lit_Match:
      case _LzmaState.NonLit_Match:
        state = _LzmaState.Match_Lit;
        break;
      case _LzmaState.Lit_LongRep:
      case _LzmaState.NonLit_Rep:
        state = _LzmaState.Rep_Lit;
        break;
      case _LzmaState.Lit_ShortRep:
        state = _LzmaState.ShortRep_Lit;
        break;
    }
  }

  void _decodeMatch(int posState) {
    var length = _matchLengthDecoder.readLength(posState);
    var distance = _distanceDecoder.readDistance(length);

    _repeatData(distance, length);

    distance3 = distance2;
    distance2 = distance1;
    distance1 = distance0;
    distance0 = distance;

    switch (state) {
      case _LzmaState.Lit_Lit:
      case _LzmaState.Match_Lit_Lit:
      case _LzmaState.Rep_Lit_Lit:
      case _LzmaState.ShortRep_Lit_Lit:
      case _LzmaState.Match_Lit:
      case _LzmaState.Rep_Lit:
      case _LzmaState.ShortRep_Lit:
        state = _LzmaState.Lit_Match;
        break;
      case _LzmaState.Lit_Match:
      case _LzmaState.Lit_LongRep:
      case _LzmaState.Lit_ShortRep:
      case _LzmaState.NonLit_Match:
      case _LzmaState.NonLit_Rep:
        state = _LzmaState.NonLit_Match;
        break;
    }
  }

  void _decodeRepeat(int posState) {
    int length;
    int distance;
    var literalState = _LzmaState.Lit_LongRep;
    if (_input.readBit(_repeat0Probabilities, state.index) == 0) {
      if (_input.readBit(_longRepeat0Probabilities[state.index], posState) ==
          0) {
        literalState = _LzmaState.Lit_ShortRep;
        length = 1;
        distance = distance0;
      } else {
        length = _repeatLengthDecoder.readLength(posState);
        distance = distance0;
      }
    } else if (_input.readBit(_repeat1Probabilities, state.index) == 0) {
      length = _repeatLengthDecoder.readLength(posState);
      distance = distance1;
      distance1 = distance0;
      distance0 = distance;
    } else if (_input.readBit(_repeat2Probabilities, state.index) == 0) {
      length = _repeatLengthDecoder.readLength(posState);
      distance = distance2;
      distance2 = distance1;
      distance1 = distance0;
      distance0 = distance;
    } else {
      length = _repeatLengthDecoder.readLength(posState);
      distance = distance3;
      distance3 = distance2;
      distance2 = distance1;
      distance1 = distance0;
      distance0 = distance;
    }

    _repeatData(distance, length);

    switch (state) {
      case _LzmaState.Lit_Lit:
      case _LzmaState.Match_Lit_Lit:
      case _LzmaState.Rep_Lit_Lit:
      case _LzmaState.ShortRep_Lit_Lit:
      case _LzmaState.Match_Lit:
      case _LzmaState.Rep_Lit:
      case _LzmaState.ShortRep_Lit:
        state = literalState;
        break;
      case _LzmaState.Lit_Match:
      case _LzmaState.Lit_LongRep:
      case _LzmaState.Lit_ShortRep:
      case _LzmaState.NonLit_Match:
      case _LzmaState.NonLit_Rep:
        state = _LzmaState.NonLit_Rep;
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

  static const int ALIGN_BITS = 4;

  final RangeDecoder _input;
  late final List<List<int>> dist_slot;
  late final List<int> dist_special;
  late final List<int> dist_align;

  DistanceDecoder(this._input) {
    dist_slot = <List<int>>[];
    for (var i = 0; i < DIST_STATES; i++) {
      dist_slot.add(_input.makeProbabilityTree(DIST_SLOTS));
    }
    var fullDistancesBits = (DIST_MODEL_END ~/ 2);
    var fullDistances = (1 << fullDistancesBits);
    dist_special = _input.makeProbabilityTree(fullDistances - DIST_MODEL_END);
    var alignSize = 1 << ALIGN_BITS;
    dist_align = _input.makeProbabilityTree(alignSize);
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
