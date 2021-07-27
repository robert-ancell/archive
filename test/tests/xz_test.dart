import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('xz', () {
    test('decode empty', () {
      var file = File(p.join(testDirPath, 'res/xz/empty.xz'));
      final compressed = file.readAsBytesSync();

      var data = XZDecoder().decodeBytes(compressed);
      expect(data, isEmpty);
    });

    test('decode hello', () {
      // hello.xz has no LZMA compression due to its simplicity.
      var file = File(p.join(testDirPath, 'res/xz/hello.xz'));
      final compressed = file.readAsBytesSync();

      var data = XZDecoder().decodeBytes(compressed);
      expect(data, equals(utf8.encode('hello\n')));
    });

    test('decode hello repeated', () {
      // Simple file with a small amount of compression due to repeated data.
      var file = File(p.join(testDirPath, 'res/xz/hello-hello-hello.xz'));
      final compressed = file.readAsBytesSync();

      var data = XZDecoder().decodeBytes(compressed);
      expect(data, equals(utf8.encode('hello hello hello')));
    });

    test('decode cat.jpg', () {
      var file = File(p.join(testDirPath, 'res/xz/cat.jpg.xz'));
      final compressed = file.readAsBytesSync();

      var b = File(p.join(testDirPath, 'res/cat.jpg'));
      final b_bytes = b.readAsBytesSync();

      var data = XZDecoder().decodeBytes(compressed);
      compare_bytes(data, b_bytes);
    });
  });
}
