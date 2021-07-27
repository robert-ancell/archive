import 'util/archive_exception.dart';
import 'util/crc32.dart';
import 'util/input_stream.dart';

import 'lzma/lzma_decoder.dart';

/// Decompress data with the xz format decoder.
class XZDecoder {
  List<int> decodeBytes(List<int> data, {bool verify = false}) {
    return decodeBuffer(InputStream(data), verify: verify);
  }

  List<int> decodeBuffer(InputStreamBase input, {bool verify = false}) {
    var decoder = _XZStreamDecoder();
    return decoder.decode(input);
  }
}

/// Decodes an XZ stream.
class _XZStreamDecoder {
  // Decode this stream and return the uncompressed data.
  List<int> decode(InputStreamBase input) {
    var flags = _readStreamHeader(input);

    var blocks = <_XZBlock>[];
    while (true) {
      var blockHeader = input.peekBytes(1).readByte();

      if (blockHeader == 0) {
        var indexSize = _readStreamIndex(input, blocks);
        _readStreamFooter(input, flags, indexSize);
        var data = <int>[];
        for (var block in blocks) {
          data.addAll(block.data);
        }
        return data;
      }

      var blockLength = (blockHeader + 1) * 4;
      var block = _readBlock(input, blockLength, flags & 0xf);
      blocks.add(block);
    }
  }

  // Reads an XZ steam header from [input] and returns the stream flags.
  int _readStreamHeader(InputStreamBase input) {
    var magic = input.readBytes(6);
    var magicIsValid = magic[0] == 253 &&
        magic[1] == 55 /* '7' */ &&
        magic[2] == 122 /* 'z' */ &&
        magic[3] == 88 /* 'X' */ &&
        magic[4] == 90 /* 'Z' */ &&
        magic[5] == 0;
    if (!magicIsValid) {
      throw ArchiveException('Invalid XZ stream header signature');
    }

    var header = input.readBytes(2);
    if (header.readByte() != 0) {
      throw ArchiveException('Invalid stream flags');
    }
    var flags = header.readByte();
    header.reset();

    var crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      throw ArchiveException('Invalid stream header CRC checksum');
    }

    return flags;
  }

  // Reads a data block from [input].
  _XZBlock _readBlock(InputStreamBase input, int headerLength, int checkType) {
    var header = input.readBytes(headerLength - 4);

    header.skip(1); // Skip length field
    var flags = header.readByte();
    var nFilters = (flags & 0x3) + 1;
    var hasCompressedLength = flags & 0x40 != 0;
    var hasUncompressedLength = flags & 0x80 != 0;

    int? compressedLength;
    if (hasCompressedLength) {
      compressedLength = _readMultibyteInteger(header);
    }
    int? uncompressedLength;
    if (hasUncompressedLength) {
      uncompressedLength = _readMultibyteInteger(header);
    }

    var filterIds = <int>[];
    var dictionarySize = 0;
    for (var i = 0; i < nFilters; i++) {
      var id = _readMultibyteInteger(header);
      var propertiesLength = _readMultibyteInteger(header);
      var properties = header.readBytes(propertiesLength);
      if (id == 0x21) {
        var v = properties[0];
        if (v > 40) {
          throw ArchiveException('Invalid LZMA dictionary size');
        } else if (v == 40) {
          dictionarySize = 1 << 32;
        } else if (v % 2 == 0) {
          dictionarySize = 1 << ((v ~/ 2) + 12);
        } else {
          dictionarySize = 1 << (((v - 1) ~/ 2) + 11);
        }
      }
      filterIds.add(id);
    }
    _readPadding(header);
    header.reset();

    var crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      throw ArchiveException('Invalid block CRC checksum');
    }

    if (filterIds.length != 1 && filterIds.first != 0x21) {
      throw ArchiveException('Unsupported filters');
    }

    var data = _readLZMA2(input, dictionarySize);
    if (uncompressedLength != null && data.length != uncompressedLength) {
      throw ArchiveException("Uncompressed data doesn't match expected length");
    }
    _readPadding(input);

    // Checksum
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        /*var crc = */ input.readUint32(); // FIXME
        break;
      case 0x2:
      case 0x3:
        input.skip(4);
        break;
      case 0x4: // CRC64
        /*var crc = */ input.readUint64(); // FIXME
        break;
      case 0x5:
      case 0x6:
        input.skip(8); // FIXME
        break;
      case 0x7:
      case 0x8:
      case 0x9:
        input.skip(16);
        break;
      case 0xa: // SHA-256
        input.skip(32); // FIXME
        break;
      case 0xb:
      case 0xc:
        input.skip(32);
        break;
      case 0xd:
      case 0xe:
      case 0xf:
        input.skip(64);
        break;
      default:
        throw ArchiveException('Unknown block check type $checkType');
    }

    return _XZBlock(data, compressedLength);
  }

  // Reads LZMA2 data from [input].
  // Returns the decompressed data.
  List<int> _readLZMA2(InputStreamBase input, int dictionarySize) {
    var data = <int>[];
    while (true) {
      var control = input.readByte();
      // Control values:
      // 00000000 - end marker
      // 00000001 - reset dictionary and uncompresed data
      // 00000010 - uncompressed data
      // 1rrxxxxx - LZMA data with reset (r) and bits 16-20 of size (x)
      if (control & 0x80 == 0) {
        if (control == 0) {
          return data;
        } else if (control == 1) {
          var length = input.readByte() << 8 | input.readByte() + 1;
          data.addAll(input.readBytes(length).toUint8List());
        } else {
          throw ArchiveException('Unknown LZMA2 control code $control');
        }
      } else {
        var reset = (control >> 5) & 0x3;
        var uncompressedLength = (control & 0x1f) << 16 |
            input.readByte() << 8 |
            input.readByte() + 1;
        var compressedLength = input.readByte() << 8 | input.readByte() + 1;
        var literalContextBits = 0;
        var literalPositionBits = 0;
        var positionBits = 0;
        if (reset >= 2) {
          var properties = input.readByte();
          positionBits = properties ~/ 45;
          properties -= positionBits * 45;
          literalPositionBits = properties ~/ 9;
          literalContextBits = properties - literalPositionBits * 8;
        }

        var decoder = LzmaDecoder(
            literalContextBits: literalContextBits,
            literalPositionBits: literalPositionBits,
            positionBits: positionBits);
        data.addAll(decoder.decode(
            input.readBytes(compressedLength), uncompressedLength));
      }
    }
  }

  // Reads an XZ stream index from [input] and validates it against [blocks].
  // Returns the length of the index in bytes.
  int _readStreamIndex(InputStreamBase input, List<_XZBlock> blocks) {
    var startPosition = input.position;
    input.skip(1); // Skip index indicator
    var nRecords = _readMultibyteInteger(input);
    if (nRecords != blocks.length) {
      throw ArchiveException('Stream index block count mismatch');
    }

    for (var i = 0; i < nRecords; i++) {
      var compressedLength = _readMultibyteInteger(input);
      var uncompressedLength = _readMultibyteInteger(input);
      if (blocks[i].compressedLength != null &&
          blocks[i].compressedLength != compressedLength) {
        throw ArchiveException('Stream index compressed length mismatch');
      }
      if (blocks[i].data.length != uncompressedLength) {
        throw ArchiveException('Stream index uncompressed length mismatch');
      }
    }
    _readPadding(input);

    // Re-read for CRC calculation
    var indexLength = input.position - startPosition;
    input.rewind(indexLength);
    var indexData = input.readBytes(indexLength);

    var crc = input.readUint32();
    if (getCrc32(indexData.toUint8List()) != crc) {
      throw ArchiveException('Invalid stream index CRC checksum');
    }

    return indexLength + 4;
  }

  // Reads an XZ stream footer from [input] and checks it has [flags] the same as the stream header and the index size matches [indexSize].
  void _readStreamFooter(InputStreamBase input, int flags, int indexSize) {
    var crc = input.readUint32();
    var footer = input.readBytes(6);
    var backwardSize = (footer.readUint32() + 1) * 4;
    if (backwardSize != indexSize) {
      throw ArchiveException('Stream footer has invalid index size');
    }
    if (footer.readByte() != 0) {
      throw ArchiveException('Invalid stream flags');
    }
    var footerFlags = footer.readByte();
    if (footerFlags != flags) {
      throw ArchiveException("Stream footer flags don't match header flags");
    }
    footer.reset();

    if (getCrc32(footer.toUint8List()) != crc) {
      throw ArchiveException('Invalid stream footer CRC checksum');
    }

    var magic = input.readBytes(2);
    if (magic[0] != 89 /* 'Y' */ && magic[1] != 90 /* 'Z' */) {
      throw ArchiveException('Invalid XZ stream footer signature');
    }
  }

  // Reads a multibyte integer from [input].
  int _readMultibyteInteger(InputStreamBase input) {
    var value = 0;
    var shift = 0;
    while (true) {
      var data = input.readByte();
      value |= (data & 0x7f) << shift;
      if (data & 0x80 == 0) {
        return value;
      }
      shift += 7;
    }
  }

  // Reads padding from [input] until the read position is aligned to a 4 byte boundary.
  // The padding bytes are confirmed to be zeros.
  void _readPadding(InputStreamBase input) {
    while (input.position % 4 != 0) {
      if (input.readByte() != 0) {
        throw ArchiveException('Non-zero padding byte');
      }
    }
  }
}

class _XZBlock {
  final List<int> data;
  final int? compressedLength;

  const _XZBlock(this.data, this.compressedLength);
}
