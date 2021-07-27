import '../util/input_stream.dart';

import 'range_decoder.dart';

class LzmaDecoder {
  // Compressed data.
  final _input = RangeDecoder();

  // Number of bits used from [_dictionary] length for probabilities.
  int _positionBits = 2;

  // Number of bits used from [_dictionary] length for literal probabilities.
  int _literalPositionBits = 0;

  // Number of bits used from [_dictionary] for literal probabilities.
  int _literalContextBits = 3;

  // Bit probabilities for determining which LZMA packet is present.
  final _nonLiteralTables = <RangeDecoderTable>[];
  late final RangeDecoderTable _repeatTable;
  late final RangeDecoderTable _repeat0Table;
  final _longRepeat0Tables = <RangeDecoderTable>[];
  late final RangeDecoderTable _repeat1Table;
  late final RangeDecoderTable _repeat2Table;

  // Bit probabilities when decoding literals.
  final _literalTables = <RangeDecoderTable>[];
  final _matchLiteralTables0 = <RangeDecoderTable>[];
  final _matchLiteralTables1 = <RangeDecoderTable>[];

  // Decoder to read length fields in match packets.
  late final _LengthDecoder _matchLengthDecoder;

  // Decoder to read length fields in repeat packets.
  late final _LengthDecoder _repeatLengthDecoder;

  // Decoder to read distance fields in match packaets.
  late final _DistanceDecoder _distanceDecoder;

  // Distances used in matches that can be repeated.
  var _distance0 = 0;
  var _distance1 = 0;
  var _distance2 = 0;
  var _distance3 = 0;

  // Decoder state, used in range decoding.
  var state = _LzmaState.Lit_Lit;

  // Decoded data, which is able to be copied.
  final _dictionary = <int>[];

  /// Creates an LZMA decoder.
  LzmaDecoder() {
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _nonLiteralTables.add(RangeDecoderTable(_LzmaState.values.length));
    }
    _repeatTable = RangeDecoderTable(_LzmaState.values.length);
    _repeat0Table = RangeDecoderTable(_LzmaState.values.length);
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _longRepeat0Tables.add(RangeDecoderTable(_LzmaState.values.length));
    }
    _repeat1Table = RangeDecoderTable(_LzmaState.values.length);
    _repeat2Table = RangeDecoderTable(_LzmaState.values.length);

    var positionCount = 1 << _positionBits;
    _matchLengthDecoder = _LengthDecoder(_input, positionCount);
    _repeatLengthDecoder = _LengthDecoder(_input, positionCount);
    _distanceDecoder = _DistanceDecoder(_input);

    reset();
  }

  // Reset the decoder.
  void reset(
      {int? positionBits,
      int? literalPositionBits,
      int? literalContextBits,
      bool resetDictionary = false}) {
    _positionBits = positionBits ?? _positionBits;
    _literalPositionBits = literalPositionBits ?? _literalPositionBits;
    _literalContextBits = literalContextBits ?? _literalContextBits;

    state = _LzmaState.Lit_Lit;
    _distance0 = 0;
    _distance1 = 0;
    _distance2 = 0;
    _distance3 = 0;

    var maxLiteralStates = 1 << (_literalPositionBits + _literalContextBits);
    if (_literalTables.length != maxLiteralStates) {
      _literalTables.clear();
      _matchLiteralTables0.clear();
      _matchLiteralTables1.clear();
      for (var i = 0; i < maxLiteralStates; i++) {
        _literalTables.add(RangeDecoderTable(256));
        _matchLiteralTables0.add(RangeDecoderTable(256));
        _matchLiteralTables1.add(RangeDecoderTable(256));
      }
    }

    for (var table in _nonLiteralTables) {
      table.reset();
    }
    _repeatTable.reset();
    _repeat0Table.reset();
    for (var table in _longRepeat0Tables) {
      table.reset();
    }
    _repeat1Table.reset();
    _repeat2Table.reset();
    for (var table in _literalTables) {
      table.reset();
    }
    for (var table in _matchLiteralTables0) {
      table.reset();
    }
    for (var table in _matchLiteralTables1) {
      table.reset();
    }

    var positionCount = 1 << _positionBits;
    _matchLengthDecoder.reset(positionCount);
    _repeatLengthDecoder.reset(positionCount);
    _distanceDecoder.reset();

    if (resetDictionary) {
      _dictionary.clear();
    }
  }

  // Decode [input] which contains compressed LZMA data that unpacks to [uncompressedLength] bytes.
  List<int> decode(InputStreamBase input, int uncompressedLength) {
    _input.input = input;

    var initialSize = _dictionary.length;
    var finalSize = initialSize + uncompressedLength;

    // Decode packets (literal, match or repeat) until all the data has been decoded.
    while (_dictionary.length < finalSize) {
      var positionMask = (1 << _positionBits) - 1;
      var posState = _dictionary.length & positionMask;
      if (_input.readBit(_nonLiteralTables[state.index], posState) == 0) {
        _decodeLiteral();
      } else if (_input.readBit(_repeatTable, state.index) == 0) {
        _decodeMatch(posState);
      } else {
        _decodeRepeat(posState);
      }
    }

    // Return new data added to the dictionary.
    return _dictionary.sublist(initialSize);
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
    var prevByte = _dictionary.length > 0 ? _dictionary.last : 0;
    var low = prevByte >> (8 - _literalContextBits);
    var positionMask = (1 << _literalPositionBits) - 1;
    var high = (_dictionary.length & positionMask) << _literalContextBits;
    var hash = low + high;
    var table = _literalTables[hash];

    int value;
    if (_prevPacketIsLiteral()) {
      value = _input.readBittree(table, 8);
    } else {
      // Get the last byte before the match that just occurred.
      prevByte = _dictionary[_dictionary.length - _distance0 - 1];

      value = 0;
      var symbolPrefix = 1;
      var matched = true;
      var matchTable0 = _matchLiteralTables0[hash];
      var matchTable1 = _matchLiteralTables1[hash];
      for (var i = 0; i < 8; i++) {
        int b;
        if (matched) {
          var matchBit = (prevByte >> 7) & 0x1;
          prevByte <<= 1;
          b = _input.readBit(
              matchBit == 0 ? matchTable0 : matchTable1, symbolPrefix | value);
          matched = b == matchBit;
        } else {
          b = _input.readBit(table, symbolPrefix | value);
        }
        value = (value << 1) | b;
        symbolPrefix <<= 1;
      }
    }

    // Add new byte to the output.
    _dictionary.add(value);

    // Update state.
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

    _distance3 = _distance2;
    _distance2 = _distance1;
    _distance1 = _distance0;
    _distance0 = distance;

    state =
        _prevPacketIsLiteral() ? _LzmaState.Lit_Match : _LzmaState.NonLit_Match;
  }

  // Decode a packet that repeats a match already done.
  void _decodeRepeat(int posState) {
    int distance;
    if (_input.readBit(_repeat0Table, state.index) == 0) {
      if (_input.readBit(_longRepeat0Tables[state.index], posState) == 0) {
        _repeatData(_distance0, 1);
        state = _prevPacketIsLiteral()
            ? _LzmaState.Lit_ShortRep
            : _LzmaState.NonLit_Rep;
        return;
      } else {
        distance = _distance0;
      }
    } else if (_input.readBit(_repeat1Table, state.index) == 0) {
      distance = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    } else if (_input.readBit(_repeat2Table, state.index) == 0) {
      distance = _distance2;
      _distance2 = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    } else {
      distance = _distance3;
      _distance3 = _distance2;
      _distance2 = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    }

    var length = _repeatLengthDecoder.readLength(posState);
    _repeatData(distance, length);

    // Update state.
    state =
        _prevPacketIsLiteral() ? _LzmaState.Lit_LongRep : _LzmaState.NonLit_Rep;
  }

  // Repeat decompressed data, starting [distance] bytes back from the end of the buffer and copying [length] bytes.
  void _repeatData(int distance, int length) {
    var start = _dictionary.length - distance - 1;
    for (var i = 0; i < length; i++) {
      _dictionary.add(_dictionary[start + i]);
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

  // Bit probabilities for the length form.
  late final RangeDecoderTable formTable;

  // Bit probabilities when lengths are in the short form (2-9).
  late final List<RangeDecoderTable> shortTables;

  // Bit probabilities when lengths are in the medium form (10-17).
  late final List<RangeDecoderTable> mediumTables;

  // Bit probabilities when lengths are in the long form (18-273).
  late final RangeDecoderTable longTable;

  _LengthDecoder(this._input, int positionCount) {
    formTable = RangeDecoderTable(2);
    shortTables = <RangeDecoderTable>[];
    mediumTables = <RangeDecoderTable>[];
    longTable = RangeDecoderTable(256);

    reset(positionCount);
  }

  // Reset this decoder.
  void reset(int positionCount) {
    formTable.reset();
    if (positionCount != shortTables.length) {
      shortTables.clear();
      mediumTables.clear();
      for (var i = 0; i < positionCount; i++) {
        shortTables.add(RangeDecoderTable(8));
        mediumTables.add(RangeDecoderTable(8));
      }
    } else {
      for (var table in shortTables) {
        table.reset();
      }
      for (var table in mediumTables) {
        table.reset();
      }
    }
    longTable.reset();
  }

  // Read a length field.
  int readLength(int posState) {
    if (_input.readBit(formTable, 0) == 0) {
      // 0xxx - Length 2 - 9
      return 2 + _input.readBittree(shortTables[posState], 3);
    } else if (_input.readBit(formTable, 1) == 0) {
      // 10xxx - Length 10 - 17
      return 10 + _input.readBittree(mediumTables[posState], 3);
    } else {
      // 11xxxxxxxx - Length 18 - 273
      return 18 + _input.readBittree(longTable, 8);
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
  late final List<RangeDecoderTable> _slotTables;

  // Bit probabilities for slots 4-13.
  late final List<RangeDecoderTable> _shortTables;

  // Bit probabilities for slots 14-63.
  late final RangeDecoderTable _longTable;

  _DistanceDecoder(this._input) {
    _slotTables = <RangeDecoderTable>[];
    var slotSize = 1 << _slotBitCount;
    for (var i = 0; i < 4; i++) {
      _slotTables.add(RangeDecoderTable(slotSize));
    }
    _shortTables = <RangeDecoderTable>[];
    for (var slot = 4; slot < 14; slot++) {
      var bitCount = (slot ~/ 2) - 1;
      _shortTables.add(RangeDecoderTable(1 << bitCount));
    }
    var alignSize = 1 << _alignBitCount;
    _longTable = RangeDecoderTable(alignSize);
  }

  // Reset this decoder.
  void reset() {
    for (var table in _slotTables) {
      table.reset();
    }
    for (var table in _shortTables) {
      table.reset();
    }
    _longTable.reset();
  }

  // Reads a distance field.
  // [length] is a match length (minimum of 2).
  int readDistance(int length) {
    var distState = length - 2;
    if (distState >= _slotTables.length) {
      distState = _slotTables.length - 1;
    }
    var table = _slotTables[distState];

    // Distances are encoded starting with a six bit slot.
    var slot = _input.readBittree(table, _slotBitCount);

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
          _input.readBittreeReverse(_shortTables[slot - 4], bitCount);
    }

    // Large distances are a combination of direct bits and reverse bittree format.
    var directCount = bitCount - _alignBitCount;
    var directBits = _input.readDirect(directCount);
    var alignBits = _input.readBittreeReverse(_longTable, _alignBitCount);
    return prefix << bitCount | directBits << _alignBitCount | alignBits;
  }
}
