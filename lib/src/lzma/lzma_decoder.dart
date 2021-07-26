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

const DIST_MODEL_START = 4;
const DIST_MODEL_END = 14;

const int MATCH_LEN_MIN = 2;
const int LEN_LOW_BITS = 3;
const int LEN_LOW_SYMBOLS = (1 << LEN_LOW_BITS);
const int LEN_MID_BITS = 3;
const int LEN_MID_SYMBOLS = (1 << LEN_MID_BITS);
const int LEN_HIGH_BITS = 8;
const int LEN_HIGH_SYMBOLS = (1 << LEN_HIGH_BITS);

class LzmaDecoder {
  late final RangeDecoder input;
  final int uncompressedLength;

  final int literalContextBits;
  late final int _positionMask;
  late final int _literalPositionMask;

  // Probabilty trees
  late final List<List<int>> literal;
  late final List<List<int>> is_match;
  late final List<int> is_rep;
  late final List<int> is_rep0;
  late final List<int> is_rep0_long;
  late final List<int> is_rep1;
  late final List<int> is_rep2;
  late final List<List<int>> dist_slot;
  late final List<int> lengthChoice;
  late final List<List<int>> low;
  late final List<List<int>> mid;
  late final List<int> high;

  var rep0 = 0;
  var rep1 = 0;
  var rep2 = 0;
  var rep3 = 0;

  late final List<int> dictionary;
  var dictionaryPosition = 0;

  var state = LzmaState.Lit_Lit;

  LzmaDecoder(
      {required InputStreamBase input,
      required this.uncompressedLength,
      required this.literalContextBits,
      required int literalPositionBits,
      required int positionBits}) {
    this.input = RangeDecoder(input);

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
    lengthChoice = [defaultProb, defaultProb];
    low = <List<int>>[];
    mid = <List<int>>[];
    for (var i = 0; i < POS_STATES_MAX; i++) {
      low.add(List<int>.filled(LEN_LOW_SYMBOLS, defaultProb));
      mid.add(List<int>.filled(LEN_MID_SYMBOLS, defaultProb));
    }
    high = List<int>.filled(LEN_HIGH_SYMBOLS, defaultProb);

    dictionary = List<int>.filled(uncompressedLength, 0);
  }

  List<int> decode() {
    while (true) {
      var posState = dictionaryPosition & _positionMask;
      if (input.readBit(is_match[state.index], posState) == 0) {
        _decodeLiteral();
      } else if (input.readBit(is_rep, state.index) == 0) {
        _decodeMatch(posState);
      } else {
        _decodeRepeat(posState);
      }
    }

    return List<int>.filled(uncompressedLength, 0);
  }

  void _decodeLiteral() {
    // Get probabilities based on previous byte written.
    var prevByte =
        dictionaryPosition > 0 ? dictionary[dictionaryPosition - 1] : 0;
    var low = prevByte >> (8 - literalContextBits);
    var high =
        (dictionaryPosition & _literalPositionMask) << literalContextBits;
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
        symbol = input.readBittree(probs, 0x100) & 0xff;
        break;
      case LzmaState.Lit_Match:
      case LzmaState.Lit_LongRep:
      case LzmaState.Lit_ShortRep:
      case LzmaState.NonLit_Match:
      case LzmaState.NonLit_Rep:
        symbol = 1;
        var matchByte = dictionary[dictionaryPosition - rep0 - 1] << 1;
        var offset = 0x100;

        while (true) {
          var matchBit = matchByte & offset;
          matchByte <<= 1;
          var i = offset + matchBit + symbol;

          var b = input.readBit(probs, i);
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

    // Add new byte to the dictionary.
    dictionary[dictionaryPosition] = symbol;
    dictionaryPosition++;
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
    var distSlot = input.readBittree(probs, DIST_SLOTS) - DIST_SLOTS;

    int distance;
    if (distSlot < DIST_MODEL_START) {
      distance = distSlot;
    } else {
      var limit = (distSlot >> 1) - 1;
      distance = 2 + (distSlot & 1);

      if (distSlot < DIST_MODEL_END) {
        distance <<= limit;
        distance = input.readBittreeReverse(
            dist_special[distance - distSlot - 1], distance, limit);
      } else {
        // FIXME: rc_direct(&s->rc, &s->lzma.rep0, limit - ALIGN_BITS);
        distance <<= ALIGN_BITS;
        distance = input.readBittreeReverse(dist_align, distance, limit);
      }
    }

    print('MATCH $length $distance');

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
    if (input.readBit(is_rep0, state.index) == 0) {
      if (input.readBit(is_rep0_long, 0) == 0) {
        length = 1;
        distance = 0;
      } else {
        length = _readLength(posState);
        distance = 0; // FIXME
      }
    } else if (input.readBit(is_rep1, state.index) == 0) {
      length = _readLength(posState);
      distance = rep1;
    } else if (input.readBit(is_rep2, state.index) == 0) {
      length = _readLength(posState);
      distance = rep2;
    } else {
      length = _readLength(posState);
      distance = rep3;
    }

    print('REPEAT length=$length distance=$distance');
    var start = dictionaryPosition - distance - 1;
    for (var i = 0; i < length; i++) {
      dictionary[dictionaryPosition] = dictionary[start + i];
      dictionaryPosition++;
    }

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

  int _readLength(int posState) {
    int minLength;
    int limit;
    List<int> probs;

    if (input.readBit(lengthChoice, 0) == 0) {
      minLength = MATCH_LEN_MIN;
      limit = LEN_LOW_SYMBOLS;
      probs = low[posState];
    } else if (input.readBit(lengthChoice, 1) == 0) {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS;
      limit = LEN_MID_SYMBOLS;
      probs = mid[posState];
    } else {
      minLength = MATCH_LEN_MIN + LEN_LOW_SYMBOLS + LEN_MID_SYMBOLS;
      limit = LEN_HIGH_SYMBOLS;
      probs = high;
    }

    return minLength + input.readBittree(probs, limit) - limit;
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
    //print('code=$code bound=$bound prob=$p');
    if (code < bound) {
      range = bound;
      probabilities[index] += (RC_BIT_MODEL_TOTAL - p) >> RC_MOVE_BITS;
      //print('0 prob=${probabilities[index]}');
      return 0;
    } else {
      range -= bound;
      code -= bound;
      probabilities[index] -= p >> RC_MOVE_BITS;
      //print('1 prob=${probabilities[index]}');
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

  int readBittreeReverse(List<int> probabilities, int value, int limit) {
    var symbol = 1;
    while (true) {
      var b = readBit(probabilities, symbol);
      symbol = (symbol << 1) | b;
      if (symbol >= limit) {
        return symbol;
      }
    }
  }
}
