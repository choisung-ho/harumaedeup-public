// lib/services/identity_service.dart

import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class IdentityService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// ✅ 본인 확인 정보(음성/얼굴) 등록 여부 확인
  static Future<bool> checkIdentityRegistered(String uid) async {
    try {
      // 1. 음성 파일 확인
      final voiceList = await _storage
          .ref('Users/$uid/source/user_voice/')
          .listAll();
      bool hasVoice = voiceList.items.isNotEmpty;

      // 2. 얼굴 사진 확인
      final faceList = await _storage
          .ref('Users/$uid/source/user_face/')
          .listAll();
      bool hasFace = faceList.items.isNotEmpty;

      return hasVoice && hasFace;
    } catch (e) {
      debugPrint("본인 확인 정보 조회 실패 (미등록으로 간주): $e");
      return false;
    }
  }

  /// 📸 얼굴 사진 업로드 로직
  static Future<Map<String, dynamic>> uploadFacePhotos({
    required String uid,
    required List<XFile> photos,
    required Function(int current, int total, double progress) onProgress,
  }) async {
    try {
      int total = photos.length;
      int successCount = 0;

      for (int i = 0; i < total; i++) {
        final file = photos[i];

        // 파일명: face_{uid}_{순서}.jpg
        final fileName = 'face_${uid}_${i + 1}.jpg';
        final ref = _storage.ref('Users/$uid/source/user_face/$fileName');

        // 메타데이터 설정 (이미지)
        final metadata = SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {'owner_id': uid},
        );

        // 업로드
        await ref.putFile(File(file.path), metadata);
        successCount++;

        // 진행률 콜백
        onProgress(i + 1, total, ((i + 1) / total) * 100);
      }

      return {'success': true, 'message': '$successCount장의 사진이 등록되었습니다.'};
    } catch (e) {
      return {'success': false, 'error': '업로드 중 오류 발생: $e'};
    }
  }

  /// 🎤 음성 파일 참조 가져오기 (확장자 .m4a 고정)
  static Reference getVoiceStorageRef(String uid) {
    // ✅ [수정] 파일명 규칙: voice_{uid}.m4a
    final fileName = 'voice_$uid.m4a';
    return _storage.ref('Users/$uid/source/user_voice/$fileName');
  }
}
