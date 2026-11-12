// lib/services/wake_word_manager.dart
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';

class WakeWordManager {
  final String accessKey =
      const String.fromEnvironment('PORCUPINE_ACCESS_KEY');

  PorcupineManager? _porcupineManager;
  final Function() onWakeWordDetected; // 감지 시 실행할 콜백
  bool isListening = false;

  WakeWordManager({required this.onWakeWordDetected});

  // 초기화 함수
  Future<void> init() async {
    try {
      // [수정] 파일 경로 대신 내장된 'Jarvis' 키워드 사용
      _porcupineManager = await PorcupineManager.fromBuiltInKeywords(
        accessKey,
        [BuiltInKeyword.JARVIS], // 👈 여기가 핵심 변경 사항!
        (int keywordIndex) {
          // 감지되면 콜백 실행
          onWakeWordDetected();
        },
        errorCallback: _onError,
      );

      print("🦔 웨이크 워드 엔진 준비 완료 (호출어: Jarvis)");
      // 초기화 직후 바로 듣기 시작
      await startListening();
    } on PorcupineException catch (err) {
      print("❌ 웨이크 워드 초기화 에러: ${err.message}");
    } catch (e) {
      print("❌ 기타 에러: $e");
    }
  }

  // 듣기 시작 (마이크 점유)
  Future<void> startListening() async {
    try {
      if (_porcupineManager != null && !isListening) {
        await _porcupineManager!.start();
        isListening = true;
        print("👂 [WakeWord] Jarvis를 기다리는 중...");
      }
    } catch (e) {
      print("❌ WakeWord 시작 실패: $e");
    }
  }

  // 듣기 중지 (STT 마이크 사용을 위해 필수)
  Future<void> stopListening() async {
    try {
      if (_porcupineManager != null && isListening) {
        await _porcupineManager!.stop();
        isListening = false;
        print("zzZ [WakeWord] 대기 모드 (마이크 해제)");
      }
    } catch (e) {
      print("❌ WakeWord 중지 실패: $e");
    }
  }

  void _onError(PorcupineException error) {
    print("❌ WakeWord 에러 발생: ${error.message}");
  }

  Future<void> dispose() async {
    if (_porcupineManager != null) {
      await _porcupineManager!.stop();
      await _porcupineManager!.delete();
    }
  }
}
