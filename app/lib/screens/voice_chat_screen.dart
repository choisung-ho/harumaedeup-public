// lib/screens/voice_chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sound_stream/sound_stream.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:audio_session/audio_session.dart';

import '../theme_state.dart'; // ✅ [추가] AppColors 사용

// ✅ [추가] compute 함수에서 사용할 파라미터 클래스 (Top-level)
class _VolumeParams {
  final Uint8List data;
  final double volume;
  _VolumeParams(this.data, this.volume);
}

// ✅ [추가] 별도 Isolate에서 볼륨 처리 (Top-level 함수여야 함)
Uint8List _applyVolumeIsolate(_VolumeParams params) {
  final data = params.data;
  final volume = params.volume;

  // 볼륨 100%면 원본 반환 (성능 최적화)
  if (volume >= 0.99) return data;

  final int length = data.length;
  final result = Uint8List(length);

  // PCM 16bit Little Endian 샘플 처리
  for (int i = 0; i < length - 1; i += 2) {
    // Little Endian으로 16bit 샘플 읽기
    int sample = data[i] | (data[i + 1] << 8);
    // signed 변환
    if (sample >= 32768) sample -= 65536;

    // 볼륨 적용
    sample = (sample * volume).round().clamp(-32768, 32767);

    // Little Endian으로 다시 쓰기
    result[i] = sample & 0xFF;
    result[i + 1] = (sample >> 8) & 0xFF;
  }

  return result;
}

class VoiceChatScreen extends StatefulWidget {
  const VoiceChatScreen({super.key});

  @override
  State<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends State<VoiceChatScreen>
    with SingleTickerProviderStateMixin {
  // 서버 베이스 주소 (환경 변수 지원)
  final String _serverBaseUrl = const String.fromEnvironment(
    'VOICE_CHAT_SERVER_URL',
    defaultValue: 'ws://endpoint-3.example.invalid:8000/ws/chat',
  );

  // ✅ [추가] dispose 플래그 - 앱 종료/화면 이탈 시 즉시 오디오 차단
  bool _isDisposed = false;

  WebSocketChannel? _channel;
  final RecorderStream _recorder = RecorderStream();
  final PlayerStream _player = PlayerStream();

  bool _isConnected = false;
  bool _isMicOn = false;
  bool _isInitializing = true;
  bool _isPopping = false;
  bool _isPlaying = false;
  bool _isPlayingSetOnce = false; // ✅ [추가] setState 최초 1회만 호출하기 위한 플래그

  // ✅ [추가] 오디오 청크 큐 및 배치 처리 타이머 (메인 스레드 블로킹 방지)
  final List<Uint8List> _audioQueue = [];
  Timer? _audioProcessTimer;
  static const int _audioProcessIntervalMs = 30; // 30ms 간격으로 배치 처리

  final List<Map<String, dynamic>> _messages = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription? _recorderSubscription;
  StreamSubscription? _playerSubscription;
  StreamSubscription? _channelSubscription; // ✅ WebSocket 구독 관리
  late AnimationController _pulseController;

  void _safePop() {
    if (_isPopping || !mounted) return;
    _isPopping = true;
    Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _startAudioProcessTimer(); // ✅ [추가] 오디오 배치 처리 타이머 시작
    _initApp();
  }

  // ✅ [추가] 오디오 배치 처리 타이머 시작 - 메인 스레드 블로킹 방지
  void _startAudioProcessTimer() {
    _audioProcessTimer = Timer.periodic(
      const Duration(milliseconds: _audioProcessIntervalMs),
      (_) => _processAudioQueue(),
    );
  }

  // ✅ [추가] 오디오 큐 배치 처리 - 메인 스레드 부하 분산
  void _processAudioQueue() {
    if (_isDisposed || !mounted || _audioQueue.isEmpty) return;

    try {
      // 큐에 쌓인 모든 청크를 한 번에 처리 (최대 10개씩)
      final int processCount = _audioQueue.length.clamp(0, 10);
      for (int i = 0; i < processCount; i++) {
        if (_audioQueue.isNotEmpty && !_isDisposed) {
          final chunk = _audioQueue.removeAt(0);
          _player.writeChunk(chunk);
        }
      }
    } catch (e) {
      debugPrint('⚠️ 오디오 큐 처리 오류: $e');
    }
  }

  Future<void> _initApp() async {
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showError("마이크 권한이 필요합니다.");
      if (mounted) {
        setState(() => _isInitializing = false);
      }
      return;
    }

    try {
      // ✅ [수정] 오디오 세션 - playback 모드로 변경 (미디어 볼륨 사용)
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          // iOS 설정
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          // Android 설정 - STREAM_MUSIC 강제 사용
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music, // ✅ 미디어로 변경
            usage: AndroidAudioUsage.media,
            flags: AndroidAudioFlags.none,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
        ),
      );
      await session.setActive(true);
      debugPrint('✅ AudioSession 초기화 완료 - STREAM_MUSIC(미디어 볼륨) 사용');

      await _recorder.initialize(sampleRate: 16000, showLogs: false);
      await _player.initialize(sampleRate: 24000, showLogs: false);
      await _player.start();
      _connectToServer();
    } catch (e) {
      _showError("오디오 초기화 실패: $e");
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _connectToServer() async {
    try {
      // Firebase Auth 토큰 획득
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _showError("로그인이 필요합니다.");
        if (mounted) {
          setState(() => _isInitializing = false);
        }
        return;
      }

      final token = await user.getIdToken();
      if (token == null) {
        _showError("인증 토큰을 가져올 수 없습니다.");
        if (mounted) {
          setState(() => _isInitializing = false);
        }
        return;
      }

      // WebSocket URL에 토큰 추가
      final wsUrl = '$_serverBaseUrl?token=$token';
      debugPrint('🔌 WebSocket 연결 시도: $wsUrl');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // ✅ StreamSubscription으로 관리하여 dispose 시 안전하게 취소
      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (data is String) {
            _handleTextMessage(data);
          } else if (data is List<int>) {
            // ✅ [새로운 구현] 소프트웨어 볼륨 조절 후 재생
            _playAudioWithVolume(Uint8List.fromList(data));
          }
        },
        onDone: () {
          if (mounted) {
            setState(() => _isConnected = false);
            _showError("서버와 연결이 끊어졌습니다.");
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() => _isConnected = false);
            _showError("연결 오류: $error");
          }
        },
        cancelOnError: true, // ✅ 에러 시 자동 취소
      );

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isInitializing = false;
        });
      }
      _addSystemMessage("🤖 AI 비서와 연결되었습니다.");
    } catch (e) {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
      _showError("연결 실패: $e");
    }
  }

  void _handleTextMessage(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      final type = data['type'];
      final content = data['content'] ?? '';

      switch (type) {
        case 'text':
        case 'user_transcript': // ← 현재 서버가 AI 응답을 이 타입으로 보냄
          if (content.trim().isNotEmpty) {
            _updateLastAiMessage(content);
          }
          break;

        case 'stt_result': // ← 추후 서버에서 실제 STT 결과를 보낼 때 사용
          if (content.trim().isNotEmpty) {
            _addUserMessage(content);
          }
          break;

        case 'text_end':
          debugPrint('✅ AI 응답 완료');
          break;

        case 'error':
          final message = data['message'] ?? '알 수 없는 오류';
          _showError(message);
          break;

        case 'status':
          final text = data['text'] ?? '';
          _addSystemMessage(text);
          break;

        default:
          debugPrint('⚠️ 알 수 없는 메시지 타입: $type');
      }
    } catch (e) {
      debugPrint('❌ JSON 파싱 실패: $e');
      _showError("서버 응답 파싱 실패");
    }
  }

  // ✨ [추가] 사용자 메시지 추가 함수
  void _addUserMessage(String text) {
    if (!mounted || text.trim().isEmpty) return;
    setState(() {
      _messages.add({
        'role': 'user',
        'text': text,
        'timestamp': DateTime.now(),
      });
    });
    _scrollToBottom();
  }

  // ✅ [수정] 오디오 재생 - 이제 시스템 볼륨(미디어)으로 조절됨
  // sound_stream 포크 버전이 STREAM_MUSIC을 사용하므로 소프트웨어 볼륨 처리 불필요
  void _playAudioWithVolume(Uint8List audioData) {
    // ✅ [핵심 수정] dispose 또는 unmounted 상태면 즉시 반환
    if (_isDisposed || !mounted) return;

    // ✅ [핵심 수정] setState는 최초 1회만 호출 (UI 프리징 방지)
    if (!_isPlayingSetOnce && !_isPlaying && mounted && !_isDisposed) {
      _isPlayingSetOnce = true;
      setState(() => _isPlaying = true);
    }

    // ✅ [핵심 변경] 메인 스레드에서 직접 처리하지 않고 큐에 추가만
    // 실제 처리는 _processAudioQueue()에서 배치로 수행 (30ms 간격)
    // 이렇게 하면 UI 이벤트 루프가 블로킹되지 않음
    _audioQueue.add(audioData);
  }

  // ✅ [유지] 동기 볼륨 처리 (필요시 사용 가능)
  Uint8List _applyVolumeSync(Uint8List data, double volume) {
    // 볼륨 100%면 원본 반환 (성능 최적화)
    if (volume >= 0.99) return data;

    final int length = data.length;
    final result = Uint8List(length);

    // PCM 16bit Little Endian 샘플 처리
    for (int i = 0; i < length - 1; i += 2) {
      // Little Endian으로 16bit 샘플 읽기
      int sample = data[i] | (data[i + 1] << 8);
      // signed 변환
      if (sample >= 32768) sample -= 65536;

      // 볼륨 적용
      sample = (sample * volume).round().clamp(-32768, 32767);

      // Little Endian으로 다시 쓰기
      result[i] = sample & 0xFF;
      result[i + 1] = (sample >> 8) & 0xFF;
    }

    return result;
  }

  Future<void> _toggleMic() async {
    // ✅ [추가] dispose 상태면 무시
    if (_isDisposed) return;

    if (!_isConnected) {
      _showError("서버에 연결되지 않았습니다.");
      return;
    }

    if (_isMicOn) {
      // ✅ 1. UI 상태 먼저 변경 (중복 클릭 방지)
      if (mounted) {
        setState(() {
          _isMicOn = false;
          _isPlaying = false; // ✅ [추가] 재생 상태도 초기화
        });
      }

      // ✅ 2. 마이크 정리
      await _recorderSubscription?.cancel();
      _recorderSubscription = null;
      await _recorder.stop();

      // ✅ 3. [핵심 추가] AI 음성 즉시 정지
      _audioQueue.clear(); // 대기 중인 오디오 청크 모두 제거
      await _player.stop(); // 현재 재생 중인 오디오 정지
      await _player.start(); // 다음 재생을 위해 다시 시작 (초기화)
      _isPlayingSetOnce = false; // setState 플래그 리셋

      debugPrint('🛑 마이크 OFF → AI 음성 즉시 정지');

      // ✅ 4. 녹음 종료 시 commit 메시지 전송
      // 이 신호가 없으면 Gemini가 사용자 발화 종료를 알 수 없음
      if (_isConnected && _channel != null) {
        try {
          _channel!.sink.add(jsonEncode({'type': 'commit'}));
          debugPrint('📤 commit 신호 전송 완료');
        } catch (e) {
          debugPrint('⚠️ commit 전송 실패: $e');
        }
      }

      if (mounted) {
        _addSystemMessage("🔇 마이크 꺼짐");
      }
    } else {
      // ✅ 1. UI 상태 먼저 변경
      if (mounted) {
        setState(() => _isMicOn = true);
      }
      // 2. 리소스 시작
      try {
        _recorderSubscription = _recorder.audioStream.listen(
          (data) {
            if (_isConnected && _channel != null) {
              _channel!.sink.add(data);
            }
          },
          onError: (e) {
            debugPrint('❌ 마이크 스트림 에러: $e');
            if (mounted) {
              setState(() => _isMicOn = false);
              _showError("마이크 오류: $e");
            }
          },
          cancelOnError: true,
        );
        await _recorder.start();
        if (mounted) {
          _addSystemMessage("🎤 듣고 있어요...");
        }
      } catch (e) {
        debugPrint('❌ 마이크 시작 실패: $e');
        if (mounted) {
          setState(() => _isMicOn = false);
          _showError("마이크 시작 실패: $e");
        }
      }
    }
  }

  void _addSystemMessage(String text) {
    if (!mounted) return;
    setState(() {
      _messages.add({
        'role': 'system',
        'text': text,
        'timestamp': DateTime.now(),
      });
    });
    _scrollToBottom();
  }

  void _updateLastAiMessage(String chunk) {
    if (!mounted) return;
    setState(() {
      if (_messages.isNotEmpty && _messages.last['role'] == 'ai') {
        _messages.last['text'] += chunk;
      } else {
        _messages.add({
          'role': 'ai',
          'text': chunk,
          'timestamp': DateTime.now(),
        });
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String msg) {
    if (!mounted) return;

    // 사용자 친화적인 에러 메시지로 변환
    String userFriendlyMsg = _getUserFriendlyErrorMessage(msg);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                userFriendlyMsg,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF5C6BC0), // 부드러운 인디고 색상
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 기술적인 에러 메시지를 사용자 친화적인 한국어로 변환
  String _getUserFriendlyErrorMessage(String rawError) {
    final lowerError = rawError.toLowerCase();

    // WebSocket 관련 에러
    if (lowerError.contains('websocketchannelexception') ||
        lowerError.contains('websocket')) {
      return '서버 연결이 일시적으로 불안정합니다.\n잠시 후 다시 시도해 주세요.';
    }

    // 연결 관련 에러
    if (lowerError.contains('connection') ||
        lowerError.contains('연결') ||
        lowerError.contains('socket')) {
      return '인터넷 연결을 확인해 주세요.';
    }

    // 타임아웃 에러
    if (lowerError.contains('timeout') || lowerError.contains('timed out')) {
      return '응답 시간이 초과되었습니다.\n다시 시도해 주세요.';
    }

    // 인증 에러
    if (lowerError.contains('auth') ||
        lowerError.contains('token') ||
        lowerError.contains('인증')) {
      return '로그인이 필요합니다.';
    }

    // 서버 에러
    if (lowerError.contains('500') ||
        lowerError.contains('server') ||
        lowerError.contains('서버')) {
      return '서버에 일시적인 문제가 발생했습니다.\n잠시 후 다시 시도해 주세요.';
    }

    // 네트워크 에러
    if (lowerError.contains('network') ||
        lowerError.contains('internet') ||
        lowerError.contains('네트워크')) {
      return '네트워크 연결을 확인해 주세요.';
    }

    // 파싱 에러
    if (lowerError.contains('parse') || lowerError.contains('파싱')) {
      return '데이터 처리 중 문제가 발생했습니다.';
    }

    // 마이크 관련
    if (lowerError.contains('마이크') || lowerError.contains('microphone')) {
      return rawError; // 마이크 관련은 원본 메시지 유지
    }

    // 이미 한국어로 된 친화적 메시지는 그대로 사용
    if (_isUserFriendlyMessage(rawError)) {
      return rawError;
    }

    // 기타 알 수 없는 에러
    return '일시적인 오류가 발생했습니다.\n다시 시도해 주세요.';
  }

  /// 이미 사용자 친화적인 메시지인지 확인
  bool _isUserFriendlyMessage(String msg) {
    // 기술적 용어가 포함되지 않은 짧은 한국어 메시지
    final technicalTerms = [
      'exception',
      'error:',
      'failed',
      'null',
      'socket',
      'channel',
      'stream',
      'async',
      'future',
      'stacktrace',
    ];

    final lowerMsg = msg.toLowerCase();
    for (final term in technicalTerms) {
      if (lowerMsg.contains(term)) return false;
    }

    // 한글이 포함되어 있고 너무 길지 않으면 친화적 메시지로 간주
    return RegExp(r'[\uac00-\ud7af]').hasMatch(msg) && msg.length < 50;
  }

  @override
  void dispose() {
    // ✅ [핵심 수정] 즉시 플래그 설정 - 이후 모든 오디오 작업 차단
    _isDisposed = true;

    // ✅ [추가] 타이머 먼저 취소 - 새로운 오디오 처리 방지
    _audioProcessTimer?.cancel();
    _audioProcessTimer = null;

    // ✅ [추가] 오디오 큐 즉시 클리어 - 잔여 오디오 제거
    _audioQueue.clear();

    // ✅ [수정] dispose는 절대 async로 선언하면 안 됨!
    // 비동기 작업은 별도 함수로 분리하여 호출
    _cleanupResources();

    // ✅ 동기적으로 dispose 가능한 것들 먼저 처리
    _pulseController.dispose();
    _scrollController.dispose();

    // ✅ 반드시 super.dispose() 호출
    super.dispose();
  }

  // ✅ [새로운] 비동기 리소스 정리 (dispose에서 호출)
  void _cleanupResources() {
    debugPrint('🧹 리소스 정리 시작...');

    // ✅ [핵심] 1. 타이머 취소 (이미 dispose에서 했지만 안전하게 다시)
    _audioProcessTimer?.cancel();
    _audioProcessTimer = null;

    // ✅ [핵심] 2. 오디오 큐 클리어
    _audioQueue.clear();

    // ✅ [핵심] 3. 구독 먼저 취소하여 새로운 데이터 유입 차단
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _playerSubscription?.cancel();
    _playerSubscription = null;

    // ✅ [핵심] 4. 리소스 정리 - 순서 중요: player 먼저 멈춰야 음성 즉시 중단
    _player.stop().catchError((e) => debugPrint('⚠️ Player stop: $e'));
    _recorder.stop().catchError((e) => debugPrint('⚠️ Recorder stop: $e'));
    _channel?.sink.close().catchError(
      (e) => debugPrint('⚠️ WebSocket close: $e'),
    );
    _channel = null;

    debugPrint('✅ 리소스 정리 완료');
  }

  // ✅ [추가] 화면 이탈 전 오디오 정지 함수
  Future<void> _stopAllAudioAndPop() async {
    if (_isPopping || _isDisposed) return;
    _isPopping = true;
    _isDisposed = true; // 즉시 오디오 차단

    debugPrint('🛑 오디오 정지 시작...');

    try {
      // ✅ [핵심] 1. 타이머 먼저 취소 - 새로운 오디오 처리 방지
      _audioProcessTimer?.cancel();
      _audioProcessTimer = null;

      // ✅ [핵심] 2. 오디오 큐 즉시 클리어 - 잔여 오디오 제거
      _audioQueue.clear();

      // ✅ [핵심] 3. 구독 즉시 취소 - 새로운 데이터 유입 차단
      _channelSubscription?.cancel();
      _channelSubscription = null;
      _recorderSubscription?.cancel();
      _recorderSubscription = null;

      // ✅ [핵심] 4. 오디오 즉시 정지 (await로 완료 대기)
      await _player.stop();
      await _recorder.stop();

      // ✅ [핵심] 5. WebSocket 닫기
      _channel?.sink.close();
      _channel = null;

      debugPrint('✅ 오디오 정지 완료');
    } catch (e) {
      debugPrint('⚠️ 오디오 정지 오류: $e');
    }

    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // ✅ [추가] PopScope로 시스템 뒤로가기 버튼 처리
    return PopScope(
      canPop: false, // 직접 처리
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _stopAllAudioAndPop();
      },
      child: Scaffold(
        // ✅ [개선] AppColors 사용 - 네이비 다크 테마
        backgroundColor: isDark
            ? AppColors.darkBackground
            : const Color(0xFFF8F9FD),
        appBar: AppBar(
          // ✅ [추가] 커스텀 뒤로가기 버튼 - 오디오 정지 후 pop
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios,
              color: isDark ? Colors.white : Colors.black87,
            ),
            onPressed: _stopAllAudioAndPop,
          ),
          elevation: 0,
          // ✅ [개선] AppColors 사용 - 네이비 다크 테마
          backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.psychology,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              // ✅ [수정] Flexible로 감싸서 오버플로우 방지
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      'AI 음성 비서',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '실시간 대화',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _isConnected
                    ? Colors.green.withOpacity(0.1)
                    : Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isConnected ? Colors.green : Colors.red,
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _isConnected ? Colors.green : Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isConnected ? '연결됨' : '연결 끊김',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _isConnected ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        body: _isInitializing
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '초기화 중...',
                      style: TextStyle(
                        fontSize: 16,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: _messages.isEmpty
                        ? _buildEmptyState(isDark)
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final msg = _messages[index];
                              return _buildMessageBubble(msg, isDark);
                            },
                          ),
                  ),
                  _buildControlPanel(isDark),
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF667EEA).withOpacity(0.3),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const Icon(Icons.mic_none, size: 64, color: Colors.white),
          ),
          const SizedBox(height: 32),
          Text(
            '마이크 버튼을 눌러\n대화를 시작하세요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '실시간으로 음성을 주고받습니다',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        // ✅ [개선] AppColors 사용 - 네이비 다크 테마
        color: isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.3 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: _isMicOn
                  ? const Color(0xFFE53935).withOpacity(0.1)
                  : const Color(0xFF667EEA).withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isMicOn ? Icons.graphic_eq : Icons.mic_off,
                  color: _isMicOn
                      ? const Color(0xFFE53935)
                      : const Color(0xFF667EEA),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _isMicOn ? '말씀해 주세요...' : '마이크 버튼을 눌러 시작',
                  style: TextStyle(
                    color: _isMicOn
                        ? const Color(0xFFE53935)
                        : const Color(0xFF667EEA),
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _toggleMic,
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  height: 88,
                  width: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _isMicOn
                        ? const LinearGradient(
                            colors: [Color(0xFFE53935), Color(0xFFC62828)],
                          )
                        : const LinearGradient(
                            colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                          ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_isMicOn
                                    ? const Color(0xFFE53935)
                                    : const Color(0xFF667EEA))
                                .withOpacity(
                                  _isMicOn
                                      ? 0.4 + (_pulseController.value * 0.3)
                                      : 0.3,
                                ),
                        blurRadius:
                            20 + (_isMicOn ? _pulseController.value * 15 : 0),
                        spreadRadius:
                            5 + (_isMicOn ? _pulseController.value * 8 : 0),
                      ),
                    ],
                  ),
                  child: Icon(
                    _isMicOn ? Icons.stop_rounded : Icons.mic,
                    color: Colors.white,
                    size: 44,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg, bool isDark) {
    final role = msg['role'];
    final isSystem = role == 'system';
    final isAi = role == 'ai';
    final isUser = role == 'user'; // ✨ [추가] 사용자 메시지 구분
    final timestamp = msg['timestamp'] as DateTime?;

    if (isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withOpacity(0.05)
                : Colors.black.withOpacity(0.04),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  msg['text'],
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: isAi ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment: isAi
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            // ✨ [추가] 역할 라벨 표시
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isAi ? Icons.smart_toy : Icons.person,
                    size: 14,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isAi ? 'AI 비서' : '나',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                // ✨ [수정] 사용자 메시지는 보라색 그라데이션
                gradient: isUser
                    ? const LinearGradient(
                        colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                      )
                    : null,
                // ✅ [개선] AppColors 사용 - 네이비 다크 테마
                color: isAi
                    ? (isDark ? AppColors.darkSurface : Colors.white)
                    : null,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: isAi
                      ? const Radius.circular(4)
                      : const Radius.circular(20),
                  bottomRight: isAi
                      ? const Radius.circular(20)
                      : const Radius.circular(4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.2 : 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Text(
                msg['text'],
                style: TextStyle(
                  fontSize: 16,
                  color: isAi
                      ? (isDark ? Colors.white : Colors.black87)
                      : Colors.white,
                  height: 1.5,
                ),
              ),
            ),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                child: Text(
                  DateFormat('HH:mm').format(timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
