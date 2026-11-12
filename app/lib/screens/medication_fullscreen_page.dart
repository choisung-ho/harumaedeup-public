// lib/screens/medication_fullscreen_page.dart
// 시니어용 약 복용 알림 전체 화면 다이얼로그
// FastAPI 서버에서 FCM 푸시를 받으면 이 화면이 표시됨
// ⚠️ 앱은 Firestore에 직접 저장하지 않고, 서버에게만 복용 여부를 전송함

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

// ✅ [추가] 잠금화면 제어 채널
const MethodChannel _lockscreenChannel = MethodChannel(
  'com.example.my_first_app/lockscreen',
);

class MedicationFullscreenPage extends StatefulWidget {
  final String? alarmId;
  final String? medicationName;
  final String? title;
  final String? body;
  final int retryCount; // 재시도 횟수

  const MedicationFullscreenPage({
    super.key,
    this.alarmId,
    this.medicationName,
    this.title,
    this.body,
    this.retryCount = 0,
  });

  @override
  State<MedicationFullscreenPage> createState() =>
      _MedicationFullscreenPageState();
}

class _MedicationFullscreenPageState extends State<MedicationFullscreenPage>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _slideController;
  late Animation<double> _pulseAnimation;
  late Animation<Offset> _slideAnimation;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();

    // ✅ [추가] 잠금화면 위에 표시 활성화 (약 알림 전용)
    _enableShowWhenLocked();

    // 전체 화면 모드 설정
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // 펄스 애니메이션
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 슬라이드 애니메이션
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
        );

    _slideController.forward();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _slideController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // ✅ [추가] 잠금화면 위 표시 비활성화 (일반 모드 복귀)
    _disableShowWhenLocked();

    super.dispose();
  }

  // ✅ [추가] 잠금화면 위에 표시 활성화
  Future<void> _enableShowWhenLocked() async {
    try {
      await _lockscreenChannel.invokeMethod('enableShowWhenLocked');
      debugPrint('✅ 잠금화면 위 표시 활성화');
    } catch (e) {
      debugPrint('⚠️ 잠금화면 제어 실패: $e');
    }
  }

  // ✅ [추가] 잠금화면 위에 표시 비활성화
  Future<void> _disableShowWhenLocked() async {
    try {
      await _lockscreenChannel.invokeMethod('disableShowWhenLocked');
      debugPrint('✅ 잠금화면 위 표시 비활성화');
    } catch (e) {
      debugPrint('⚠️ 잠금화면 제어 실패: $e');
    }
  }

  /// 복용 완료 처리
  Future<void> _handleTaken() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await _sendResponseToServer(status: 'taken');
      if (mounted) {
        _showResultFeedback(success: true);
      }
    } catch (e) {
      debugPrint("❌ 복용 완료 전송 실패: $e");
      if (mounted) {
        _showResultFeedback(success: true); // 전송 실패해도 화면은 닫기
      }
    }
  }

  /// 미복용 처리
  Future<void> _handleMissed() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await _sendResponseToServer(status: 'missed');
      if (mounted) {
        _showResultFeedback(success: false);
      }
    } catch (e) {
      debugPrint("❌ 미복용 전송 실패: $e");
      if (mounted) {
        _showResultFeedback(success: false); // 전송 실패해도 화면은 닫기
      }
    }
  }

  /// ✅ [핵심] 서버에 복용 여부 전송 (Firestore 직접 저장 X)
  Future<void> _sendResponseToServer({required String status}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint("⚠️ 로그인된 사용자 없음");
      return;
    }

    // 서버 엔드포인트 (FastAPI) - 서버의 /medication-confirm 엔드포인트와 일치
    const String serverUrl = 'http://endpoint-3.example.invalid:8000/medication-confirm';

    // ✅ [수정] null 값을 빈 문자열로 대체 (422 에러 방지)
    // is_retry: retry_count > 0 이면 재알림으로 인한 응답임을 명시
    final requestBody = {
      'medicine_id': widget.alarmId ?? '',
      'medication_name': widget.medicationName ?? '',
      'status': status, // 'taken' 또는 'missed'
      'retry_count': widget.retryCount,
      'is_retry': widget.retryCount > 0, // ✅ [추가] 재알림 여부 (백엔드 구분용)
    };

    debugPrint("📤 서버로 복용 응답 전송: $requestBody (재알림: ${widget.retryCount > 0})");

    try {
      // Firebase Auth 토큰 가져오기 (서버 인증용)
      final idToken = await user.getIdToken();

      final response = await http
          .post(
            Uri.parse(serverUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint("✅ 서버 응답 성공: ${response.body}");
      } else {
        debugPrint("⚠️ 서버 응답 실패: ${response.statusCode} - ${response.body}");
      }
    } catch (e) {
      debugPrint("❌ 서버 통신 오류: $e");
      // 오류가 나도 사용자 경험을 위해 예외를 다시 throw하지 않음
    }
  }

  /// 결과 피드백 표시 후 화면 닫기
  void _showResultFeedback({required bool success}) {
    // ✅ 즉시 피드백 다이얼로그 표시
    final dialog = showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, anim1, anim2) {
        return ScaleTransition(
          scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(40),
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: success
                          ? const Color(0xFF4CAF50).withOpacity(0.15)
                          : const Color(0xFFFF9800).withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      success ? Icons.check_rounded : Icons.schedule_rounded,
                      size: 48,
                      color: success
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFFF9800),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    success ? "복용 완료!" : "알겠어요",
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: success
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFFF9800),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    success ? "잘 하셨어요! 💪" : "다음엔 꼭 드세요!",
                    style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    // ✅ 1초 후 모든 화면 닫기 (더 확실한 방식)
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) {
        // Navigator.popUntil로 확실하게 이 페이지까지 닫기
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isSmallScreen = size.height < 700;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF667eea), Color(0xFF764ba2)],
            ),
          ),
          child: SafeArea(
            child: SlideTransition(
              position: _slideAnimation,
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight:
                        size.height -
                        MediaQuery.of(context).padding.top -
                        MediaQuery.of(context).padding.bottom,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: isSmallScreen ? 16 : 24,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // ========== 상단: 시간 표시 ==========
                        _buildTimeSection(isSmallScreen),

                        // ========== 중앙: 약 아이콘 & 메시지 ==========
                        _buildMainContent(isSmallScreen),

                        // ========== 하단: 버튼 ==========
                        _buildButtonSection(isSmallScreen),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeSection(bool isSmallScreen) {
    final now = DateTime.now();
    final timeStr = DateFormat('a h:mm', 'ko_KR').format(now);

    return Column(
      children: [
        SizedBox(height: isSmallScreen ? 8 : 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Text(
            timeStr,
            style: TextStyle(
              fontSize: isSmallScreen ? 18 : 22,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainContent(bool isSmallScreen) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: isSmallScreen ? 16 : 32),

        // 애니메이션 약 아이콘
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Transform.scale(
              scale: _pulseAnimation.value,
              child: Container(
                width: isSmallScreen ? 120 : 150,
                height: isSmallScreen ? 120 : 150,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    "💊",
                    style: TextStyle(fontSize: isSmallScreen ? 60 : 80),
                  ),
                ),
              ),
            );
          },
        ),

        SizedBox(height: isSmallScreen ? 20 : 32),

        // 약 이름
        if (widget.medicationName != null && widget.medicationName!.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              widget.medicationName!,
              style: TextStyle(
                fontSize: isSmallScreen ? 20 : 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

        SizedBox(height: isSmallScreen ? 16 : 24),

        // 메인 메시지
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            "약 드실 시간이에요!",
            style: TextStyle(
              fontSize: isSmallScreen ? 28 : 36,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        SizedBox(height: isSmallScreen ? 8 : 12),

        // 부가 메시지
        Text(
          "건강을 위해 꼭 드세요",
          style: TextStyle(
            fontSize: isSmallScreen ? 16 : 18,
            color: Colors.white.withOpacity(0.85),
          ),
          textAlign: TextAlign.center,
        ),

        // 알림 횟수 표시 (항상 표시)
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.retryCount > 0
                ? Colors.orange.withOpacity(0.3) // 재알림: 주황색
                : Colors.white.withOpacity(0.2), // 첫 알림: 흰색
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            widget.retryCount > 0
                ? "⚠️ ${widget.retryCount + 1}번째 알림이에요!"
                : "${widget.retryCount + 1}번째 알림이에요!",
            style: TextStyle(
              fontSize: isSmallScreen ? 14 : 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),

        SizedBox(height: isSmallScreen ? 16 : 32),
      ],
    );
  }

  Widget _buildButtonSection(bool isSmallScreen) {
    final buttonHeight = isSmallScreen ? 70.0 : 85.0;

    return Column(
      children: [
        // ✅ 복용 완료 버튼
        SizedBox(
          width: double.infinity,
          height: buttonHeight,
          child: ElevatedButton(
            onPressed: _isProcessing ? null : _handleTaken,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF4CAF50),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              disabledBackgroundColor: Colors.white.withOpacity(0.5),
            ),
            child: _isProcessing
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFF4CAF50),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: isSmallScreen ? 32 : 40,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        "네, 먹었어요!",
                        style: TextStyle(
                          fontSize: isSmallScreen ? 22 : 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        SizedBox(height: isSmallScreen ? 12 : 16),

        // ❌ 미복용 버튼
        SizedBox(
          width: double.infinity,
          height: buttonHeight * 0.85,
          child: OutlinedButton(
            onPressed: _isProcessing ? null : _handleMissed,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withOpacity(0.6), width: 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.access_time_rounded, size: isSmallScreen ? 26 : 32),
                const SizedBox(width: 10),
                Text(
                  "아직 안 먹었어요",
                  style: TextStyle(
                    fontSize: isSmallScreen ? 18 : 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: isSmallScreen ? 16 : 24),
      ],
    );
  }
}
