// lib/screens/storytelling_date_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'storytelling_screen.dart';
import '../theme_state.dart'; // 테마 시스템

class StorytellingDateScreen extends StatefulWidget {
  final String seniorId;

  const StorytellingDateScreen({super.key, required this.seniorId});

  // 테스트용 컬렉션 (나중에 'diary'로 변경)
  static const String _collection = 'diary';

  @override
  State<StorytellingDateScreen> createState() => _StorytellingDateScreenState();
}

class _StorytellingDateScreenState extends State<StorytellingDateScreen> {
  bool _loading = true;
  List<String> _dates = [];
  String? _latestDate;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchDates();
  }

  Future<void> _fetchDates() async {
    if (widget.seniorId.isEmpty) {
      setState(() {
        _loading = false;
        _errorMessage = '사용자 ID가 올바르지 않습니다.';
      });
      return;
    }

    try {
      debugPrint('📅 [날짜선택] 조회 대상 seniorId: ${widget.seniorId}');

      // 1. users 컬렉션 -> 해당 유저 -> diary 컬렉션 조회
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.seniorId)
          .collection(StorytellingDateScreen._collection)
          .get();

      if (!mounted) return;

      if (snapshot.docs.isEmpty) {
        // 컬렉션이 없으면 혹시 문서 필드(Project A 레거시 방식)로 저장되어 있는지 2차 확인
        await _fetchDatesFromUserDoc();
        return;
      }

      // 2. 문서 ID(날짜) 리스트 추출 및 정렬 (최신순)
      final dates = snapshot.docs.map((doc) => doc.id).toList();
      dates.sort((a, b) => b.compareTo(a));

      debugPrint('📅 [날짜선택] 가져온 날짜들: $dates');

      setState(() {
        _dates = dates;
        _latestDate = dates.isNotEmpty ? dates.first : null;
        _loading = false;
      });
    } catch (e) {
      debugPrint('❌ [날짜선택] 오류: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = '추억을 불러오는 중 문제가 발생했어요.';
        });
      }
    }
  }

  // (Project A 레거시 데이터 구조 대응용 - 필요 없다면 나중에 삭제 가능)
  Future<void> _fetchDatesFromUserDoc() async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.seniorId)
          .get();

      if (!mounted) return;

      if (!userDoc.exists) {
        setState(() {
          _loading = false;
          _errorMessage = '아직 저장된 추억이 없습니다.';
        });
        return;
      }

      final data = userDoc.data();
      final raw = data?[StorytellingDateScreen._collection];

      List<String> dates = [];
      if (raw is List) {
        dates = raw.map((e) => e.toString()).toList();
      } else if (raw is Map) {
        dates = raw.keys.map((e) => e.toString()).toList();
      }

      dates = dates.where((e) => e.trim().isNotEmpty).toList();
      dates.sort((a, b) => b.compareTo(a));

      if (dates.isEmpty) {
        setState(() {
          _loading = false;
          _errorMessage = '아직 저장된 추억이 없습니다.';
        });
        return;
      }

      setState(() {
        _dates = dates;
        _latestDate = dates.first;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = '데이터 오류가 발생했습니다.';
        });
      }
    }
  }

  void _navigateToStory(String date) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StorytellingScreen(
          seniorId: widget.seniorId, // ✅ ID 전달
          date: date,
          collection: StorytellingDateScreen._collection,
        ),
      ),
    );
  }

  String _formatDateForDisplay(String date) {
    try {
      final parts = date.split('-');
      if (parts.length == 3) {
        return '${parts[0]}년 ${int.parse(parts[1])}월 ${int.parse(parts[2])}일';
      }
    } catch (_) {}
    return date;
  }

  String _getRelativeDate(String date) {
    try {
      final dateTime = DateTime.parse(date);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final targetDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
      final difference = today.difference(targetDate).inDays;

      if (difference == 0) return '오늘';
      if (difference == 1) return '어제';
      if (difference == 2) return '그저께';
      if (difference <= 7) return '$difference일 전';
      return '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 테마에 따른 그라데이션 색상
    final gradientColors = isDark
        ? [
            AppColors.darkBackground,
            const Color(0xFF2D3561),
            AppColors.darkBackground,
          ]
        : [
            const Color(0xFFF5F0E8),
            const Color(0xFFE8E0D4),
            const Color(0xFFF5F0E8),
          ];

    final textColor = isDark ? Colors.white : const Color(0xFF1A1F3C);
    final subtextColor = isDark
        ? Colors.white70
        : const Color(0xFF1A1F3C).withOpacity(0.7);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: gradientColors,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(isDark, textColor),
              Expanded(
                child: _loading
                    ? _buildLoading(isDark, subtextColor)
                    : _errorMessage != null
                    ? _buildError(isDark, textColor, subtextColor)
                    : _buildContent(isDark, textColor, subtextColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(bool isDark, Color textColor) {
    final buttonBgColor = isDark
        ? Colors.white.withOpacity(0.1)
        : const Color(0xFF1A1F3C).withOpacity(0.1);
    final buttonBorderColor = isDark
        ? Colors.white.withOpacity(0.2)
        : const Color(0xFF1A1F3C).withOpacity(0.2);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // 뒤로가기 버튼
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: buttonBgColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: buttonBorderColor),
              ),
              child: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: textColor,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 타이틀
          Text(
            '나의 추억 이야기',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: textColor,
              fontFamily: 'PyeongtaekSemiconductor',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(bool isDark, Color subtextColor) {
    final indicatorColor = isDark
        ? const Color(0xFFFFE4D6)
        : const Color(0xFF7B68EE);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: indicatorColor, strokeWidth: 3),
          const SizedBox(height: 24),
          Text(
            '추억을 불러오는 중...',
            style: TextStyle(
              fontSize: 20,
              color: subtextColor,
              fontFamily: 'PyeongtaekSemiconductor',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(bool isDark, Color textColor, Color subtextColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.sentiment_dissatisfied_rounded,
            size: 80,
            color: textColor.withOpacity(0.5),
          ),
          const SizedBox(height: 24),
          Text(
            _errorMessage ?? '오류가 발생했습니다',
            style: TextStyle(
              fontSize: 22,
              color: subtextColor,
              fontFamily: 'PyeongtaekSemiconductor',
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          // 다시 시도 버튼
          GestureDetector(
            onTap: () {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
              _fetchDates();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B9D), Color(0xFFC86DD7)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '다시 시도',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontFamily: 'PyeongtaekSemiconductor',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isDark, Color textColor, Color subtextColor) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // ===== 상단: 가장 최근 날짜 (당일) 스토리텔링 버튼 (크게) =====
          if (_latestDate != null) _buildLatestDateCard(),

          const SizedBox(height: 24),

          // ===== 하단: 이전 날짜들 리스트 =====
          if (_dates.length > 1) ...[
            // 제목
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 12),
                child: Text(
                  '지난 추억 보기',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: textColor.withOpacity(0.8),
                    fontFamily: 'PyeongtaekSemiconductor',
                  ),
                ),
              ),
            ),
            // 이전 날짜 리스트
            Expanded(
              child: _buildPreviousDates(isDark, textColor, subtextColor),
            ),
          ] else ...[
            // 이전 날짜가 없을 때
            Expanded(
              child: Center(
                child: Text(
                  '아직 이전 추억이 없어요',
                  style: TextStyle(
                    fontSize: 18,
                    color: textColor.withOpacity(0.5),
                    fontFamily: 'PyeongtaekSemiconductor',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLatestDateCard() {
    final relativeDate = _getRelativeDate(_latestDate!);
    final displayDate = _formatDateForDisplay(_latestDate!);

    return GestureDetector(
      onTap: () => _navigateToStory(_latestDate!),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF6B9D), Color(0xFFC86DD7), Color(0xFF7B68EE)],
          ),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF6B9D).withOpacity(0.4),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          children: [
            // 아이콘
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_stories_rounded,
                size: 48,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 20),

            // 상대적 날짜 (오늘, 어제 등)
            if (relativeDate.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  relativeDate,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: 'PyeongtaekSemiconductor',
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // 날짜
            Text(
              displayDate,
              style: TextStyle(
                fontSize: 22,
                color: Colors.white.withOpacity(0.9),
                fontFamily: 'PyeongtaekSemiconductor',
              ),
            ),
            const SizedBox(height: 20),

            // 버튼 텍스트
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.play_circle_filled_rounded,
                    size: 28,
                    color: Color(0xFFFF6B9D),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '스토리 보기',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1F3C),
                      fontFamily: 'PyeongtaekSemiconductor',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviousDates(bool isDark, Color textColor, Color subtextColor) {
    // 첫 번째(가장 최근)를 제외한 나머지 날짜들
    final previousDates = _dates.skip(1).toList();

    final cardBgColor = isDark
        ? Colors.white.withOpacity(0.08)
        : const Color(0xFF1A1F3C).withOpacity(0.05);
    final cardBorderColor = isDark
        ? Colors.white.withOpacity(0.15)
        : const Color(0xFF1A1F3C).withOpacity(0.1);
    final iconBgColor = isDark
        ? const Color(0xFFC86DD7).withOpacity(0.3)
        : const Color(0xFFC86DD7).withOpacity(0.2);
    final iconColor = isDark ? Colors.white : const Color(0xFF7B68EE);

    return ListView.builder(
      itemCount: previousDates.length,
      itemBuilder: (context, index) {
        final date = previousDates[index];
        final relativeDate = _getRelativeDate(date);
        final displayDate = _formatDateForDisplay(date);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GestureDetector(
            onTap: () => _navigateToStory(date),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
              decoration: BoxDecoration(
                color: cardBgColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cardBorderColor),
              ),
              child: Row(
                children: [
                  // 날짜 아이콘
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: iconBgColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.calendar_today_rounded,
                      size: 24,
                      color: iconColor,
                    ),
                  ),
                  const SizedBox(width: 16),

                  // 날짜 텍스트
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayDate,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                            fontFamily: 'PyeongtaekSemiconductor',
                          ),
                        ),
                        if (relativeDate.isNotEmpty)
                          Text(
                            relativeDate,
                            style: TextStyle(
                              fontSize: 14,
                              color: subtextColor,
                              fontFamily: 'PyeongtaekSemiconductor',
                            ),
                          ),
                      ],
                    ),
                  ),

                  // 화살표
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 20,
                    color: textColor.withOpacity(0.5),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
