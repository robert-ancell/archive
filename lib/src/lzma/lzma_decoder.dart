import '../util/input_stream.dart';

import 'range_decoder.dart';

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

  // Bit probabilities for determining which LZMA packet is present.
  late final List<RangeDecoderProbabilities> _nonLiteralProbabilities;
  late final RangeDecoderProbabilities _repeatProbabilities;
  late final RangeDecoderProbabilities _repeat0Probabilities;
  late final List<RangeDecoderProbabilities> _longRepeat0Probabilities;
  late final RangeDecoderProbabilities _repeat1Probabilities;
  late final RangeDecoderProbabilities _repeat2Probabilities;

  // Bit probabilities when decoding literals.
  late final List<List<RangeDecoderProbabilities>> _literalProbabilities;

  // Decoder to read length fields in match packets.
  late final _LengthDecoder _matchLengthDecoder;

  // Decoder to read length fields in repeat packets.
  late final _LengthDecoder _repeatLengthDecoder;

  // Decoder to read distance fields in match packaets.
  late final _DistanceDecoder _distanceDecoder;

  // Distances used in matches that can be repeated.
  var distance0 = 0;
  var distance1 = 0;
  var distance2 = 0;
  var distance3 = 0;

  // Decoder state, used in range decoding.
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

    _nonLiteralProbabilities = <RangeDecoderProbabilities>[];
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _nonLiteralProbabilities
          .add(RangeDecoderProbabilities(_LzmaState.values.length));
    }
    _repeatProbabilities = RangeDecoderProbabilities(_LzmaState.values.length);
    _repeat0Probabilities = RangeDecoderProbabilities(_LzmaState.values.length);
    _longRepeat0Probabilities = <RangeDecoderProbabilities>[];
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _longRepeat0Probabilities
          .add(RangeDecoderProbabilities(_LzmaState.values.length));
    }
    _repeat1Probabilities = RangeDecoderProbabilities(_LzmaState.values.length);
    _repeat2Probabilities = RangeDecoderProbabilities(_LzmaState.values.length);
    _literalProbabilities = <List<RangeDecoderProbabilities>>[];
    var maxLiteralStates = 1 << (literalPositionBits + literalContextBits);
    for (var i = 0; i < maxLiteralStates; i++) {
      _literalProbabilities.add([
        RangeDecoderProbabilities(256),
        RangeDecoderProbabilities(256),
        RangeDecoderProbabilities(256)
      ]);
    }

    var positionCount = 1 << positionBits;
    _matchLengthDecoder = _LengthDecoder(_input, positionCount);
    _repeatLengthDecoder = _LengthDecoder(_input, positionCount);
    _distanceDecoder = _DistanceDecoder(_input);

    reset();
  }

  void reset() {
    state = _LzmaState.Lit_Lit;
    distance0 = 0;
    distance1 = 0;
    distance2 = 0;
    distance3 = 0;

    for (var tree in _nonLiteralProbabilities) {
      tree.reset();
    }
    _repeatProbabilities.reset();
    _repeat0Probabilities.reset();
    for (var tree in _longRepeat0Probabilities) {
      tree.reset();
    }
    _repeat1Probabilities.reset();
    _repeat2Probabilities.reset();
    for (var tree in _literalProbabilities) {
      tree[0].reset();
      tree[1].reset();
      tree[2].reset();
    }

    _matchLengthDecoder.reset();
    _repeatLengthDecoder.reset();
    _distanceDecoder.reset();
  }

  List<int> decode() {
    // Decode packets (literal, match or repeat) until all the data has been decoded.
    while (_outputPosition < _output.length) {
      var positionMask = (1 << _positionBits) - 1;
      var posState = _outputPosition & positionMask;
      if (_input.readBit(_nonLiteralProbabilities[state.index], posState) ==
          0) {
        _decodeLiteral();
      } else if (_input.readBit(_repeatProbabilities, state.index) == 0) {
        _decodeMatch(posState);
      } else {
        _decodeRepeat(posState);
      }
    }

    return _output;
  }

  // Returns true if the previous packet seen was a literal.
  bool _prevPacketIsLiteral() {
    switch (state) {
      case _LzmaState.Lit_Lit:
      case _LzmaState.Match_Lit_Lit:
      case _LzmaState.Rep_Lit_Lit:
      case _LzmaState.ShortRep_Lit_Lit:
      case _LzmaState.Match_Lit:
      case _LzmaState.Rep_Lit:
      case _LzmaState.ShortRep_Lit:
        return true;
      case _LzmaState.Lit_Match:
      case _LzmaState.Lit_LongRep:
      case _LzmaState.Lit_ShortRep:
      case _LzmaState.NonLit_Match:
      case _LzmaState.NonLit_Rep:
        return false;
    }
  }

  // Decode a packet containing a literal byte.
  void _decodeLiteral() {
    // Get probabilities based on previous byte written.
    var prevByte = _outputPosition > 0 ? _output[_outputPosition - 1] : 0;
    var low = prevByte >> (8 - _literalContextBits);
    var positionMask = (1 << _literalPositionBits) - 1;
    var high = (_outputPosition & positionMask) << _literalContextBits;
    var probabilities = _literalProbabilities[low + high];

    int value;
    if (_prevPacketIsLiteral()) {
      value = _input.readBittree(probabilities[0], 8);
    } else {
      // Get the last byte before the match that just occurred.
      prevByte = _output[_outputPosition - distance0 - 1];

      value = 0;
      var symbolPrefix = 1;
      var matched = true;
      for (var i = 0; i < 8; i++) {
        int b;
        if (matched) {
          var matchBit = (prevByte >> 7) & 0x1;
          prevByte <<= 1;
          b = _input.readBit(probabilities[1 + matchBit], symbolPrefix | value);
          matched = b == matchBit;
        } else {
          b = _input.readBit(probabilities[0], symbolPrefix | value);
        }
        value = (value << 1) | b;
        symbolPrefix <<= 1;
      }
    }

    // Add new byte to the output.
    _output[_outputPosition] = value;
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

  // Decode a packet that matches some already decoded data.
  void _decodeMatch(int posState) {
    var length = _matchLengthDecoder.readLength(posState);
    var distance = _distanceDecoder.readDistance(length);

    _repeatData(distance, length);

    distance3 = distance2;
    distance2 = distance1;
    distance1 = distance0;
    distance0 = distance;

    state =
        _prevPacketIsLiteral() ? _LzmaState.Lit_Match : _LzmaState.NonLit_Match;
  }

  // Decode a packet that repeats a match already done.
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

    state = _prevPacketIsLiteral() ? literalState : _LzmaState.NonLit_Rep;
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

// The decoder state which tracks the sequence of LZMA packets received.
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

// Decodes match/repeat length fields from LZMA data.
class _LengthDecoder {
  // Data being read from.
  final RangeDecoder _input;

  // Probabilities
  late final RangeDecoderProbabilities formProbabilities;

  // Bit probabilities when lengths are in the short form (2-9).
  late final List<RangeDecoderProbabilities> shortProbabilities;

  // Bit probabilities when lengths are in the medium form (10-17).
  late final List<RangeDecoderProbabilities> mediumProbabilities;

  // Bit probabilities when lengths are in the long form (18-273).
  late final RangeDecoderProbabilities longProbabilities;

  _LengthDecoder(this._input, int positionCount) {
    formProbabilities = RangeDecoderProbabilities(2);
    shortProbabilities = <RangeDecoderProbabilities>[];
    mediumProbabilities = <RangeDecoderProbabilities>[];
    for (var i = 0; i < positionCount; i++) {
      shortProbabilities.add(RangeDecoderProbabilities(8));
      mediumProbabilities.add(RangeDecoderProbabilities(8));
    }
    longProbabilities = RangeDecoderProbabilities(256);

    reset();
  }

  // Reset this decoder.
  void reset() {
    formProbabilities.reset();
    for (var tree in shortProbabilities) {
      tree.reset();
    }
    for (var tree in mediumProbabilities) {
      tree.reset();
    }
    longProbabilities.reset();
  }

  // Read a length field.
  int readLength(int posState) {
    if (_input.readBit(formProbabilities, 0) == 0) {
      // 0xxx - Length 2 - 9
      return 2 + _input.readBittree(shortProbabilities[posState], 3);
    } else if (_input.readBit(formProbabilities, 1) == 0) {
      // 10xxx - Length 10 - 17
      return 10 + _input.readBittree(mediumProbabilities[posState], 3);
    } else {
      // 11xxxxxxxx - Length 18 - 273
      return 18 + _input.readBittree(longProbabilities, 8);
    }
  }
}

// Decodes match distance fields from LZMA data.
class _DistanceDecoder {
  // Number of bits in a slot.
  final int _slotBitCount = 6;

  // Number of aligned bits.
  final int _alignBitCount = 4;

  // Data being read from.
  final RangeDecoder _input;

  // Bit probabilities for the 6 bit slot.
  late final List<RangeDecoderProbabilities> _slotProbabilities;

  // Bit probabilities for slots 4-13.
  late final List<RangeDecoderProbabilities> _shortProbabilities;

  // Bit probabilities for slots 14-63.
  late final RangeDecoderProbabilities _longProbabilities;

  _DistanceDecoder(this._input) {
    _slotProbabilities = <RangeDecoderProbabilities>[];
    var slotSize = 1 << _slotBitCount;
    for (var i = 0; i < 4; i++) {
      _slotProbabilities.add(RangeDecoderProbabilities(slotSize));
    }
    _shortProbabilities = <RangeDecoderProbabilities>[];
    for (var slot = 4; slot < 14; slot++) {
      var bitCount = (slot ~/ 2) - 1;
      _shortProbabilities.add(RangeDecoderProbabilities(1 << bitCount));
    }
    var alignSize = 1 << _alignBitCount;
    _longProbabilities = RangeDecoderProbabilities(alignSize);
  }

  // Reset this decoder.
  void reset() {
    for (var tree in _slotProbabilities) {
      tree.reset();
    }
    for (var tree in _shortProbabilities) {
      tree.reset();
    }
    _longProbabilities.reset();
  }

  // Reads a distance field.
  // [length] is a match length (minimum of 2).
  int readDistance(int length) {
    var distState = length - 2;
    if (distState >= _slotProbabilities.length) {
      distState = _slotProbabilities.length - 1;
    }
    var probabilities = _slotProbabilities[distState];

    // Distances are encoded starting with a six bit slot.
    var slot = _input.readBittree(probabilities, _slotBitCount);

    // Slots 0-3 map to the distances 0-3.
    if (slot < 4) {
      return slot;
    }

    // Larger slots have a variable number of bits that follow.
    var prefix = 0x2 | (slot & 0x1);
    var bitCount = (slot ~/ 2) - 1;

    // Short distances are stored in reverse bittree format.
    if (slot < 14) {
      return prefix << bitCount |
          _input.readBittreeReverse(_shortProbabilities[slot - 4], bitCount);
    }

    // Large distances are a combination of direct bits and reverse bittree format.
    var directCount = bitCount - _alignBitCount;
    var directBits = _input.readDirect(directCount);
    var alignBits =
        _input.readBittreeReverse(_longProbabilities, _alignBitCount);
    return prefix << bitCount | directBits << _alignBitCount | alignBits;
  }
}
