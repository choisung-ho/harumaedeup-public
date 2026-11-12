// lib/utils/galaxy_path_helper.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 갤럭시 기기별 파일 경로 자동 감지 헬퍼
///
/// 통화녹음, 사진, 동영상 등의 경로를 스마트하게 추적하여
/// 어르신들이 경로를 헤매지 않도록 도와줌
///
/// ✅ Android 10+ (API 29+) 최적화
/// ✅ 갤럭시 기기 특화 경로 지원
class GalaxyPathHelper {
  /// 갤럭시 통화 녹음 주요 경로 (우선순위 순)
  ///
  /// 1. Android 11+ 최신 국룰
  /// 2. 구형 갤럭시 국룰
  /// 3. 음악 폴더 취급 (일부 기기)
  /// 4. T전화 사용자 전용
  static const List<String> _callRecordingPaths = [
    'Recordings/Call', // Android 11+ 최신
    'Call', // 구형 갤럭시
    'Music/Call Recordings', // 음악 폴더 취급
    'TPhone/VoiceRecorder', // T전화 사용자
  ];

  /// DCIM 카메라 경로 (사진/동영상 공통)
  /// ★ 갤럭시 + Pixel 에뮬레이터 모두 지원
  static const List<String> _cameraPaths = [
    'DCIM/Camera', // 표준 카메라 앱 (갤럭시/실제 기기)
    'Pictures', // ★ Pixel 에뮬레이터 카메라 저장 위치
    'DCIM/100ANDRO', // 일부 구형 기기
    'Pictures/Screenshots', // 스크린샷 (선택사항)
  ];

  /// 통화 녹음 파일 확장자
  static const List<String> _recordingExtensions = [
    '.m4a',
    '.amr',
    '.3gp',
    '.mp3',
    '.wav',
  ];

  /// 동영상 파일 확장자
  static const List<String> _videoExtensions = [
    '.mp4',
    '.3gp',
    '.avi',
    '.mkv',
    '.mov',
  ];

  /// 이미지 파일 확장자
  static const List<String> _imageExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.heic',
    '.webp',
  ];

  /// 🎯 통화 녹음 폴더 자동 감지
  ///
  /// 우선순위대로 경로를 체크하고, 실제 녹음 파일이 있는지 확인
  ///
  /// Returns:
  /// - 성공 시: 전체 경로 (예: `/storage/emulated/0/Recordings/Call`)
  /// - 실패 시: `null`
  static Future<String?> detectCallRecordingPath() async {
    try {
      final baseDir = await _getExternalStorageDirectory();
      if (baseDir == null) {
        debugPrint('⚠️ External Storage를 찾을 수 없습니다');
        return null;
      }

      for (final relativePath in _callRecordingPaths) {
        final fullPath = '${baseDir.path}/$relativePath';
        final dir = Directory(fullPath);

        if (await dir.exists()) {
          debugPrint('📂 경로 존재 확인: $fullPath');
          // ✅ 폴더가 존재하면 바로 반환 (파일 유무 체크 제거)
          debugPrint('✅ 통화 녹음 폴더 자동 감지 성공: $fullPath');
          return fullPath;
        }
      }

      debugPrint('❌ 통화 녹음 폴더 자동 감지 실패');
      return null;
    } catch (e) {
      debugPrint('❌ 통화 녹음 경로 감지 에러: $e');
      return null;
    }
  }

  /// 🎯 카메라 폴더 자동 감지 (사진/동영상 공통)
  ///
  /// Returns:
  /// - 성공 시: 전체 경로 (예: `/storage/emulated/0/DCIM/Camera`)
  /// - 실패 시: `null`
  static Future<String?> detectCameraPath() async {
    try {
      final baseDir = await _getExternalStorageDirectory();
      if (baseDir == null) {
        debugPrint('⚠️ External Storage를 찾을 수 없습니다');
        return null;
      }

      for (final relativePath in _cameraPaths) {
        final fullPath = '${baseDir.path}/$relativePath';
        final dir = Directory(fullPath);

        if (await dir.exists()) {
          debugPrint('📂 경로 존재 확인: $fullPath');
          // ✅ 폴더가 존재하면 바로 반환 (파일 유무 체크 제거)
          debugPrint('✅ 카메라 폴더 자동 감지 성공: $fullPath');
          return fullPath;
        }
      }

      debugPrint('❌ 카메라 폴더 자동 감지 실패');
      return null;
    } catch (e) {
      debugPrint('❌ 카메라 경로 감지 에러: $e');
      return null;
    }
  }

  /// 🔍 폴더에 녹음 파일이 있는지 확인
  static Future<bool> _hasRecordingFiles(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();

      return files.any((file) => _isRecordingFile(file.path));
    } catch (e) {
      debugPrint('⚠️ 녹음 파일 확인 에러: $e');
      return false;
    }
  }

  /// 🔍 폴더에 미디어 파일이 있는지 확인
  static Future<bool> _hasMediaFiles(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();

      return files.any(
        (file) => _isVideoFile(file.path) || _isImageFile(file.path),
      );
    } catch (e) {
      debugPrint('⚠️ 미디어 파일 확인 에러: $e');
      return false;
    }
  }

  /// 녹음 파일 여부 확인
  static bool _isRecordingFile(String path) {
    final lowerPath = path.toLowerCase();
    return _recordingExtensions.any((ext) => lowerPath.endsWith(ext));
  }

  /// 동영상 파일 여부 확인
  static bool _isVideoFile(String path) {
    final lowerPath = path.toLowerCase();
    return _videoExtensions.any((ext) => lowerPath.endsWith(ext));
  }

  /// 이미지 파일 여부 확인
  static bool _isImageFile(String path) {
    final lowerPath = path.toLowerCase();
    return _imageExtensions.any((ext) => lowerPath.endsWith(ext));
  }

  /// 외부 사용용: 녹음 파일 여부 확인
  static bool isRecordingFile(String path) => _isRecordingFile(path);

  /// 외부 사용용: 동영상 파일 여부 확인
  static bool isVideoFile(String path) => _isVideoFile(path);

  /// 외부 사용용: 이미지 파일 여부 확인
  static bool isImageFile(String path) => _isImageFile(path);

  /// External Storage 디렉토리 가져오기
  ///
  /// `/storage/emulated/0` 형태의 절대 경로 반환
  static Future<Directory?> _getExternalStorageDirectory() async {
    try {
      if (Platform.isAndroid) {
        // Android의 경우 /storage/emulated/0로 접근
        const basePathString = '/storage/emulated/0';
        final baseDir = Directory(basePathString);

        if (await baseDir.exists()) {
          return baseDir;
        } else {
          // Fallback: path_provider 사용
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            // /storage/emulated/0/Android/data/... 형태에서
            // /storage/emulated/0 추출
            final parts = externalDir.path.split('/');
            if (parts.length >= 4) {
              final basePath = '/${parts[1]}/${parts[2]}/${parts[3]}';
              return Directory(basePath);
            }
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ External Storage 경로 가져오기 실패: $e');
      return null;
    }
  }

  /// 🎁 SAF 폴더 선택 시 힌트로 제공할 초기 URI 생성
  ///
  /// 자동 감지된 경로를 content:// URI로 변환
  ///
  /// Example:
  /// ```dart
  /// final hintUri = await GalaxyPathHelper.getCallRecordingHintUri();
  /// final result = await safUtil.pickDirectory(initialUri: hintUri);
  /// ```
  static Future<Uri?> getCallRecordingHintUri() async {
    final path = await detectCallRecordingPath();
    if (path == null) return null;

    try {
      // 파일 경로를 URI로 변환
      return Uri.file(path);
    } catch (e) {
      debugPrint('⚠️ URI 변환 실패: $e');
      return null;
    }
  }

  /// 🎁 카메라 폴더 힌트 URI
  static Future<Uri?> getCameraHintUri() async {
    final path = await detectCameraPath();
    if (path == null) return null;

    try {
      return Uri.file(path);
    } catch (e) {
      debugPrint('⚠️ URI 변환 실패: $e');
      return null;
    }
  }

  /// 📊 모든 경로 상태 디버그 출력
  static Future<void> debugPrintAllPaths() async {
    debugPrint('');
    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('📱 갤럭시 경로 진단 시작');
    debugPrint('═══════════════════════════════════════════════════');

    final baseDir = await _getExternalStorageDirectory();
    debugPrint('📂 Base Directory: ${baseDir?.path}');

    debugPrint('');
    debugPrint('🎙️ 통화 녹음 경로 체크:');
    for (final path in _callRecordingPaths) {
      final fullPath = '${baseDir?.path}/$path';
      final exists = await Directory(fullPath).exists();
      debugPrint('  ${exists ? "✅" : "❌"} $fullPath');
    }

    debugPrint('');
    debugPrint('📸 카메라 경로 체크:');
    for (final path in _cameraPaths) {
      final fullPath = '${baseDir?.path}/$path';
      final exists = await Directory(fullPath).exists();
      debugPrint('  ${exists ? "✅" : "❌"} $fullPath');
    }

    debugPrint('');
    debugPrint('🎯 자동 감지 결과:');
    final callPath = await detectCallRecordingPath();
    final cameraPath = await detectCameraPath();
    debugPrint('  통화 녹음: ${callPath ?? "감지 실패"}');
    debugPrint('  카메라: ${cameraPath ?? "감지 실패"}');

    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('');
  }
}
