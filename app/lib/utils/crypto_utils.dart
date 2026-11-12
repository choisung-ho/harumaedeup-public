// lib/utils/crypto_utils.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:crypto/crypto.dart';

class CryptoUtils {
  // 환경변수에서 키 로드
  static String get _keyString {
    final key = dotenv.env['ENCRYPTION_KEY'];
    if (key == null || key.isEmpty) {
      throw Exception('ENCRYPTION_KEY가 .env 파일에 설정되지 않았습니다.');
    }
    return key;
  }

  /// [복호화] Fernet 암호화된 문자열 -> 원본 데이터(String or JSON Object) 반환
  static dynamic decrypt(String? encryptedText) {
    if (encryptedText == null || encryptedText.isEmpty) return null;

    try {
      // 1. Base64 URL-safe 디코딩
      final tokenBytes = base64Url.decode(encryptedText);

      // 2. Fernet 토큰 파싱
      if (tokenBytes.length < 57) {
        // 최소 길이: version(1) + timestamp(8) + iv(16) + ciphertext(1+) + hmac(32)
        throw Exception('Invalid Fernet token: too short');
      }

      final version = tokenBytes[0];
      if (version != 0x80) {
        throw Exception('Invalid Fernet token version');
      }

      // timestamp는 검증 생략 (필요시 추가)
      final iv = tokenBytes.sublist(9, 25);
      final ciphertext = tokenBytes.sublist(25, tokenBytes.length - 32);
      final providedHmac = tokenBytes.sublist(tokenBytes.length - 32);

      // 3. 키 파생 (Fernet은 32바이트 키를 signing key 16바이트 + encryption key 16바이트로 분할)
      final keyBytes = base64.decode(_keyString);
      if (keyBytes.length != 32) {
        throw Exception('Invalid key length: expected 32 bytes');
      }

      final signingKey = keyBytes.sublist(0, 16);
      final encryptionKey = keyBytes.sublist(16, 32);

      // 4. HMAC 검증
      final hmacData = tokenBytes.sublist(0, tokenBytes.length - 32);
      final hmacSha256 = Hmac(sha256, signingKey);
      final computedHmac = hmacSha256.convert(hmacData).bytes;

      bool hmacValid = true;
      for (int i = 0; i < 32; i++) {
        if (computedHmac[i] != providedHmac[i]) {
          hmacValid = false;
          break;
        }
      }

      if (!hmacValid) {
        throw Exception('HMAC verification failed');
      }

      // 5. AES-128-CBC 복호화
      final cipher = CBCBlockCipher(AESEngine());
      final params = ParametersWithIV(
        KeyParameter(encryptionKey),
        Uint8List.fromList(iv),
      );
      cipher.init(false, params); // false = decrypt

      final decrypted = _processBlocks(cipher, Uint8List.fromList(ciphertext));

      // 6. PKCS7 패딩 제거
      final unpaddedData = _removePkcs7Padding(decrypted);
      final decryptedString = utf8.decode(unpaddedData);

      // 7. JSON 파싱 시도
      try {
        return jsonDecode(decryptedString);
      } catch (e) {
        return decryptedString;
      }
    } catch (e) {
      print("❌ 복호화 실패: $e");
      return "내용을 불러올 수 없습니다.";
    }
  }

  /// [암호화] (필요시 사용)
  static String encrypt(dynamic data) {
    if (data == null) return "";

    try {
      String textData;
      if (data is String) {
        textData = data;
      } else {
        textData = jsonEncode(data);
      }

      final keyBytes = base64.decode(_keyString);
      final signingKey = keyBytes.sublist(0, 16);
      final encryptionKey = keyBytes.sublist(16, 32);

      // IV 생성
      final random = FortunaRandom();
      final seed = Uint8List.fromList(
        List<int>.generate(
          32,
          (i) => DateTime.now().millisecondsSinceEpoch % 256,
        ),
      );
      random.seed(KeyParameter(seed));
      final iv = random.nextBytes(16);

      // Timestamp (8 bytes, big-endian)
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final timestampBytes = Uint8List(8);
      for (int i = 0; i < 8; i++) {
        timestampBytes[7 - i] = (timestamp >> (i * 8)) & 0xFF;
      }

      // PKCS7 패딩 추가
      final plainBytes = utf8.encode(textData);
      final paddedData = _addPkcs7Padding(Uint8List.fromList(plainBytes), 16);

      // AES-128-CBC 암호화
      final cipher = CBCBlockCipher(AESEngine());
      final params = ParametersWithIV(KeyParameter(encryptionKey), iv);
      cipher.init(true, params); // true = encrypt

      final encrypted = _processBlocks(cipher, paddedData);

      // Fernet 토큰 구성: version | timestamp | iv | ciphertext
      final tokenData = Uint8List.fromList([
        0x80, // version
        ...timestampBytes,
        ...iv,
        ...encrypted,
      ]);

      // HMAC 생성
      final hmacSha256 = Hmac(sha256, signingKey);
      final hmacBytes = hmacSha256.convert(tokenData).bytes;

      // 최종 토큰: tokenData | hmac
      final finalToken = Uint8List.fromList([...tokenData, ...hmacBytes]);

      return base64Url.encode(finalToken);
    } catch (e) {
      print("❌ 암호화 실패: $e");
      return "";
    }
  }

  // 블록 암호화/복호화 처리
  static Uint8List _processBlocks(BlockCipher cipher, Uint8List data) {
    final blockSize = cipher.blockSize;
    final result = Uint8List(data.length);

    for (int offset = 0; offset < data.length; offset += blockSize) {
      cipher.processBlock(data, offset, result, offset);
    }

    return result;
  }

  // PKCS7 패딩 추가
  static Uint8List _addPkcs7Padding(Uint8List data, int blockSize) {
    final padLength = blockSize - (data.length % blockSize);
    final padded = Uint8List(data.length + padLength);
    padded.setRange(0, data.length, data);
    for (int i = data.length; i < padded.length; i++) {
      padded[i] = padLength;
    }
    return padded;
  }

  // PKCS7 패딩 제거
  static Uint8List _removePkcs7Padding(Uint8List data) {
    final padLength = data[data.length - 1];
    return data.sublist(0, data.length - padLength);
  }
}
