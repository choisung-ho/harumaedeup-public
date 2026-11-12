import 'dart:async'; // ✅ [추가] 타이머 사용을 위해 필요
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // 👈 꼭 추가해야 함!
import 'package:permission_handler/permission_handler.dart'; // ✅ [추가] 배터리 최적화 권한

import 'care_target_my_page.dart';
import 'patient_map_page.dart';
import 'patient_history_page.dart';
import 'voice_chat_screen.dart';
import 'storytelling_date_screen.dart';

// 서비스 Import
import '../services/medication_service.dart';
import '../services/archive_service.dart';
import '../services/auto_upload_service.dart'; // ✅ [추가] 자동 업로드 서비스
import '../services/fcm_manager.dart'; // ✅ [추가] FCM 토큰 동기화

// 설정 및 테마 관련 Import
import 'settings_screen.dart';
import '../theme_state.dart';

class DiaryHomePage extends StatefulWidget {
  const DiaryHomePage({super.key});

  @override
  State<DiaryHomePage> createState() => _DiaryHomePageState();
}

class _DiaryHomePageState extends State<DiaryHomePage>
    with WidgetsBindingObserver {
  String _userName = '사용자';
  String _currentDocId = '';
  Timer? _timer; // ✅ [추가] 시간을 갱신할 타이머 변수

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // ✅ [추가] 라이프사이클 감시
    _initializeUser();

    // ✅ [추가] FCM 토큰 동기화 서비스 초기화 (시니어 → 보호자 토큰 자동 동기화)
    FCMManager().init();

    // ✅ [추가] 1분마다 화면을 갱신하여 시간을 업데이트하는 타이머 시작
    _startClockTimer();

    // ✅ [추가] 배터리 최적화 권한 미허용 시 재안내
    _checkBatteryOptimizationReminder();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // ✅ [추가]
    // ✅ [추가] 화면이 종료될 때 타이머 해제 (메모리 누수 방지)
    _timer?.cancel();
    super.dispose();
  }

  // ✅ [수정] 앱이 포그라운드로 돌아올 때 - main.dart에서 통합 처리하므로 여기서는 삭제
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 자동 업로드는 main.dart의 DiaryApp에서 통합 처리
    // 중복 호출 방지를 위해 여기서는 호출하지 않음
  }

  void _startClockTimer() {
    // 1초마다 혹은 1분마다 갱신 (여기선 배터리 효율을 위해 30초 간격 추천)
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        setState(() {
          // build가 다시 호출되면서 시간(DateTime.now)이 갱신됨
        });
      }
    });
  }

  /// ✅ [추가] 배터리 최적화 권한 미허용 시 재안내 (24시간에 1회)
  Future<void> _checkBatteryOptimizationReminder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final status = await Permission.ignoreBatteryOptimizations.status;

      // 마지막 알림 시간 확인 (24시간에 1번만)
      final lastReminder =
          prefs.getInt('battery_optimization_last_reminder') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      // 권한이 없고 24시간이 지났으면 안내
      if (!status.isGranted && (now - lastReminder) > 86400000) {
        await prefs.setInt('battery_optimization_last_reminder', now);

        // 약간의 딜레이 후 스낵바 표시 (화면 로딩 후)
        await Future.delayed(const Duration(seconds: 2));

        if (mounted) {
          _showBatteryOptimizationSnackbar();
        }
      }
    } catch (e) {
      debugPrint('배터리 최적화 확인 오류: $e');
    }
  }

  /// ✅ [추가] 배터리 최적화 재안내 스낵바
  void _showBatteryOptimizationSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.white, size: 24),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '백그라운드 실행 허용을 설정하면\n더 안정적으로 작동해요',
                style: TextStyle(fontSize: 15),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '설정',
          textColor: Colors.white,
          onPressed: () async {
            final status = await Permission.ignoreBatteryOptimizations
                .request();
            if (status.isGranted && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('✅ 백그라운드 실행이 허용되었습니다!'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          },
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _initializeUser() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. 현재 로그인한 '진짜' 유저 정보 가져오기
    final user = FirebaseAuth.instance.currentUser;

    // 로그인이 되어 있다면?
    if (user != null) {
      try {
        // [핵심 수정] 이메일 말고 'UID'로 문서를 찾는다!
        // 앱은 이제 "users" 방에서 "4iqLF..." 문서를 찾게 됨 -> 성공!
        DocumentSnapshot doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        String fetchedName = '사용자';

        // 2. 문서가 있으면 이름 꺼내기
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data != null) {
            // 형 DB에 있는 'name' 필드 확인
            if (data['name'] != null && data['name'].toString().isNotEmpty) {
              fetchedName = data['name']; // 여기서 "시니어"를 가져옴!
            }
            // 혹시 name이 없으면 userName 확인
            else if (data['userName'] != null &&
                data['userName'].toString().isNotEmpty) {
              fetchedName = data['userName'];
            }
          }
        }

        // 3. 만약 DB에서 못 가져왔다면? (백업 플랜)
        if (fetchedName == '사용자') {
          if (user.displayName != null && user.displayName!.isNotEmpty) {
            fetchedName = user.displayName!;
          } else if (user.email != null) {
            fetchedName = user.email!.split('@')[0];
          }
        }

        if (mounted) {
          setState(() {
            _userName = fetchedName;
            _currentDocId = user.uid; // 앞으로도 UID로 쓰도록 고정
          });
        }

        // 다음을 위해 폰에도 저장 (이름은 별도 키로 저장)
        await prefs.setString('currentUserName', fetchedName);
      } catch (e) {
        print("내 정보 로드 실패: $e");
      }
    } else {
      // 로그인 안 된 상태면 저장된 거라도 보여주기
      String cachedName = prefs.getString('currentUserName') ?? '';
      if (cachedName.isNotEmpty && cachedName != '사용자') {
        setState(() {
          _userName = cachedName;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [수정] setState가 호출될 때마다 현재 시간을 다시 가져옴
    DateTime now = DateTime.now();
    String dateStr = DateFormat('M월 d일 EEEE', 'ko_KR').format(now);
    String timeStr = DateFormat('a h:mm', 'ko_KR').format(now);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = AppButtonColors.getTextColor(context);

    // ✅ [작업1] 부드러운 테마 전환을 위한 AnimatedContainer 래핑
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      color: scaffoldColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          actions: [
            // ✅ [작업1] 테마 아이콘에 부드러운 전환 애니메이션 추가
            IconButton(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) => RotationTransition(
                  turns: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Icon(
                  isDark ? Icons.dark_mode : Icons.light_mode,
                  key: ValueKey<bool>(isDark),
                  color: textColor,
                ),
              ),
              onPressed: () => toggleTheme(),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              color: textColor,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Text(
                dateStr,
                style: TextStyle(
                  fontSize: 18,
                  color: AppButtonColors.getTextColor(
                    context,
                    isSecondary: true,
                  ),
                ),
              ),
              // ✅ [확인] 여기가 이제 실시간으로 바뀜
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? AppColors.darkPrimary
                      : const Color(0xFF2E7D32),
                ),
              ),
              const SizedBox(height: 30),
              Text(
                "$_userName님,\n오늘도 건강하세요! 🌸",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 40),

              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.8,
                children: [
                  _buildMenuCard(
                    context: context,
                    title: "추억 이야기\n(스토리텔링)",
                    subtitle: "오늘과 지난 추억 보기",
                    icon: Icons.auto_stories_rounded,
                    colorType: 'yellow',
                    onTap: () {
                      if (_currentDocId.isEmpty || _currentDocId == '사용자') {
                        // ID가 없으면 경고하되, 최대한 이메일이라도 쓰도록 처리
                        String effectiveId = _currentDocId.isEmpty
                            ? 'unknown'
                            : _currentDocId;

                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                StorytellingDateScreen(seniorId: effectiveId),
                          ),
                        );
                      } else {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                StorytellingDateScreen(seniorId: _currentDocId),
                          ),
                        );
                      }
                    },
                  ),
                  _buildMenuCard(
                    context: context,
                    title: "말동무\n(AI 대화)",
                    subtitle: "심심할 때 대화하기",
                    icon: Icons.smart_toy_rounded,
                    colorType: 'teal',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const VoiceChatScreen(),
                        ),
                      );
                    },
                  ),
                  _buildMenuCard(
                    context: context,
                    title: "지금 내 위치\n지도 보기",
                    subtitle: "나는 어디 있을까?",
                    icon: Icons.map_outlined,
                    colorType: 'purple',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const PatientMapPage(),
                        ),
                      );
                    },
                  ),
                  _buildMenuCard(
                    context: context,
                    title: "지난 이동\n기록 보기",
                    subtitle: "어디 갔었지?",
                    icon: Icons.history,
                    colorType: 'green',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const PatientHistoryPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ), // ✅ AnimatedContainer 닫기
    );
  }

  /// ✅ [개선] 메뉴 카드 - 다크모드 대응 + 보석톤 색상
  Widget _buildMenuCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required String colorType,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = AppButtonColors.getMenuCardColor(context, colorType);
    final iconColor = AppButtonColors.getIconColor(context, colorType);
    final titleColor = AppButtonColors.getCardTitleColor(context, colorType);
    final subtitleColor = AppButtonColors.getCardSubtitleColor(
      context,
      colorType,
    );
    final iconBgColor = isDark
        ? Colors.white.withOpacity(0.12)
        : Colors.white.withOpacity(0.9);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withOpacity(0.4)
                  : Colors.grey.withOpacity(0.1),
              blurRadius: isDark ? 15 : 10,
              offset: const Offset(0, 5),
            ),
          ],
          border: isDark
              ? Border.all(color: iconColor.withOpacity(0.2), width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconBgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 28),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: subtitleColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
