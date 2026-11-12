// lib/screens/guardian_home_page.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';

import 'login_page.dart';
import 'guardian_map_page.dart';
import 'care_target_medication_page.dart';
import 'guardian_history_page.dart';
import 'guardian_calendar_page.dart';
import '../services/fcm_manager.dart';
import '../services/withdrawal_service.dart';

// ✅ [추가] 필요한 파일 Import
import '../theme_state.dart';
import 'settings_screen.dart';
import 'connect_care_target_page.dart';
import 'cluster_labeling_page.dart';
import 'safety_zone_page.dart'; // ✅ [필수] 안심 구역 페이지 임포트

class GuardianHomePage extends StatefulWidget {
  // 로그인 시 넘겨받은 환자 ID (없으면 DB에서 조회)
  final String? patientId;

  const GuardianHomePage({super.key, this.patientId});

  @override
  State<GuardianHomePage> createState() => _GuardianHomePageState();
}

class _GuardianHomePageState extends State<GuardianHomePage> {
  String _userName = '사용자';
  String _currentDocId = '';
  bool _isConnected = false;
  String? _seniorId;
  String _patientName = "대상자";
  String? _seniorFcmToken;

  @override
  void initState() {
    super.initState();
    _initializeUserAndData();
    FCMManager().init();

    // ✅ 만약 생성자에서 전달받은 patientId가 있다면 그걸 우선 사용 (알림 타고 들어온 경우 등)
    if (widget.patientId != null) {
      _listenToPatientStatus(widget.patientId!);
    }
  }

  // 👤 사용자 데이터 초기화
  Future<void> _initializeUserAndData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _currentDocId = user.uid; // UID 사용
    String realName = user.displayName ?? '사용자';

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentDocId)
          .get();

      if (doc.exists && doc.data() != null) {
        realName = doc.data()!['name'] ?? realName;
      }
    } catch (e) {
      debugPrint("이름 불러오기 실패: $e");
    }

    if (mounted) {
      setState(() {
        _userName = realName;
      });
    }
    _checkConnectionStatus();
  }

  // 🔗 연결 상태 확인 (DB 필드 seniorId 확인)
  Future<void> _checkConnectionStatus() async {
    if (_currentDocId.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentDocId)
          .get();
      if (doc.exists) {
        final data = doc.data();
        if (data != null &&
            data['seniorId'] != null &&
            data['seniorId'].toString().isNotEmpty) {
          setState(() {
            _isConnected = true;
            _seniorId = data['seniorId'];
          });
          _loadSeniorInfo(_seniorId!);
          _listenToPatientStatus(_seniorId!); // ✅ 연결 확인 후 상태 리스너 등록
        } else {
          setState(() {
            _isConnected = false;
            _seniorId = null;
          });
        }
      }
    } catch (e) {
      debugPrint("연결 확인 중 오류: $e");
    }
  }

  // 👴 시니어 정보 로드
  Future<void> _loadSeniorInfo(String targetId) async {
    try {
      final targetDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetId)
          .get();
      if (targetDoc.exists) {
        setState(() {
          _patientName = targetDoc.data()?['name'] ?? "대상자";
          _seniorFcmToken = targetDoc.data()?['fcmToken'];
        });
      }
    } catch (e) {
      debugPrint("대상자 정보 로드 실패: $e");
    }
  }

  // 🚨 [추가] 환자 상태 실시간 리스너 (지오펜싱 알림용)
  void _listenToPatientStatus(String targetId) {
    FirebaseFirestore.instance
        .collection('users')
        .doc(targetId)
        .snapshots()
        .listen((snapshot) {
          if (snapshot.exists) {
            final data = snapshot.data() as Map<String, dynamic>;
            final status = data['status']; // 'safe' 또는 'emergency'

            // 상태가 'emergency'로 바뀌면 경고창 띄움
            if (status == 'emergency') {
              if (mounted) {
                _showEmergencyDialog(
                  data['alertMessage'] ?? "환자가 안전 구역을 벗어났습니다!",
                );
              }
            }
          }
        });
  }

  // 🚨 경고 알림창 표시 (개선: 문구 변경 + 전화 걸기 + 위치 보기 이동)
  void _showEmergencyDialog(String message) async {
    // 시니어의 전화번호 가져오기
    String? seniorPhone;
    try {
      if (_seniorId != null) {
        final seniorDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_seniorId)
            .get();
        if (seniorDoc.exists) {
          seniorPhone = seniorDoc.data()?['phone'];
        }
      }
    } catch (e) {
      debugPrint("시니어 전화번호 조회 실패: $e");
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.red[50],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 30),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                "안심 구역 이탈 알림",
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "$_patientName님이 설정된 안심 구역을 벗어났습니다.",
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "현재 위치를 확인하시고, 필요 시 연락해주세요.",
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          // 전화 걸기 버튼
          if (seniorPhone != null && seniorPhone.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final Uri phoneUri = Uri(scheme: 'tel', path: seniorPhone);
                if (await canLaunchUrl(phoneUri)) {
                  await launchUrl(phoneUri);
                }
              },
              icon: const Icon(Icons.phone, color: Colors.green),
              label: const Text(
                "전화 걸기",
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          // 위치 확인 버튼 → 지도 페이지로 이동
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(context); // 다이얼로그 닫기
              // 상태를 safe로 되돌림 (알림 해제)
              if (_seniorId != null) {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(_seniorId)
                    .update({'status': 'safe'});
              }
              // 위치 보기 화면으로 이동
              if (_seniorId != null && mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GuardianMapPage(
                      patientId: _seniorId!,
                      patientName: _patientName,
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.location_on, color: Colors.blue),
            label: const Text(
              "위치 확인",
              style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    DateTime now = DateTime.now();
    String dateStr = DateFormat('M월 d일 EEEE', 'ko_KR').format(now);

    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    final horizontalPadding = screenWidth * 0.06;
    final baseFontSize = screenWidth * 0.045;
    final titleFontSize = (screenWidth * 0.055).clamp(18.0, 26.0);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? AppColors.darkBackground
        : AppColors.lightBackground;
    final textColor = isDark
        ? AppColors.darkOnSurface
        : AppColors.lightOnSurface;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            floating: true,
            snap: true,
            automaticallyImplyLeading: false,
            actions: [
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
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsScreen(),
                    ),
                  );
                },
              ),
              SizedBox(width: horizontalPadding * 0.3),
            ],
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                SizedBox(height: screenHeight * 0.02),
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: baseFontSize * 0.9,
                    color: Colors.grey,
                  ),
                ),
                SizedBox(height: screenHeight * 0.015),
                LayoutBuilder(
                  builder: (context, constraints) {
                    return Text(
                      "$_userName님,\n오늘도 케어해주셔서 감사합니다 💚",
                      style: TextStyle(
                        fontSize: titleFontSize,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
                SizedBox(height: screenHeight * 0.025),

                // 시니어 상태 카드
                _buildFullStatusCard(screenWidth, screenHeight),

                SizedBox(height: screenHeight * 0.025),

                // ✅ 케어 기능 그리드 (여기에 얼굴인식, 안심구역 포함됨)
                _buildNewMenuGrid(isDark, textColor, screenWidth, screenHeight),

                SizedBox(height: screenHeight * 0.04),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // 🏥 환자 상태 요약 카드
  Widget _buildFullStatusCard(double screenWidth, double screenHeight) {
    final cardPadding = (screenWidth * 0.045).clamp(16.0, 24.0);
    final iconSize = (screenWidth * 0.09).clamp(32.0, 44.0);
    final titleFontSize = (screenWidth * 0.05).clamp(18.0, 22.0);

    // 1. 연결된 시니어가 없을 때
    if (_seniorId == null || _seniorId!.isEmpty) {
      return GestureDetector(
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const ConnectCareTargetPage(),
            ),
          );
          if (result == true) {
            _initializeUserAndData();
          }
        },
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(cardPadding),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(cardPadding * 0.5),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_add_rounded,
                  color: const Color(0xFF2E7D32),
                  size: iconSize,
                ),
              ),
              SizedBox(height: screenHeight * 0.015),
              Text(
                "케어 대상자 연결하기",
                style: TextStyle(
                  fontSize: titleFontSize,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF2E7D32),
                ),
              ),
              SizedBox(height: screenHeight * 0.008),
              Text(
                "어르신의 초대 코드를 입력해주세요",
                style: TextStyle(
                  fontSize: titleFontSize * 0.7,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 2. 연결되었을 때
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(_seniorId)
          .collection('medication_logs')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, medicationSnapshot) {
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(_seniorId)
              .snapshots(),
          builder: (context, locationSnapshot) {
            String todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
            int todayTakeCount = 0;
            String lastTakenTimeStr = "";
            if (medicationSnapshot.hasData &&
                medicationSnapshot.data!.docs.isNotEmpty) {
              var todayLogs = medicationSnapshot.data!.docs.where((doc) {
                var d = doc.data() as Map<String, dynamic>;
                return d['date'] == todayStr && d['isTaken'] == true;
              }).toList();
              todayTakeCount = todayLogs.length;
              if (todayLogs.isNotEmpty) {
                Timestamp ts =
                    (todayLogs.first.data()
                        as Map<String, dynamic>)['timestamp'];
                lastTakenTimeStr = DateFormat(
                  'a h:mm',
                  'ko_KR',
                ).format(ts.toDate());
              }
            }

            String addressDisplay = "위치 확인 중...";
            if (locationSnapshot.hasData && locationSnapshot.data!.exists) {
              var data = locationSnapshot.data!.data() as Map<String, dynamic>;
              double lat = data['currentLat']?.toDouble() ?? 0.0;
              double lng = data['currentLng']?.toDouble() ?? 0.0;

              if (lat == 0.0) {
                return _buildCardUI(
                  todayTakeCount,
                  lastTakenTimeStr,
                  "위치 정보 없음",
                  screenWidth,
                  screenHeight,
                );
              }

              return FutureBuilder<List<Placemark>>(
                future: () async {
                  try {
                    // ignore: deprecated_member_use
                    await setLocaleIdentifier("ko_KR");
                    return await placemarkFromCoordinates(lat, lng);
                  } catch (e) {
                    return <Placemark>[];
                  }
                }(),
                builder: (context, geoSnapshot) {
                  if (geoSnapshot.hasData && geoSnapshot.data!.isNotEmpty) {
                    final place = geoSnapshot.data![0];
                    String name = place.name ?? "";
                    if (name.isNotEmpty &&
                        !RegExp(r'^[0-9-]+$').hasMatch(name)) {
                      addressDisplay = name;
                    } else {
                      addressDisplay =
                          "${place.locality} ${place.thoroughfare} $name"
                              .replaceAll(RegExp(r'\s+'), ' ')
                              .trim();
                    }
                  }
                  return _buildCardUI(
                    todayTakeCount,
                    lastTakenTimeStr,
                    addressDisplay,
                    screenWidth,
                    screenHeight,
                  );
                },
              );
            }
            return _buildCardUI(
              todayTakeCount,
              lastTakenTimeStr,
              "위치 신호 대기 중...",
              screenWidth,
              screenHeight,
            );
          },
        );
      },
    );
  }

  Widget _buildCardUI(
    int takeCount,
    String lastTime,
    String address,
    double screenWidth,
    double screenHeight,
  ) {
    bool isTakenAtLeastOnce = takeCount > 0;
    final cardPadding = (screenWidth * 0.045).clamp(14.0, 20.0);
    final iconSize = (screenWidth * 0.055).clamp(20.0, 26.0);
    final nameFontSize = (screenWidth * 0.052).clamp(18.0, 24.0);
    final contentFontSize = (screenWidth * 0.038).clamp(13.0, 16.0);
    final smallFontSize = (screenWidth * 0.032).clamp(11.0, 14.0);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isTakenAtLeastOnce
              ? [const Color(0xFF66BB6A), const Color(0xFF43A047)]
              : [const Color(0xFFFFA726), const Color(0xFFFB8C00)],
        ),
        boxShadow: [
          BoxShadow(
            color: (isTakenAtLeastOnce ? Colors.green : Colors.orange)
                .withOpacity(0.25),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(cardPadding * 0.45),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.person, color: Colors.white, size: iconSize),
              ),
              SizedBox(width: screenWidth * 0.03),
              Expanded(
                child: Text(
                  "$_patientName님",
                  style: TextStyle(
                    fontSize: nameFontSize,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: screenHeight * 0.015),
          Container(height: 1, color: Colors.white.withOpacity(0.3)),
          SizedBox(height: screenHeight * 0.012),
          Row(
            children: [
              Icon(
                isTakenAtLeastOnce ? Icons.check_circle : Icons.warning_rounded,
                color: Colors.white,
                size: iconSize * 0.85,
              ),
              SizedBox(width: screenWidth * 0.02),
              Expanded(
                child: Text(
                  isTakenAtLeastOnce
                      ? "오늘 $takeCount회 복용 완료"
                      : "아직 약을 드시지 않았어요",
                  style: TextStyle(
                    fontSize: contentFontSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (isTakenAtLeastOnce && lastTime.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: screenWidth * 0.07, top: 3),
              child: Text(
                "마지막 복용: $lastTime",
                style: TextStyle(
                  fontSize: smallFontSize,
                  color: Colors.white.withOpacity(0.85),
                ),
              ),
            ),
          SizedBox(height: screenHeight * 0.01),
          Row(
            children: [
              Icon(
                Icons.location_on,
                color: Colors.white.withOpacity(0.9),
                size: iconSize * 0.85,
              ),
              SizedBox(width: screenWidth * 0.02),
              Expanded(
                child: Text(
                  address,
                  style: TextStyle(
                    fontSize: smallFontSize,
                    color: Colors.white.withOpacity(0.9),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 📱 케어 기능 그리드
  Widget _buildNewMenuGrid(
    bool isDark,
    Color textColor,
    double screenWidth,
    double screenHeight,
  ) {
    final crossAxisSpacing = screenWidth * 0.04;
    final mainAxisSpacing = screenHeight * 0.018;
    final childAspectRatio = (screenWidth / screenHeight) * 1.8;

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      childAspectRatio: childAspectRatio.clamp(0.95, 1.15),
      children: [
        _buildNewMenuCard(
          title: "$_patientName님\n위치 보기",
          subtitle: "현재 위치 확인",
          icon: Icons.location_on_rounded,
          colorType: 'blue',
          onTap: () => _handleNewMenuTap("위치 보기"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
        _buildNewMenuCard(
          title: "지난 이동 \n기록 보기",
          subtitle: "지난 동선 확인",
          icon: Icons.route_rounded,
          colorType: 'orange',
          onTap: () => _handleNewMenuTap("이동 기록"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
        _buildNewMenuCard(
          title: "$_patientName님\n일지 작성",
          subtitle: "건강 기록 관리",
          icon: Icons.edit_note_rounded,
          colorType: 'teal',
          onTap: () => _handleNewMenuTap("환자 일지"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
        _buildNewMenuCard(
          title: "약 알림\n관리",
          subtitle: "복용 시간 설정",
          icon: Icons.medication_rounded,
          colorType: 'green',
          onTap: () => _handleNewMenuTap("약 알림"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
        // ✅ [수정] 얼굴 인식 버튼을 그리드로 이동
        _buildNewMenuCard(
          title: "얼굴 인식\n관리",
          subtitle: "인물 사진 식별",
          icon: Icons.face_retouching_natural_rounded,
          colorType: 'purple',
          onTap: () => _handleNewMenuTap("얼굴 인식"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
        // ✅ [추가] 안심 구역 설정 버튼 추가
        _buildNewMenuCard(
          title: "안심 구역\n설정",
          subtitle: "이탈 감지 반경",
          icon: Icons.security_rounded,
          colorType:
              'red', // 빨간색 계열 테마 (AppButtonColors에 'red'가 없다면 분홍색 등으로 매핑됨)
          onTap: () => _handleNewMenuTap("안심 구역"),
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
      ],
    );
  }

  Widget _buildNewMenuCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String colorType,
    required VoidCallback onTap,
    required double screenWidth,
    required double screenHeight,
  }) {
    final cardPadding = (screenWidth * 0.035).clamp(12.0, 18.0);
    final iconContainerSize = (screenWidth * 0.1).clamp(36.0, 48.0);
    final iconSize = (screenWidth * 0.06).clamp(22.0, 30.0);
    final titleFontSize = (screenWidth * 0.052).clamp(18.0, 22.0);
    final subtitleFontSize = (screenWidth * 0.032).clamp(12.0, 14.0);

    // AppButtonColors에 'red' 타입이 없다면 'purple' 등을 사용하거나 theme_state.dart에 추가 필요
    // 여기서는 기본적으로 'purple', 'blue' 등이 있다고 가정. 'red'가 없으면 default로 떨어질 수 있음.
    final cardColor = AppButtonColors.getMenuCardColor(context, colorType);
    final iconColor = AppButtonColors.getIconColor(context, colorType);
    final titleColor = AppButtonColors.getCardTitleColor(context, colorType);
    final subtitleColor = AppButtonColors.getCardSubtitleColor(
      context,
      colorType,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(cardPadding),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(18),
          border: isDark
              ? Border.all(color: iconColor.withOpacity(0.3), width: 1)
              : null,
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: iconContainerSize,
              height: iconContainerSize,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurfaceVariant : Colors.white,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(icon, color: iconColor, size: iconSize),
              ),
            ),
            SizedBox(height: screenHeight * 0.012),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: titleFontSize,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                      height: 1.15,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: screenHeight * 0.004),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: subtitleFontSize,
                      color: subtitleColor,
                    ),
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

  void _handleNewMenuTap(String action) {
    if (_seniorId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("연결된 케어 대상자가 없습니다.")));
      return;
    }

    switch (action) {
      case "위치 보기":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GuardianMapPage(
              patientId: _seniorId!,
              patientName: _patientName,
            ),
          ),
        );
        break;
      case "이동 기록":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GuardianHistoryPage(
              patientId: _seniorId!,
              patientName: _patientName,
            ),
          ),
        );
        break;
      case "환자 일지":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GuardianCalendarPage(
              patientId: _seniorId!,
              patientName: _patientName,
            ),
          ),
        );
        break;
      case "약 알림":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CareTargetMedicationPage(
              careTargetId: _seniorId!,
              careTargetName: _patientName,
              careTargetFcmToken: _seniorFcmToken,
            ),
          ),
        );
        break;
      // ✅ [수정] 핸들러 추가
      case "얼굴 인식":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                ClusterLabelingPage(currentUserUid: _currentDocId),
          ),
        );
        break;
      // ✅ [추가] 안심 구역 페이지 연결
      case "안심 구역":
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SafetyZonePage(patientId: _seniorId!),
          ),
        );
        break;
    }
  }
}
