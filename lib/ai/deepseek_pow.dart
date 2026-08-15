/// DeepSeek PoW 求解器（DeepSeekHashV1）。
///
/// 移植自 deepseek-pp 的 core/deepseek/pow.ts 与 deepseek-pow 的纯实现。

import 'dart:convert';
import 'dart:typed_data';

import 'deepseek_hash.dart';

/// PoW 挑战（服务端下发）
class DeepSeekPowChallenge {
  final String algorithm;
  final String challenge;
  final String salt;
  final int difficulty;
  final String signature;
  final int expireAt;

  DeepSeekPowChallenge({
    required this.algorithm,
    required this.challenge,
    required this.salt,
    required this.difficulty,
    required this.signature,
    required this.expireAt,
  });

  factory DeepSeekPowChallenge.fromJson(Map<String, dynamic> json) {
    return DeepSeekPowChallenge(
      algorithm: json['algorithm']?.toString() ?? 'DeepSeekHashV1',
      challenge: json['challenge']?.toString() ?? '',
      salt: json['salt']?.toString() ?? '',
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 0,
      signature: json['signature']?.toString() ?? '',
      expireAt: (json['expire_at'] ?? json['expireAt'] ?? 0) as int? ?? 0,
    );
  }
}

/// 求解 PoW，返回 `X-DS-PoW-Response` 头的值（base64 编码的 JSON）。
String solveDeepSeekPow(DeepSeekPowChallenge challenge,
    {String targetPath = '/api/v0/chat/completion'}) {
  final answer = _solveAnswer(challenge);
  final result = <String, dynamic>{
    'algorithm': challenge.algorithm,
    'challenge': challenge.challenge,
    'salt': challenge.salt,
    'answer': answer,
    'signature': challenge.signature,
    'target_path': targetPath,
  };
  return base64Encode(utf8.encode(jsonEncode(result)));
}

int _solveAnswer(DeepSeekPowChallenge challenge) {
  final prefix = utf8.encode('${challenge.salt}_${challenge.expireAt}_');
  final target = _hexToBytes(challenge.challenge.toLowerCase());

  for (var answer = 0; answer < challenge.difficulty; answer++) {
    final input = <int>[...prefix, ...utf8.encode('$answer')];
    if (_bytesEqual(deepSeekHashV1(input), target)) {
      return answer;
    }
  }
  return -1;
}

Uint8List _hexToBytes(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
