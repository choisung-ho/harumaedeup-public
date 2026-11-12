// lib/screens/storytelling_screen.dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../utils/crypto_utils.dart';
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class StorytellingScreen extends StatefulWidget {
  const StorytellingScreen({
    super.key,
    required this.seniorId, // ✅ 필수 값으로 변경
    required this.date, // ✅ 필수 값으로 변경
    required this.collection,
  });

  final String seniorId;
  final String date;
  final String collection;

  @override
  State<StorytellingScreen> createState() => _StorytellingScreenState();
}

class _StorytellingScreenState extends State<StorytellingScreen>
    with TickerProviderStateMixin {
  // ========== 색상 상수 (다크모드) ==========
  static const _deepNavyDark = Color(0xFF1A1F3C);
  static const _warmCreamDark = Color(0xFFFFF8F0);
  static const _softPeachDark = Color(0xFFFFE4D6);
  static const _pastelPinkDark = Color(0xFFFFD6E0);
  static const _pastelMintDark = Color(0xFFD4F0E7);
  static const _pastelLavenderDark = Color(0xFFE8DFF5);
  static const _glassWhiteDark = Color(0x1AFFFFFF);
  static const _glassBorderDark = Color(0x4DFFFFFF);

  // ========== 색상 상수 (라이트모드) - 완전 재설계 ==========
  static const _deepNavyLight = Color(0xFFFAFAFA); // 밝은 배경 (거의 흰색)
  static const _warmCreamLight = Color(0xFF3D3D3D); // 어두운 텍스트
  static const _softPeachLight = Color(0xFFE8A87C); // 부드러운 복숭아색
  static const _pastelPinkLight = Color(0xFFE8B4BC); // 파스텔 핑크
  static const _pastelMintLight = Color(0xFF85C9B8); // 파스텔 민트
  static const _pastelLavenderLight = Color(0xFFB8A9C9); // 파스텔 라벤더
  static const _glassWhiteLight = Color(0xFFF5F5F5); // 밝은 유리 효과
  static const _glassBorderLight = Color(0xFFE0E0E0); // 밝은 테두리

  // 테마 기반 색상 getter
  Color get _deepNavy => _isDarkMode ? _deepNavyDark : _deepNavyLight;
  Color get _warmCream => _isDarkMode ? _warmCreamDark : _warmCreamLight;
  Color get _softPeach => _isDarkMode ? _softPeachDark : _softPeachLight;
  Color get _pastelPink => _isDarkMode ? _pastelPinkDark : _pastelPinkLight;
  Color get _pastelMint => _isDarkMode ? _pastelMintDark : _pastelMintLight;
  Color get _pastelLavender =>
      _isDarkMode ? _pastelLavenderDark : _pastelLavenderLight;
  Color get _glassWhite => _isDarkMode ? _glassWhiteDark : _glassWhiteLight;
  Color get _glassBorder => _isDarkMode ? _glassBorderDark : _glassBorderLight;

  // 다크모드 상태 (build에서 설정)
  bool _isDarkMode = true;

  // ========== 상태 변수 ==========
  bool _loading = true;
  String _loadingStatus = '추억을 불러오는 중...';

  // ✅ [수정] 복잡한 게터 삭제 및 단순화
  // 이제 코드 밑에서 widget.date, widget.seniorId를 직접 쓰면 돼.
  String get _storyDocId => widget.date;
  // _overrideUserId는 삭제함 (필요 없음)

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _effectPlayer = AudioPlayer(); // Call audio playback
  final PageController _pageController = PageController();
  final Map<int, VideoPlayerController> _videoControllers = {};

  List<Map<String, dynamic>> _cueSheet = [];
  List<List<int>> _pageGroups = []; // 각 페이지에 속한 cue 인덱스들
  String? _rawScript; // 태그 포함 원본 스크립트
  String? _cleanScript;
  Duration? _audioDuration;
  int _currentPage = 0;
  // _isPlaying 제거됨 - StreamBuilder<PlayerState>로 대체
  bool _isPlayingCallAudio = false; // Call audio playback state
  bool _isPageAnimating = false; // 페이지 애니메이션 가드
  Set<int> _playedCallAudioPages = {}; // 이미 재생한 call audio 페이지 추적

  late AnimationController _pulseController;
  late AnimationController _kenBurnsController;

  // 스트림 구독 관리
  var _positionSubscription;
  var _durationSubscription;
  var _playerStateSubscription;

  @override
  void initState() {
    super.initState();
    // 더 유기적인 "숨쉬는" 효과를 위한 느린 펄스
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);

    // Ken Burns 효과용 컨트롤러 (느린 줌/패닝)
    _kenBurnsController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat(reverse: true);

    _fetchStoryData();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _pulseController.dispose();
    _kenBurnsController.dispose();
    _audioPlayer.dispose();
    _effectPlayer.dispose();
    _pageController.dispose();
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _cueSheet = [];
    _pageGroups = [];
    _cleanScript = null;
    super.dispose();
  }

  // ========== 데이터 불러오기 ==========
  Future<void> _fetchStoryData() async {
    try {
      // ✅ [수정] 외부에서 받은 seniorId를 바로 사용
      final String uid = widget.seniorId;

      final docSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection(widget.collection) // diary
          .doc(widget.date)
          .get();

      if (!docSnap.exists) throw Exception('데이터가 없습니다');

      final data = docSnap.data()!;

      final scriptRaw = data['story_script']?.toString() ?? '';
      debugPrint('🔐 [복호화] story_script 길이: ${scriptRaw.length}');
      if (scriptRaw.isNotEmpty) {
        final preview = scriptRaw.substring(
          0,
          scriptRaw.length > 100 ? 100 : scriptRaw.length,
        );
        debugPrint('🔐 [복호화] story_script 앞 100글자: $preview');
      }

      final rawScript = _decryptString(data['story_script']) ?? '';
      if (rawScript.isNotEmpty) {
        final preview = rawScript.substring(
          0,
          rawScript.length > 100 ? 100 : rawScript.length,
        );
        debugPrint('🔓 [복호화] rawScript 결과: $preview...');
      }

      final ttsUrl = _decryptString(data['tts_url']) ?? '';

      final cueSheetRaw = _decryptValue(data['cue_sheet']);
      var cueSheet = _normalizeCueSheet(cueSheetRaw);

      // 디버그: cue_sheet 복호화 확인
      debugPrint('📋 [스토리텔링] cue_sheet 개수: ${cueSheet.length}');
      if (cueSheet.isNotEmpty) {
        final firstCue = cueSheet[0];
        debugPrint(
          '📋 [스토리텔링] 첫 번째 cue: type=${firstCue['type']}, text=${firstCue['text']?.toString().substring(0, 50)}...',
        );
      }

      // 스크립트에서 태그 제거
      final cleanScript = rawScript.replaceAll(RegExp(r'<[^>]+>'), '');
      debugPrint(
        '📜 [스토리텔링] cleanScript: ${cleanScript.substring(0, cleanScript.length > 100 ? 100 : cleanScript.length)}...',
      );

      if (cueSheet.isEmpty && cleanScript.isNotEmpty) {
        cueSheet = [
          {'type': 'greeting', 'text': cleanScript, 'time_seconds': 0},
        ];
        debugPrint('⚠️ [스토리텔링] cue_sheet가 비어있어 cleanScript로 대체');
      }

      // 페이지 그룹화
      final pageGroups = _groupCuesIntoPages(cueSheet);

      if (mounted) {
        setState(() {
          _cueSheet = cueSheet;
          _rawScript = rawScript;
          _cleanScript = cleanScript;
          _pageGroups = pageGroups;
          _loading = false;
        });
      }

      // TTS 설정
      final downloadUrl = await _getFirebaseDownloadUrl(ttsUrl);
      if (downloadUrl != null) {
        await _audioPlayer.setUrl(downloadUrl);

        // 어르신 대상: 0.85배속으로 천천히 재생
        await _audioPlayer.setSpeed(0.85);

        // 처음부터 시작하도록 초기화
        await _audioPlayer.seek(Duration.zero);

        // 페이지 컨트롤러도 초기화
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
        }

        // ========== CRITICAL: Duration 먼저 설정 (페이지 전환에 필수) ==========
        // durationStream 구독을 먼저 설정
        _durationSubscription = _audioPlayer.durationStream.listen((dur) {
          if (mounted && dur != null) {
            debugPrint('🎵 [Duration] 설정됨: ${dur.inSeconds}초');
            setState(() => _audioDuration = dur);
          }
        });

        // duration 직접 가져와서 초기값 설정 (스트림 이벤트 놓치는 경우 대비)
        final initialDuration = _audioPlayer.duration;
        if (initialDuration != null && mounted) {
          debugPrint('🎵 [Duration] 초기값 설정: ${initialDuration.inSeconds}초');
          setState(() => _audioDuration = initialDuration);
        }

        // ========== FIX: 스트림 구독을 재생 전에 먼저 설정 ==========
        // positionStream 구독 (재생 전에 설정해야 자동 재생 시에도 동기화 작동)
        _positionSubscription = _audioPlayer.positionStream.listen((pos) {
          if (!mounted) return;
          // 오디오 싱크는 비동기로 처리하여 UI 블로킹 방지
          Future.microtask(() => _syncPageWithAudio(pos));
        });

        _playerStateSubscription = _audioPlayer.playerStateStream.listen((
          state,
        ) {
          // StreamBuilder가 UI 업데이트를 담당하므로 여기서는 로깅만
          debugPrint(
            '🎵 [PlayerState] playing=${state.playing}, processingState=${state.processingState}',
          );
        });

        // 스트림 구독이 완전히 설정될 때까지 짧은 딜레이
        await Future.delayed(const Duration(milliseconds: 100));

        // ========== AUTO-PLAY: 모든 스트림 구독 완료 후 자동 재생 ==========
        if (mounted) {
          setState(() {
            _currentPage = 0;
          });
        }

        debugPrint('🎵 [자동재생] 스트림 구독 완료 - TTS 재생 시작');
        await _audioPlayer.play();

        // 재생 시작 후 추가 안정화 시간
        await Future.delayed(const Duration(milliseconds: 50));
        debugPrint('✅ [자동재생] 완료 - 페이지 동기화 활성화됨');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingStatus = '오류: $e';
        });
      }
    }
  }

  String? _decryptString(dynamic value) {
    if (value == null) {
      debugPrint('⚠️ [복호화] value가 null');
      return null;
    }
    if (value is! String) {
      debugPrint('⚠️ [복호화] value가 String이 아님: ${value.runtimeType}');
      return value.toString();
    }
    if (!_looksEncrypted(value)) {
      debugPrint('✅ [복호화] 암호문이 아님 - 그대로 반환');
      return value;
    }

    debugPrint('🔑 [복호화] 암호문 감지 - 복호화 시도: ${value.substring(0, 50)}...');

    try {
      final decrypted = CryptoUtils.decrypt(value);
      if (decrypted == null) {
        debugPrint('❌ [복호화] 실패: decrypted == null');
        return null;
      }
      if (decrypted is String && decrypted == '내용을 불러올 수 없습니다.') {
        debugPrint('❌ [복호화] 실패: 에러 메시지 반환');
        return null;
      }
      if (decrypted is String) {
        debugPrint(
          '✅ [복호화] 성공: ${decrypted.substring(0, decrypted.length > 100 ? 100 : decrypted.length)}...',
        );
        return decrypted;
      }
      debugPrint(
        '✅ [복호화] 성공 (toString): ${decrypted.toString().substring(0, 50)}...',
      );
      return decrypted.toString();
    } catch (e) {
      debugPrint('🔥 [복호화] 예외 발생: $e');
      return null;
    }
  }

  dynamic _decryptValue(dynamic value) {
    if (value is String) {
      if (!_looksEncrypted(value)) return value;
      final decrypted = CryptoUtils.decrypt(value);
      if (decrypted == null) return null;
      if (decrypted is String && decrypted == '내용을 불러올 수 없습니다.') {
        return null;
      }
      return decrypted;
    }
    if (value is List) {
      return value.map(_decryptValue).toList();
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key, _decryptValue(val)));
    }
    return value;
  }

  bool _looksEncrypted(String value) {
    final trimmed = value.trim();
    if (trimmed.length < 40) return false;
    if (!trimmed.startsWith('gAAAA')) return false;

    // 개행 제거 후 첫 100자만 체크 (긴 암호문 대응)
    final sample = trimmed.replaceAll('\n', '').replaceAll('\r', '');
    final checkLen = sample.length > 100 ? 100 : sample.length;
    final sampleStr = sample.substring(0, checkLen);

    final base64UrlExp = RegExp(r'^[A-Za-z0-9_-]+$');
    final isEncrypted = base64UrlExp.hasMatch(sampleStr);

    debugPrint(
      '🔍 [암호문 체크] startsWith(gAAAA)=true, regex=$isEncrypted, length=${trimmed.length}',
    );
    return isEncrypted;
  }

  List<Map<String, dynamic>> _normalizeCueSheet(dynamic raw) {
    if (raw is String) {
      final decoded = _tryDecodeJson(raw);
      if (decoded is List) {
        return decoded.map((e) => _normalizeCue(_toCueMap(e))).toList();
      }
    }
    if (raw is List) {
      return raw.map((e) => _normalizeCue(_toCueMap(e))).toList();
    }
    return [];
  }

  Map<String, dynamic> _toCueMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is String) {
      final decoded = _tryDecodeJson(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    }
    return <String, dynamic>{};
  }

  dynamic _tryDecodeJson(String value) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return value;
    }
  }

  Map<String, dynamic> _normalizeCue(Map<String, dynamic> cue) {
    final normalized = <String, dynamic>{};
    cue.forEach((key, value) {
      final decrypted = _decryptValue(value);
      normalized[key] = decrypted;
    });

    // text 필드 추가 복호화 시도 (중요!)
    if (normalized['text'] != null) {
      final textValue = normalized['text'];
      if (textValue is String && _looksEncrypted(textValue)) {
        final decryptedText = CryptoUtils.decrypt(textValue);
        if (decryptedText != null && decryptedText is String) {
          normalized['text'] = decryptedText;
          debugPrint(
            '✅ [복호화] text 필드 재복호화 성공: ${decryptedText.substring(0, decryptedText.length > 30 ? 30 : decryptedText.length)}...',
          );
        }
      }
    }

    final timeValue = normalized['time_seconds'];
    if (timeValue is String) {
      normalized['time_seconds'] = double.tryParse(timeValue) ?? 0.0;
    }

    return normalized;
  }

  // ========== Cue 그룹화 로직 ==========
  List<List<int>> _groupCuesIntoPages(List<Map<String, dynamic>> cues) {
    // 같은 타입의 연속된 cue를 하나의 페이지로 그룹화
    final List<List<int>> pages = [];
    if (cues.isEmpty) return pages;

    List<int> currentGroup = [0];
    String? currentType = cues[0]['type'];

    for (int i = 1; i < cues.length; i++) {
      final cueType = cues[i]['type'];

      // 같은 타입이면 현재 그룹에 추가
      if (cueType == currentType) {
        currentGroup.add(i);
      } else {
        // 타입이 다르면 현재 그룹을 완료하고 새 그룹 시작
        pages.add(List.from(currentGroup));
        currentGroup = [i];
        currentType = cueType;
      }
    }

    // 마지막 그룹 추가
    if (currentGroup.isNotEmpty) {
      pages.add(currentGroup);
    }

    debugPrint('📄 [페이지 그룹화] 총 ${pages.length}개 페이지 생성 (${cues.length}개 cue)');
    return pages;
  }

  // ========== 오디오 싱크 ==========
  // REFACTORED: 애니메이션 가드 + Call Audio 블로킹 + Duration 체크 강화
  void _syncPageWithAudio(Duration position) async {
    // Guard 1: 기본 조건 체크
    if (!mounted || _pageGroups.isEmpty) return;

    // Guard 2: Call Audio 재생 중이면 페이지 전환/텍스트 업데이트 차단
    if (_isPlayingCallAudio) {
      return; // 로그 제거 (너무 많이 출력됨)
    }

    // Guard 3: 페이지 애니메이션 진행 중이면 중복 호출 방지
    if (_isPageAnimating) {
      return;
    }

    final currentSeconds = position.inMilliseconds / 1000.0;

    // ========== CRITICAL: Duration 체크 강화 ==========
    // duration이 아직 설정되지 않았으면 직접 가져오기 시도
    Duration? effectiveDuration = _audioDuration;
    if (effectiveDuration == null || effectiveDuration.inMilliseconds == 0) {
      effectiveDuration = _audioPlayer.duration;
      if (effectiveDuration != null && mounted) {
        // 상태 업데이트 (다음 싱크에서 사용)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _audioDuration = effectiveDuration);
        });
      }
    }
    final totalDuration = (effectiveDuration?.inMilliseconds ?? 0) / 1000.0;

    if (_currentPage >= _pageGroups.length) return;

    final currentPageCues = _pageGroups[_currentPage];
    if (currentPageCues.isEmpty) return;

    final currentCue = _cueSheet[currentPageCues.first];
    final cueType = currentCue['type'];

    // 현재 페이지의 종료 시간 계산 (다음 페이지 시작 시간)
    final double pageEndTime;
    if (_currentPage + 1 < _pageGroups.length) {
      final nextPageFirstCue = _pageGroups[_currentPage + 1].first;
      pageEndTime =
          (_cueSheet[nextPageFirstCue]['time_seconds'] as num?)?.toDouble() ??
          (currentSeconds + 10.0);
    } else {
      // 마지막 페이지: totalDuration 사용, 없으면 cue 기반 추정
      if (totalDuration > 0) {
        pageEndTime = totalDuration;
      } else {
        // duration 없을 때 fallback: 현재 cue 시작 + 30초 (충분한 버퍼)
        final cueStartTime =
            (currentCue['time_seconds'] as num?)?.toDouble() ?? 0.0;
        pageEndTime = cueStartTime + 30.0;
      }
    }

    // ========== CRITICAL: Call Audio 로직 수정 ==========
    // 통화 타입일 때: TTS 대본이 끝나는 시점(pageEndTime 직전)에 통화 녹음 재생
    // 즉, TTS가 "오늘은 이런 통화를 하셨네요!" 를 다 읽은 후 통화 녹음 재생
    if (cueType == 'call' && !_playedCallAudioPages.contains(_currentPage)) {
      // 통화 녹음 재생 시점: 현재 페이지 종료 1초 전 ~ 종료 시점
      final callAudioTriggerTime = pageEndTime - 1.0;
      if (currentSeconds >= callAudioTriggerTime &&
          currentSeconds < pageEndTime + 0.5) {
        debugPrint(
          '📞 [Call Audio] TTS 대본 완료 - 통화 녹음 재생 시작 (time: ${currentSeconds.toStringAsFixed(1)}s)',
        );
        _playedCallAudioPages.add(_currentPage);
        // 통화 녹음 재생 (페이지 전환은 통화 녹음 완료 후)
        _playCallAudioIntercept(currentCue);
        return;
      }
    }

    // ========== 페이지 전환 조건 ==========
    // 통화 타입이 아닌 경우에만 자동 페이지 전환
    // (통화 타입은 _playCallAudioIntercept 완료 후 페이지 전환)
    if (cueType != 'call' || _playedCallAudioPages.contains(_currentPage)) {
      // 일반 페이지: 0.3초 버퍼로 다음 페이지 전환
      if (currentSeconds >= pageEndTime - 0.3) {
        if (_currentPage + 1 < _pageGroups.length) {
          await _animateToPage(_currentPage + 1, currentSeconds, pageEndTime);
        }
      }
    }
  }

  // 페이지 전환 애니메이션 (가드 포함)
  Future<void> _animateToPage(
    int nextPage,
    double currentTime,
    double endTime,
  ) async {
    if (_isPageAnimating || !mounted) return;

    debugPrint(
      '🔄 [페이지 전환] ${_currentPage + 1} → ${nextPage + 1} (time: ${currentTime.toStringAsFixed(1)}s / ${endTime.toStringAsFixed(1)}s)',
    );

    _isPageAnimating = true; // 가드 설정

    if (mounted) {
      setState(() => _currentPage = nextPage);
    }

    if (_pageController.hasClients) {
      await _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }

    // 애니메이션 완료 후 가드 해제 (약간의 딜레이 추가)
    await Future.delayed(const Duration(milliseconds: 100));
    _isPageAnimating = false;
  }

  // ========== Call Audio Intercept ==========
  // REFACTORED: TTS 대본 완료 후 통화 녹음 재생 → 다음 페이지 전환
  Future<void> _playCallAudioIntercept(Map<String, dynamic> callCue) async {
    if (!mounted || _isPlayingCallAudio) return;

    final int currentCallPage = _currentPage; // 현재 페이지 저장

    try {
      debugPrint('📞 [Call Audio] === TTS 대본 완료 - 통화 녹음 재생 시작 ===');
      if (mounted) setState(() => _isPlayingCallAudio = true);

      // Step 1: TTS 일시정지 (대본 읽기 완료 후이므로 즉시 정지)
      await _audioPlayer.pause();
      debugPrint('📞 [Call Audio] TTS 일시정지');

      // Step 2: 통화 녹음 URL 가져오기 (타임아웃 5초)
      final callUrl = await _getCueDownloadUrl(
        callCue,
      ).timeout(const Duration(seconds: 5), onTimeout: () => null);

      if (callUrl == null || callUrl.isEmpty) {
        debugPrint('❌ [Call Audio] 통화 녹음 URL 없음 - 다음 페이지로 이동');
        if (mounted) setState(() => _isPlayingCallAudio = false);
        // 다음 페이지로 전환 후 TTS 재개
        await _moveToNextPageAfterCallAudio(currentCallPage);
        return;
      }

      // Step 3: 통화 녹음 재생
      debugPrint('📞 [Call Audio] 통화 녹음 로드 중...');
      try {
        await _effectPlayer
            .setUrl(callUrl)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw Exception('통화 녹음 로드 타임아웃'),
            );
        await _effectPlayer.play();
        debugPrint('📞 [Call Audio] 🎵 통화 녹음 재생 중...');

        // Step 4: 재생 완료 대기 (최대 60초)
        await _effectPlayer.processingStateStream
            .firstWhere(
              (state) =>
                  state == ProcessingState.completed ||
                  state == ProcessingState.idle,
            )
            .timeout(
              const Duration(seconds: 60),
              onTimeout: () => ProcessingState.completed,
            );
        debugPrint('📞 [Call Audio] ✅ 통화 녹음 재생 완료');
      } catch (e) {
        debugPrint('❌ [Call Audio] 재생 오류: $e');
        await _effectPlayer.stop();
      }

      // Step 5: 통화 녹음 완료 → 다음 페이지로 전환 후 TTS 재개
      if (mounted) {
        setState(() => _isPlayingCallAudio = false);
        await _moveToNextPageAfterCallAudio(currentCallPage);
      }
    } catch (e) {
      debugPrint('❌ [Call Audio] 전체 오류: $e');
      if (mounted) {
        setState(() => _isPlayingCallAudio = false);
        // 에러 발생 시에도 다음 페이지로 전환 시도
        await _moveToNextPageAfterCallAudio(currentCallPage);
      }
    }
  }

  // 통화 녹음 완료 후 다음 페이지 전환 및 TTS 재개
  Future<void> _moveToNextPageAfterCallAudio(int callPage) async {
    if (!mounted) return;

    // 다음 페이지가 있으면 전환
    if (callPage + 1 < _pageGroups.length) {
      debugPrint(
        '📞 [Call Audio] 다음 페이지로 전환: ${callPage + 1} → ${callPage + 2}',
      );

      _isPageAnimating = true;
      if (mounted) {
        setState(() => _currentPage = callPage + 1);
      }

      if (_pageController.hasClients) {
        await _pageController.animateToPage(
          callPage + 1,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
        );
      }

      await Future.delayed(const Duration(milliseconds: 100));
      _isPageAnimating = false;
    }

    // TTS 재개
    if (mounted) {
      await _audioPlayer.play();
      debugPrint('📞 [Call Audio] TTS 재개');
    }
  }

  // ========== Firebase URL 변환 ==========
  // REFACTORED: 모든 예외를 잡아서 null 반환 (404 포함)
  Future<String?> _getFirebaseDownloadUrl(String? url) async {
    if (url == null || url.isEmpty) {
      debugPrint('⚠️ [Firebase URL] 입력 URL이 null이거나 비어있음');
      return null;
    }

    final safePreview = url.length > 80 ? url.substring(0, 80) : url;
    debugPrint('🔗 [Firebase URL] 입력: $safePreview...');

    try {
      // Case 1: gs:// 형식
      if (url.startsWith('gs://')) {
        debugPrint('📦 [Firebase URL] gs:// 형식 감지');
        final path = url.replaceFirst(RegExp(r'gs://[^/]+/'), '');
        try {
          final downloadUrl = await FirebaseStorage.instance
              .ref(path)
              .getDownloadURL()
              .timeout(const Duration(seconds: 10));
          debugPrint('✅ [Firebase URL] 성공');
          return downloadUrl;
        } catch (e) {
          debugPrint('❌ [Firebase URL] gs:// 변환 실패: $e');
          return null; // 404 포함 모든 에러 → null
        }
      }

      // Case 2: 이미 다운로드 URL 형식
      if (url.contains('firebasestorage.googleapis.com') &&
          url.contains('alt=media')) {
        debugPrint('✅ [Firebase URL] 이미 다운로드 URL 형식');
        return url;
      }

      // Case 3: storage.googleapis.com 형식
      final storageMatch = RegExp(
        r'https://storage\.googleapis\.com/[^/]+/(.+)',
      ).firstMatch(url);
      if (storageMatch != null) {
        debugPrint('📦 [Firebase URL] storage.googleapis.com 형식 감지');
        final path = storageMatch.group(1);
        if (path == null || path.isEmpty) {
          debugPrint('❌ [Firebase URL] 경로 추출 실패');
          return null;
        }
        try {
          final downloadUrl = await FirebaseStorage.instance
              .ref(path)
              .getDownloadURL()
              .timeout(const Duration(seconds: 10));
          debugPrint('✅ [Firebase URL] 성공');
          return downloadUrl;
        } catch (e) {
          debugPrint('❌ [Firebase URL] storage.googleapis.com 변환 실패: $e');
          return null; // 404 포함 모든 에러 → null
        }
      }

      debugPrint('⚠️ [Firebase URL] 알 수 없는 형식 - 그대로 반환');
      return url;
    } catch (e) {
      debugPrint('❌ [Firebase URL] 예상치 못한 에러: $e');
      return null; // 모든 예외 → null (crash 방지)
    }
  }

  // ========== 재생/일시정지 ==========
  // REFACTORED: _audioPlayer.playing 직접 사용 (로컬 상태 변수 없음)
  Future<void> _togglePlayPause() async {
    if (!mounted) return;

    try {
      // Case 1: Call Audio 재생 중이면 effectPlayer 토글
      if (_isPlayingCallAudio) {
        final isEffectPlaying = _effectPlayer.playing;
        debugPrint(
          '🎵 [토글] Call Audio: $isEffectPlaying → ${!isEffectPlaying}',
        );

        if (isEffectPlaying) {
          await _effectPlayer.pause();
        } else {
          await _effectPlayer.play();
        }
        return;
      }

      // Case 2: 메인 TTS 플레이어 토글
      final isCurrentlyPlaying = _audioPlayer.playing;
      debugPrint('🎵 [토글] TTS: $isCurrentlyPlaying → ${!isCurrentlyPlaying}');

      if (isCurrentlyPlaying) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play();
      }
      // StreamBuilder가 UI 자동 업데이트함 - setState 불필요
    } catch (e) {
      debugPrint('❌ [토글] 실패: $e');
    }
  }

  // ========== UI 빌드 ==========
  @override
  Widget build(BuildContext context) {
    // 테마 모드 감지
    _isDarkMode = Theme.of(context).brightness == Brightness.dark;

    SystemChrome.setSystemUIOverlayStyle(
      _isDarkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    );

    if (_loading) {
      return Scaffold(
        backgroundColor: _deepNavy,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildShimmerLoading(),
              const SizedBox(height: 24),
              Text(
                _loadingStatus,
                style: TextStyle(
                  color: _warmCream,
                  fontSize: 16,
                  fontFamily: 'PyeongtaekSemiconductor',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _deepNavy,
      body: Stack(
        children: [
          // 배경 블러
          _buildBlurredBackground(),

          // 메인 컨텐츠
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildPageView()),
                _buildBottomControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ========== Shimmer 로딩 ==========
  Widget _buildShimmerLoading() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            _softPeach.withOpacity(0.5),
            _pastelLavender.withOpacity(0.5),
            _softPeach.withOpacity(0.5),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return Transform.scale(
            scale: 1.0 + (_pulseController.value * 0.1),
            child: CircularProgressIndicator(color: _warmCream, strokeWidth: 3),
          );
        },
      ),
    );
  }

  // ========== 블러 배경 ==========
  Widget _buildBlurredBackground() {
    final midColor = _isDarkMode
        ? const Color(0xFF2D1F3D)
        : const Color(0xFFF0F0F0);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_deepNavy, midColor, _deepNavy],
        ),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, _deepNavy.withOpacity(0.3)],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 헤더 ==========
  Widget _buildHeader() {
    final dateLabel = _formatDateLabel(_storyDocId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          // 뒤로가기
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _isDarkMode ? _glassWhite : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _isDarkMode ? _glassBorder : Colors.grey.shade300,
                  width: 1.5,
                ),
                boxShadow: _isDarkMode
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_back_ios_new,
                    color: _isDarkMode ? _warmCream : Colors.grey.shade700,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '돌아가기',
                    style: TextStyle(
                      fontFamily: 'PyeongtaekSemiconductor',
                      color: _isDarkMode
                          ? _warmCream.withOpacity(0.95)
                          : Colors.grey.shade700,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // 날짜
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: _isDarkMode ? _glassWhite : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _isDarkMode ? _glassBorder : Colors.grey.shade300,
                width: 1.5,
              ),
              boxShadow: _isDarkMode
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: Text(
              dateLabel,
              style: TextStyle(
                fontFamily: 'PyeongtaekSemiconductor',
                color: _isDarkMode ? _warmCream : Colors.grey.shade800,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          // 페이지 번호
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _isDarkMode ? _glassWhite : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _isDarkMode ? _glassBorder : Colors.grey.shade300,
                width: 1.5,
              ),
              boxShadow: _isDarkMode
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: Text(
              '${_currentPage + 1} / ${_pageGroups.length}',
              style: TextStyle(
                fontFamily: 'PyeongtaekSemiconductor',
                color: _isDarkMode ? _warmCream : Colors.grey.shade700,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========== 세그먼트 진행바 ==========
  Widget _buildSegmentProgressBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: List.generate(_pageGroups.length, (index) {
          final isActive = index == _currentPage;
          final isPassed = index < _currentPage;

          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: isPassed
                    ? _pastelPink
                    : isActive
                    ? _softPeach
                    : _glassWhite,
              ),
            ),
          );
        }),
      ),
    );
  }

  // ========== 페이지 뷰 ==========
  Widget _buildPageView() {
    if (_pageGroups.isEmpty) {
      return const SizedBox.shrink();
    }
    return PageView.builder(
      controller: _pageController,
      onPageChanged: (page) {
        if (mounted) {
          setState(() => _currentPage = page);
        }
        // 페이지 변경 시 해당 오디오 시점으로 이동
        final firstCueIdx = _pageGroups[page].first;
        final timeSeconds = (_cueSheet[firstCueIdx]['time_seconds'] as num)
            .toDouble();
        _audioPlayer.seek(Duration(milliseconds: (timeSeconds * 1000).toInt()));
      },
      itemCount: _pageGroups.length,
      itemBuilder: (context, pageIdx) {
        final cueIndices = _pageGroups[pageIdx];
        return _buildStoryCard(pageIdx, cueIndices);
      },
    );
  }

  // ========== 스토리 카드 ==========
  Widget _buildStoryCard(int pageIdx, List<int> cueIndices) {
    final isActive = pageIdx == _currentPage;

    return AnimatedScale(
      scale: isActive ? 1.0 : 0.92,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            // 비주얼 영역 - 더 불맰식한 레이아웃 (flex 6)
            Expanded(
              flex: 6,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: _isDarkMode
                          ? Colors.black.withOpacity(0.4)
                          : Colors.black.withOpacity(0.15),
                      blurRadius: _isDarkMode ? 30 : 20,
                      spreadRadius: _isDarkMode ? 2 : 0,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildVisualContent(cueIndices, isActive: isActive),
                      // 하단 그라데이션 오버레이
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 80,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                _deepNavy.withOpacity(0.6),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 텍스트 영역 - 그라데이션 오버레이 배경 (flex 4)
            Expanded(
              flex: 4,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _isDarkMode
                        ? [
                            _deepNavy.withOpacity(0.7),
                            _deepNavy.withOpacity(0.9),
                          ]
                        : [Colors.white.withOpacity(0.95), Colors.white],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isDarkMode
                        ? _glassBorder.withOpacity(0.3)
                        : Colors.grey.shade300,
                    width: 1,
                  ),
                  boxShadow: _isDarkMode
                      ? []
                      : [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: _buildTextContent(cueIndices),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ========== 비주얼 컨텐츠 ==========
  Widget _buildVisualContent(List<int> cueIndices, {required bool isActive}) {
    final cueIndex = cueIndices.first;
    final cue = _cueSheet[cueIndex];
    final type = cue['type'];

    debugPrint(
      '🎨 [비주얼] 페이지 ${_currentPage + 1} - type: $type, cueIndex: $cueIndex',
    );

    if (type == 'greeting') {
      return _buildIconVisual(
        Icons.wb_sunny_rounded,
        const Color(0xFFFFB347),
        _softPeach,
      );
    } else if (type == 'call') {
      // Show pulsing icon while call audio is playing
      return _buildCallAudioVisual(_isPlayingCallAudio);
    } else if (type == 'closing') {
      return _buildIconVisual(
        Icons.nights_stay_rounded,
        const Color(0xFF9B8DC9),
        _pastelLavender,
      );
    } else if (type == 'sms') {
      return _buildIconVisual(
        Icons.mail_outline_rounded,
        Colors.indigoAccent,
        Colors.indigoAccent.withOpacity(0.2),
      );
    } else if (type == 'location') {
      return _buildIconVisual(
        Icons.location_on_rounded,
        Colors.redAccent,
        Colors.redAccent.withOpacity(0.2),
      );
    } else if (type == 'image') {
      debugPrint('📷 [이미지] 이미지 타입 감지 - FutureBuilder 시작');
      debugPrint('📷 [이미지] cue 데이터: ${cue.keys.toList()}');
      debugPrint(
        '📷 [이미지] resource_url 존재: ${cue.containsKey('resource_url')}',
      );
      if (cue.containsKey('resource_url')) {
        final rawUrl = cue['resource_url'];
        debugPrint(
          '📷 [이미지] resource_url 값: ${rawUrl?.toString().substring(0, rawUrl.toString().length > 100 ? 100 : rawUrl.toString().length)}...',
        );
      }
      return FutureBuilder<String?>(
        future: _getCueDownloadUrl(cue),
        builder: (context, snapshot) {
          debugPrint(
            '📷 [이미지] FutureBuilder state: ${snapshot.connectionState}',
          );

          // 로딩 중 상태 먼저 처리
          if (snapshot.connectionState == ConnectionState.waiting ||
              snapshot.connectionState == ConnectionState.none) {
            return Container(
              color: _deepNavy,
              child: Center(
                child: CircularProgressIndicator(
                  color: _warmCream,
                  strokeWidth: 2,
                ),
              ),
            );
          }

          // Robust Error Handling: Show placeholder immediately on error
          if (snapshot.hasError ||
              snapshot.data == null ||
              snapshot.data!.isEmpty) {
            if (snapshot.hasError) {
              debugPrint('❌ [이미지] 에러 발생: ${snapshot.error}');
            }
            debugPrint('⚠️ [이미지] Media Unavailable - 플레이스홀더 표시');
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isDarkMode
                      ? [_deepNavy, const Color(0xFF2D1F3D)]
                      : [const Color(0xFFF8F8F8), const Color(0xFFFFFFFF)],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.broken_image,
                      size: 60,
                      color: _isDarkMode
                          ? _warmCream.withOpacity(0.5)
                          : Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '이미지를 불러올 수 없습니다',
                      style: TextStyle(
                        fontFamily: 'PyeongtaekSemiconductor',
                        color: _isDarkMode
                            ? _warmCream.withOpacity(0.7)
                            : Colors.grey.shade500,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final url = snapshot.data!;
          // Ken Burns 효과: 느린 줌/패닝으로 정적 이미지에 생명감 부여
          return AnimatedBuilder(
            animation: _kenBurnsController,
            builder: (context, child) {
              final scale = 1.0 + (_kenBurnsController.value * 0.08);
              final offsetX =
                  math.sin(_kenBurnsController.value * math.pi) * 10;
              final offsetY = math.cos(_kenBurnsController.value * math.pi) * 5;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..scale(scale)
                  ..translate(offsetX, offsetY),
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  memCacheWidth: 600,
                  placeholder: (context, url) => Container(
                    color: _deepNavy,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: _warmCream,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: _deepNavy,
                    child: Icon(Icons.image_not_supported, color: _warmCream),
                  ),
                ),
              );
            },
          );
        },
      );
    } else if (type == 'video') {
      debugPrint('🎬 [비디오] 비디오 타입 감지 - cueIndex: $cueIndex');
      debugPrint('🎬 [비디오] cue 데이터: ${cue.keys.toList()}');
      debugPrint(
        '🎬 [비디오] resource_url 존재: ${cue.containsKey('resource_url')}',
      );
      if (cue.containsKey('resource_url')) {
        final rawUrl = cue['resource_url'];
        debugPrint(
          '🎬 [비디오] resource_url 값: ${rawUrl?.toString().substring(0, rawUrl.toString().length > 100 ? 100 : rawUrl.toString().length)}...',
        );
      }
      return FutureBuilder<VideoPlayerController?>(
        future: _ensureVideoControllerInitialized(cueIndex),
        builder: (context, snapshot) {
          debugPrint(
            '🎬 [비디오] FutureBuilder state: ${snapshot.connectionState}',
          );

          // 로딩 중 상태 먼저 처리
          if (snapshot.connectionState == ConnectionState.waiting ||
              snapshot.connectionState == ConnectionState.none) {
            return Container(
              color: _deepNavy,
              child: Center(
                child: CircularProgressIndicator(
                  color: _warmCream,
                  strokeWidth: 2,
                ),
              ),
            );
          }

          // Robust Error Handling: Show placeholder immediately on error
          if (snapshot.hasError ||
              snapshot.data == null ||
              !snapshot.data!.value.isInitialized) {
            if (snapshot.hasError) {
              debugPrint('❌ [비디오] 에러 발생: ${snapshot.error}');
            }
            debugPrint('⚠️ [비디오] Media Unavailable - 플레이스홀더 표시');
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isDarkMode
                      ? [_deepNavy, const Color(0xFF2D1F3D)]
                      : [const Color(0xFFF8F8F8), const Color(0xFFFFFFFF)],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.videocam_off,
                      size: 60,
                      color: _isDarkMode
                          ? _warmCream.withOpacity(0.5)
                          : Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '동영상을 불러올 수 없습니다',
                      style: TextStyle(
                        fontFamily: 'PyeongtaekSemiconductor',
                        color: _isDarkMode
                            ? _warmCream.withOpacity(0.7)
                            : Colors.grey.shade500,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final controller = snapshot.data;
          if (controller == null || !controller.value.isInitialized) {
            return Container(
              color: _deepNavy,
              child: Center(
                child: CircularProgressIndicator(color: _warmCream),
              ),
            );
          }
          debugPrint(
            '✅ [비디오] 재생 준비 완료 - isActive: $isActive, isPlaying: ${controller.value.isPlaying}',
          );

          if (isActive && !controller.value.isPlaying) {
            controller.play();
          } else if (!isActive && controller.value.isPlaying) {
            controller.pause();
          }

          return AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          );
        },
      );
    }

    return Container(color: _deepNavy);
  }

  // ========== Call Audio Visual ==========
  // Logic designed by Gemini
  Widget _buildCallAudioVisual(bool isPlayingCall) {
    final iconColor = const Color(0xFF7FCCB4);
    final glowColor = _pastelMint;

    final midColor = _isDarkMode
        ? const Color(0xFF2D1F3D)
        : const Color(0xFFFAFAFA);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isDarkMode
              ? [_deepNavy, midColor, _deepNavy.withOpacity(0.9)]
              : [
                  const Color(0xFFF8F8F8),
                  const Color(0xFFFFFFFF),
                  const Color(0xFFF5F5F5),
                ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Pulsing icon during call playback
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                final scale = isPlayingCall
                    ? 1.0 +
                          (math.sin(_pulseController.value * 2 * math.pi) *
                              0.15)
                    : 1.0;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: glowColor.withOpacity(
                            isPlayingCall
                                ? (_isDarkMode ? 0.5 : 0.35)
                                : (_isDarkMode ? 0.3 : 0.2),
                          ),
                          blurRadius: isPlayingCall
                              ? (_isDarkMode ? 50 : 40)
                              : (_isDarkMode ? 40 : 30),
                          spreadRadius: isPlayingCall
                              ? (_isDarkMode ? 20 : 15)
                              : (_isDarkMode ? 15 : 10),
                        ),
                      ],
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(35),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isDarkMode
                            ? _glassWhite
                            : glowColor.withOpacity(0.15),
                        border: Border.all(
                          color: glowColor.withOpacity(
                            isPlayingCall ? 0.6 : 0.4,
                          ),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: iconColor.withOpacity(
                              isPlayingCall
                                  ? (_isDarkMode ? 0.4 : 0.25)
                                  : (_isDarkMode ? 0.2 : 0.12),
                            ),
                            blurRadius: 25,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.phone_in_talk_rounded,
                        size: 70,
                        color: iconColor,
                        shadows: [
                          Shadow(
                            color: iconColor.withOpacity(0.5),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (isPlayingCall) ...[
              const SizedBox(height: 24),
              Text(
                '통화 녹음 재생 중...',
                style: TextStyle(
                  fontFamily: 'PyeongtaekSemiconductor',
                  color: _isDarkMode
                      ? _warmCream.withOpacity(0.9)
                      : Colors.grey.shade700,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIconVisual(IconData icon, Color iconColor, Color glowColor) {
    final midColor = _isDarkMode
        ? const Color(0xFF2D1F3D)
        : const Color(0xFFFAFAFA);
    final bgColor = _isDarkMode ? _deepNavy : const Color(0xFFF5F5F5);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isDarkMode
              ? [_deepNavy, midColor, _deepNavy.withOpacity(0.9)]
              : [
                  const Color(0xFFF8F8F8),
                  const Color(0xFFFFFFFF),
                  const Color(0xFFF5F5F5),
                ],
        ),
      ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: glowColor.withOpacity(_isDarkMode ? 0.3 : 0.25),
                blurRadius: _isDarkMode ? 40 : 30,
                spreadRadius: _isDarkMode ? 15 : 10,
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(35),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isDarkMode ? _glassWhite : glowColor.withOpacity(0.15),
              border: Border.all(
                color: glowColor.withOpacity(_isDarkMode ? 0.4 : 0.35),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: iconColor.withOpacity(_isDarkMode ? 0.2 : 0.15),
                  blurRadius: 25,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Icon(
              icon,
              size: 70,
              color: iconColor,
              shadows: [
                Shadow(color: iconColor.withOpacity(0.5), blurRadius: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 텍스트 컨텐츠 (타이핑 효과) ==========
  Widget _buildTextContent(List<int> cueIndices) {
    final cueIndex = cueIndices.first;
    final cue = _cueSheet[cueIndex];
    final caption = _displayText(cue['caption']);
    final type = cue['type'];

    // 현재 페이지의 텍스트 추출: rawScript에서 해당 구간 찾기
    final firstCueIdx = cueIndices.first;
    final lastCueIdx = cueIndices.last;
    final firstMarker = '<mark name=\'cue_$firstCueIdx\'/>';
    final lastMarker = lastCueIdx + 1 < _cueSheet.length
        ? '<mark name=\'cue_${lastCueIdx + 1}\'/>'
        : null;

    String pageText = '';
    final rawScript = _rawScript ?? _cleanScript ?? '';

    if (rawScript.isNotEmpty) {
      final startIdx = rawScript.indexOf(firstMarker);
      if (startIdx != -1) {
        final contentStart = startIdx + firstMarker.length;
        final endIdx = lastMarker != null
            ? rawScript.indexOf(lastMarker, contentStart)
            : rawScript.length;

        if (endIdx != -1) {
          pageText = rawScript
              .substring(contentStart, endIdx)
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .trim();
        }
      }
    }

    final fallbackScript = _displayText(_cleanScript);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 타입 배지
        if (type != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _getTypeColor(type).withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _getTypeColor(type).withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_getTypeIcon(type), size: 14, color: _getTypeColor(type)),
                const SizedBox(width: 6),
                Text(
                  _getTypeLabel(type),
                  style: TextStyle(
                    fontFamily: 'PyeongtaekSemiconductor',
                    color: _getTypeColor(type),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        if (caption.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _isDarkMode
                  ? _softPeach.withOpacity(0.2)
                  : _softPeach.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              caption,
              style: TextStyle(
                fontFamily: 'PyeongtaekSemiconductor',
                color: _isDarkMode ? _softPeach : const Color(0xFFD4845A),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        const SizedBox(height: 4),
        // 타이핑 텍스트는 Expanded로 남은 공간 차지
        Expanded(
          child: _buildTypewriterText(cueIndices, pageText, fallbackScript),
        ),
      ],
    );
  }

  // ========== 타입별 스타일 헬퍼 ==========
  Color _getTypeColor(String type) {
    switch (type) {
      case 'greeting':
        return const Color(0xFFFFB347);
      case 'closing':
        return _pastelLavender;
      case 'sms':
        return Colors.indigoAccent;
      case 'call':
        return _pastelMint;
      case 'image':
      case 'video':
        return _pastelPink;
      case 'location':
        return Colors.tealAccent;
      default:
        return _warmCream;
    }
  }

  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'greeting':
        return Icons.wb_sunny_rounded;
      case 'closing':
        return Icons.nights_stay_rounded;
      case 'sms':
        return Icons.mail_outline_rounded;
      case 'call':
        return Icons.phone_in_talk_rounded;
      case 'image':
        return Icons.photo_camera_rounded;
      case 'video':
        return Icons.videocam_rounded;
      case 'location':
        return Icons.location_on_rounded;
      default:
        return Icons.auto_stories_rounded;
    }
  }

  String _getTypeLabel(String type) {
    switch (type) {
      case 'greeting':
        return '아침 인사';
      case 'closing':
        return '하루 마무리';
      case 'sms':
        return '문자 메시지';
      case 'call':
        return '통화 기록';
      case 'image':
        return '사진';
      case 'video':
        return '동영상';
      case 'location':
        return '위치';
      default:
        return '이야기';
    }
  }

  // ========== 타이핑 효과 텍스트 ==========
  Widget _buildTypewriterText(
    List<int> cueIndices,
    String pageText,
    String fallbackScript,
  ) {
    // 1순위: pageText (rawScript에서 추출한 현재 페이지 텍스트)
    // 2순위: cue의 text 필드 연결 (sms, image, video 등)
    // 3순위: fallbackScript (전체 스크립트)
    String fullText = pageText;

    if (fullText.isEmpty) {
      // pageText가 없으면 각 cue의 text 필드 시도
      fullText = cueIndices
          .map((idx) => _displayText(_cueSheet[idx]['text']))
          .where((text) => text.isNotEmpty)
          .join('\n\n');
    }

    if (fullText.isEmpty) {
      // 그래도 없으면 fallbackScript 사용
      fullText = fallbackScript;
    }

    if (fullText.isEmpty) {
      return Text(
        '내용을 불러올 수 없습니다.',
        style: TextStyle(
          fontFamily: 'PyeongtaekSemiconductor',
          color: _isDarkMode
              ? _warmCream.withOpacity(0.9)
              : Colors.grey.shade600,
          fontSize: 17,
          height: 2.0,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.5,
        ),
      );
    }

    return _TypewriterTextWidget(
      fullText: fullText,
      cueIndices: cueIndices,
      cueSheet: _cueSheet,
      audioDuration: _audioDuration,
      audioPlayer: _audioPlayer,
      isCallAudioPlaying: _isPlayingCallAudio,
    );
  }

  String _displayText(dynamic value) {
    if (value == null) return '';
    final text = value.toString();
    if (_looksEncrypted(text)) {
      debugPrint('⚠️ [표시] 암호문 감지: ${text.substring(0, 50)}...');
      // 마지막 시도: 직접 복호화
      final decrypted = CryptoUtils.decrypt(text);
      if (decrypted != null &&
          decrypted is String &&
          !_looksEncrypted(decrypted)) {
        debugPrint(
          '✅ [표시] 복호화 성공: ${decrypted.substring(0, decrypted.length > 30 ? 30 : decrypted.length)}...',
        );
        return decrypted;
      }
      return '[복호화 필요: 암호화된 텍스트]';
    }
    if (_looksBase64Like(text)) return '';
    return text;
  }

  bool _looksBase64Like(String value) {
    final trimmed = value.replaceAll('\n', '').trim();
    if (trimmed.length < 60) return false;
    final base64UrlExp = RegExp(r'^[A-Za-z0-9_-]+$');
    final base64Exp = RegExp(r'^[A-Za-z0-9+/=]+$');
    return base64UrlExp.hasMatch(trimmed) || base64Exp.hasMatch(trimmed);
  }

  String _formatDateLabel(String docId) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(docId);
    if (match == null) return docId;
    final year = match.group(1);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    return '$year년 $month월 $day일';
  }

  Future<String?> _getCueDownloadUrl(Map<String, dynamic> cue) async {
    try {
      final rawUrl = cue['resource_url'];
      debugPrint(
        '🔗 [URL 처리] rawUrl type: ${rawUrl.runtimeType}, value: ${rawUrl?.toString().substring(0, rawUrl.toString().length > 50 ? 50 : rawUrl.toString().length)}...',
      );

      String? url;
      if (rawUrl == null) {
        debugPrint('⚠️ [URL 처리] rawUrl이 null');
        return null;
      }

      // rawUrl이 암호화되어 있는지 확인
      if (rawUrl is String && _looksEncrypted(rawUrl)) {
        debugPrint('🔐 [URL 처리] 암호화된 URL 감지 - 복호화 시도');
        final decrypted = _decryptString(rawUrl);
        url = decrypted;
      } else {
        url = rawUrl.toString();
      }

      if (url == null || url.isEmpty) {
        debugPrint('❌ [URL 처리] 복호화 후 url이 비어있음');
        return null;
      }

      debugPrint(
        '✅ [URL 처리] 최종 URL: ${url.substring(0, url.length > 80 ? 80 : url.length)}...',
      );
      return await _getFirebaseDownloadUrl(url);
    } catch (e) {
      debugPrint('❌ 리소스 URL 처리 실패: $e');
      return null;
    }
  }

  Future<VideoPlayerController?> _ensureVideoControllerInitialized(
    int cueIndex,
  ) async {
    try {
      debugPrint('🎬 [비디오 초기화] cueIndex: $cueIndex 시작');
      final existing = _videoControllers[cueIndex];
      if (existing != null && existing.value.isInitialized) {
        debugPrint('✅ [비디오 초기화] 이미 초기화된 컨트롤러 재사용');
        return existing;
      }

      final cue = _cueSheet[cueIndex];
      debugPrint('🎬 [비디오 초기화] URL 가져오기 시도...');
      final url = await _getCueDownloadUrl(cue);
      debugPrint('🎬 [비디오 초기화] 받은 URL: $url');
      if (url == null || url.isEmpty) {
        debugPrint('❌ [비디오 초기화] URL이 null이거나 비어있음');
        return null;
      }

      debugPrint('🎬 [비디오 초기화] VideoPlayerController 생성 중...');
      final controller =
          existing ??
          VideoPlayerController.networkUrl(
            Uri.parse(url),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );

      if (existing == null) {
        _videoControllers[cueIndex] = controller;
        debugPrint('🎬 [비디오 초기화] 새 컨트롤러를 맵에 저장');
      }

      try {
        debugPrint('🎬 [비디오 초기화] initialize() 호출 중...');
        await controller.initialize();
        debugPrint('🎬 [비디오 초기화] setLooping(false) 호출 중...');
        await controller.setLooping(false);
        debugPrint('🎬 [비디오 초기화] setVolume(1.0) 호출 중...');
        await controller.setVolume(1.0);
        debugPrint('✅ [비디오 초기화] 성공!');
        return controller;
      } catch (e) {
        debugPrint('❌ [비디오 초기화] 실패: $e');
        if (existing == null) {
          _videoControllers.remove(cueIndex);
          try {
            await controller.dispose();
          } catch (_) {}
        }
        return null;
      }
    } catch (e) {
      debugPrint('❌ 비디오 초기화 실패: $e');
      return null;
    }
  }

  // ========== 하단 컨트롤 ==========
  Widget _buildBottomControls() {
    final canGoPrev = _currentPage > 0;
    final canGoNext = _currentPage < _pageGroups.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 이전 버튼
          _buildControlButton(
            icon: Icons.arrow_back_ios_new,
            enabled: canGoPrev,
            onTap: () {
              if (canGoPrev) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          ),

          // 재생/일시정지 버튼 (유기적인 "숨쉬는" 펄스 애니메이션)
          // StreamBuilder로 실시간 플레이어 상태 반영
          StreamBuilder<bool>(
            stream: _audioPlayer.playingStream,
            initialData: _audioPlayer.playing,
            builder: (context, playingSnapshot) {
              final isActuallyPlaying = playingSnapshot.data ?? false;

              return GestureDetector(
                onTap: () {
                  debugPrint(
                    '🔴 [버튼] 클릭! isPlaying=$isActuallyPlaying, callAudio=$_isPlayingCallAudio',
                  );
                  _togglePlayPause();
                },
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    // 더 유기적인 숨쉬는 효과를 위한 사인 곡선 적용
                    final breathValue = math.sin(
                      _pulseController.value * math.pi,
                    );
                    final scale = isActuallyPlaying
                        ? 1.0 + (breathValue * 0.05)
                        : 1.0;
                    final glowIntensity = isActuallyPlaying
                        ? 0.3 + (breathValue * 0.2)
                        : 0.0;

                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _softPeach.withOpacity(
                                0.25 + (breathValue * 0.1),
                              ),
                              _pastelLavender.withOpacity(
                                0.25 + (breathValue * 0.1),
                              ),
                            ],
                          ),
                          border: Border.all(
                            color: _glassBorder.withOpacity(
                              0.6 + (breathValue * 0.2),
                            ),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _pastelPink.withOpacity(glowIntensity),
                              blurRadius: 20 + (breathValue * 15),
                              spreadRadius: 2 + (breathValue * 3),
                            ),
                            if (isActuallyPlaying)
                              BoxShadow(
                                color: _softPeach.withOpacity(
                                  glowIntensity * 0.5,
                                ),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                          ],
                        ),
                        child: Icon(
                          isActuallyPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: _isDarkMode
                              ? _warmCream
                              : Colors.grey.shade700,
                          size: 36,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),

          // 다음 버튼
          _buildControlButton(
            icon: Icons.arrow_forward_ios,
            enabled: canGoNext,
            onTap: () {
              if (canGoNext) {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final bgColor = _isDarkMode
        ? (enabled ? _glassWhite : _glassWhite.withOpacity(0.3))
        : (enabled ? Colors.white : Colors.grey.shade200);
    final borderColor = _isDarkMode
        ? (enabled ? _glassBorder : _glassBorder.withOpacity(0.3))
        : (enabled ? Colors.grey.shade300 : Colors.grey.shade200);
    final iconColor = _isDarkMode
        ? (enabled ? _warmCream : _warmCream.withOpacity(0.3))
        : (enabled ? Colors.grey.shade700 : Colors.grey.shade400);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bgColor,
          border: Border.all(color: borderColor),
          boxShadow: _isDarkMode
              ? null
              : [
                  if (enabled)
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                ],
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}

// ========== 자동 스크롤 타이핑 효과 위젯 ==========
class _TypewriterTextWidget extends StatefulWidget {
  final String fullText;
  final List<int> cueIndices;
  final List<Map<String, dynamic>> cueSheet;
  final Duration? audioDuration;
  final AudioPlayer audioPlayer;
  final bool isCallAudioPlaying;

  const _TypewriterTextWidget({
    required this.fullText,
    required this.cueIndices,
    required this.cueSheet,
    required this.audioDuration,
    required this.audioPlayer,
    this.isCallAudioPlaying = false,
  });

  @override
  State<_TypewriterTextWidget> createState() => _TypewriterTextWidgetState();
}

class _TypewriterTextWidgetState extends State<_TypewriterTextWidget> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.audioPlayer.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final currentSeconds = position.inMilliseconds / 1000.0;

        // 현재 페이지 그룹의 시작/종료 시간
        final firstCueIdx = widget.cueIndices.first;
        final lastCueIdx = widget.cueIndices.last;

        // startTime: 그룹의 첫 번째 cue 시작 시간
        final startTime =
            (widget.cueSheet[firstCueIdx]['time_seconds'] as num?)
                ?.toDouble() ??
            0.0;

        // endTime: 그룹의 마지막 cue 다음 cue 시작 시간 (또는 오디오 끝)
        final totalDuration =
            (widget.audioDuration?.inMilliseconds ?? 0) / 1000.0;
        final double endTime;
        if (lastCueIdx + 1 < widget.cueSheet.length) {
          endTime =
              (widget.cueSheet[lastCueIdx + 1]['time_seconds'] as num?)
                  ?.toDouble() ??
              (startTime + 10.0);
        } else {
          endTime = totalDuration > 0 ? totalDuration : (startTime + 30.0);
        }

        // 진행률 계산 (0.0 ~ 1.0)
        // Pause typewriter effect when call audio is playing
        double progress = 0.0;
        if (!widget.isCallAudioPlaying &&
            endTime > startTime &&
            currentSeconds >= startTime) {
          progress = ((currentSeconds - startTime) / (endTime - startTime))
              .clamp(0.0, 1.0);
        }

        // 표시할 텍스트 길이 계산
        final visibleLength = (widget.fullText.length * progress).round();
        final displayText = widget.fullText.substring(
          0,
          visibleLength.clamp(0, widget.fullText.length),
        );

        // 텍스트가 길어지면 자동 스크롤
        if (displayText.length > 50) {
          _scrollToBottom();
        }

        return SingleChildScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(),
          child: Text(
            displayText.isNotEmpty ? displayText : ' ',
            style: TextStyle(
              fontFamily: 'PyeongtaekSemiconductor',
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFFFFF8F0).withOpacity(0.95)
                  : const Color(0xFF3D3D3D).withOpacity(0.95),
              fontSize: 17,
              height: 2.0,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.5,
            ),
          ),
        );
      },
    );
  }
}
