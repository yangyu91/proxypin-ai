/// DeepSeekHashV1 — SHA3-256 变体，跳过 Keccak-f[1600] 第 0 轮（仅 1..23 轮）。
///
/// 移植自 deepseek-pow (shaohuahuawww/deepseek-pow) 的纯 Python 实现，
/// 算法与 DeepSeek 网页版 `sha3_wasm_bg.wasm` 完全一致。

import 'dart:typed_data';

/// Keccak-f[1600] 轮常量
const List<int> _rc = [
  0x0000000000000001,
  0x0000000000008082,
  0x800000000000808A,
  0x8000000080008000,
  0x000000000000808B,
  0x0000000080000001,
  0x8000000080008081,
  0x8000000000008009,
  0x000000000000008A,
  0x0000000000000088,
  0x0000000080008009,
  0x000000008000000A,
  0x000000008000808B,
  0x800000000000008B,
  0x8000000000008089,
  0x8000000000008003,
  0x8000000000008002,
  0x8000000000000080,
  0x000000000000800A,
  0x800000008000000A,
  0x8000000080008081,
  0x8000000000008080,
  0x0000000080000001,
  0x8000000080008008,
];

const int _m = 0xFFFFFFFFFFFFFFFF;

const List<int> _pi = [
  0,
  6,
  12,
  18,
  24,
  3,
  9,
  10,
  16,
  22,
  1,
  7,
  13,
  19,
  20,
  4,
  5,
  11,
  17,
  23,
  2,
  8,
  14,
  15,
  21,
];

const List<int> _rho = [
  0,
  44,
  43,
  21,
  14,
  28,
  20,
  3,
  45,
  61,
  1,
  6,
  25,
  8,
  18,
  27,
  36,
  10,
  15,
  56,
  62,
  55,
  39,
  41,
  2,
];

int _rotl(int v, int k) => ((v << k) | (v >>> (64 - k))) & _m;

/// Keccak-f[1600] 跳过第 0 轮（r = 1 .. 23）。
void _keccakF23(List<int> s) {
  final a = List<int>.from(s);
  for (var r = 1; r < 24; r++) {
    final c = List<int>.generate(
        5, (i) => (a[i] ^ a[i + 5] ^ a[i + 10] ^ a[i + 15] ^ a[i + 20]) & _m);
    final d = List<int>.generate(
        5, (i) => (c[(i + 4) % 5] ^ _rotl(c[(i + 1) % 5], 1)) & _m);
    for (var i = 0; i < 5; i++) {
      for (var j = 0; j < 25; j += 5) {
        a[i + j] = (a[i + j] ^ d[i]) & _m;
      }
    }
    final b = List<int>.generate(25, (i) => _rotl(a[_pi[i]], _rho[i]));
    for (var j = 0; j < 5; j++) {
      for (var i = 0; i < 5; i++) {
        a[j * 5 + i] = (b[j * 5 + i] ^
                ((~b[j * 5 + (i + 1) % 5] & _m) & b[j * 5 + (i + 2) % 5])) &
            _m;
      }
    }
    a[0] = (a[0] ^ _rc[r]) & _m;
  }
  for (var i = 0; i < 25; i++) {
    s[i] = a[i];
  }
}

/// 计算 DeepSeekHashV1 哈希，返回 32 字节。
Uint8List deepSeekHashV1(List<int> data) {
  const rate = 136;
  final s = List<int>.filled(25, 0);
  var off = 0;

  while (off + rate <= data.length) {
    for (var i = 0; i < rate ~/ 8; i++) {
      var lane = 0;
      for (var b = 0; b < 8; b++) {
        lane |= (data[off + i * 8 + b] & 0xFF) << (8 * b);
      }
      s[i] ^= lane;
    }
    _keccakF23(s);
    off += rate;
  }

  final buf = Uint8List(rate);
  final rem = data.length - off;
  buf.setRange(0, rem, data.sublist(off));
  buf[rem] = 0x06;
  buf[rate - 1] |= 0x80;
  for (var i = 0; i < rate ~/ 8; i++) {
    var lane = 0;
    for (var b = 0; b < 8; b++) {
      lane |= (buf[i * 8 + b] & 0xFF) << (8 * b);
    }
    s[i] ^= lane;
  }
  _keccakF23(s);

  final out = Uint8List(32);
  for (var i = 0; i < 4; i++) {
    final lane = s[i];
    for (var b = 0; b < 8; b++) {
      out[i * 8 + b] = (lane >> (8 * b)) & 0xFF;
    }
  }
  return out;
}
