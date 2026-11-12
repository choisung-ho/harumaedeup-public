import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'medicine_setup_page.dart'; // ✅ 새로 만든 약 알림 설정 화면
import 'medicine_edit_page.dart'; // ✅ 약 알림 수정 화면
import '../theme_state.dart'; // 테마 시스템

class CareTargetMedicationPage extends StatefulWidget {
  final String careTargetId;
  final String careTargetName;
  final String? careTargetFcmToken; // ✅ 토큰 필수

  const CareTargetMedicationPage({
    super.key,
    required this.careTargetId,
    required this.careTargetName,
    this.careTargetFcmToken,
  });

  @override
  State<CareTargetMedicationPage> createState() =>
      _CareTargetMedicationPageState();
}

class _CareTargetMedicationPageState extends State<CareTargetMedicationPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? AppColors.darkBackground
        : const Color(0xFFF5F5F5);
    final surfaceColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black;
    final subtextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF2E7D32);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "${widget.careTargetName}님의 약 관리",
          style: TextStyle(color: textColor),
        ),
        backgroundColor: surfaceColor,
        foregroundColor: textColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        bottom: TabBar(
          controller: _tabController,
          labelColor: accentColor,
          unselectedLabelColor: subtextColor,
          indicatorColor: accentColor,
          tabs: const [
            Tab(text: "복용 기록 확인"),
            Tab(text: "알림 시간 설정"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _MedicationHistoryTab(
            careTargetId: widget.careTargetId,
            careTargetName: widget.careTargetName,
            careTargetFcmToken: widget.careTargetFcmToken,
          ),
          _MedicationSettingTab(
            careTargetId: widget.careTargetId,
            careTargetName: widget.careTargetName,
            careTargetFcmToken: widget.careTargetFcmToken, // ✅ 토큰 전달
          ),
        ],
      ),
    );
  }
}

// 탭 1: 복용 기록 확인 (기존 코드 유지)
class _MedicationHistoryTab extends StatefulWidget {
  final String careTargetId;
  final String careTargetName;
  final String? careTargetFcmToken;

  const _MedicationHistoryTab({
    required this.careTargetId,
    required this.careTargetName,
    this.careTargetFcmToken,
  });

  @override
  State<_MedicationHistoryTab> createState() => _MedicationHistoryTabState();
}

class _MedicationHistoryTabState extends State<_MedicationHistoryTab> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // medicine_result 데이터를 날짜별로 캐싱
  Map<String, List<Map<String, dynamic>>> _medicationResults = {};

  // 스트림 캐싱
  late final Stream<QuerySnapshot> _medicationResultStream;
  bool _isFirstLoad = true;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    // medicine_result 컬렉션 스트림
    _medicationResultStream = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.careTargetId)
        .collection('medicine_result')
        .snapshots();
  }

  // 날짜 선택 시 호출
  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!isSameDay(_selectedDay, selectedDay)) {
      setState(() {
        _selectedDay = selectedDay;
        _focusedDay = focusedDay;
      });
    }
  }

  // 날짜 키 생성 (yyyy-MM-dd)
  String _getDateKey(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return StreamBuilder<QuerySnapshot>(
      stream: _medicationResultStream,
      builder: (context, snapshot) {
        if (_isFirstLoad &&
            snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(
              color: isDark ? AppColors.darkPrimary : const Color(0xFF2E7D32),
            ),
          );
        }

        if (snapshot.hasData) {
          _isFirstLoad = false;
          _parseResults(snapshot.data!.docs);
        }

        // 선택된 날짜의 복용 기록
        final selectedDateKey = _getDateKey(_selectedDay ?? DateTime.now());
        final selectedDayLogs = _medicationResults[selectedDateKey] ?? [];

        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    _buildCalendar(isDark),
                    const SizedBox(height: 16),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                      child: _buildMedicationResultCard(
                        selectedDayLogs,
                        isDark,
                        key: ValueKey(_selectedDay),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // medicine_result 문서들을 파싱
  void _parseResults(List<QueryDocumentSnapshot> docs) {
    final newResults = <String, List<Map<String, dynamic>>>{};

    for (var doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final dateKey = doc.id; // 문서 ID가 날짜 (예: 2026-02-02)
      final logs = data['logs'] as List<dynamic>? ?? [];

      newResults[dateKey] = logs.map((log) {
        final logMap = log as Map<String, dynamic>;
        return {
          'medication_name': logMap['medication_name'] ?? '약',
          'medicine_id': logMap['medicine_id'] ?? '',
          'status': logMap['status'] ?? 'unknown',
          'timestamp': logMap['timestamp'] ?? '',
          'recorded_at': logMap['recorded_at'],
          'retry_count': logMap['retry_count'] ?? 0,
        };
      }).toList();
    }

    _medicationResults = newResults;
  }

  Widget _buildCalendar(bool isDark) {
    final cardColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subtextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.black54;
    final headerBtnColor = isDark
        ? AppColors.darkSurfaceVariant
        : Colors.grey.shade100;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF5C6BC0);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.3)
                : Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TableCalendar(
        locale: 'ko_KR',
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: DateTime.utc(2030, 12, 31),
        focusedDay: _focusedDay,
        calendarFormat: CalendarFormat.month,
        selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
        onDaySelected: _onDaySelected,
        eventLoader: (day) {
          // 해당 날짜에 복용 기록이 있는지 확인
          final dateKey = _getDateKey(day);
          final logs = _medicationResults[dateKey] ?? [];
          if (logs.isNotEmpty) {
            // 복용 완료가 하나라도 있으면 마커 표시
            final hasTaken = logs.any((log) => log['status'] == 'taken');
            final hasMissed = logs.any(
              (log) => log['status'] == 'missed' || log['status'] == 'skipped',
            );
            if (hasTaken) return ['taken'];
            if (hasMissed) return ['missed'];
          }
          return [];
        },
        calendarBuilders: CalendarBuilders(
          markerBuilder: (context, day, events) {
            if (events.isEmpty) return null;
            final isTaken = events.contains('taken');
            return Positioned(
              bottom: 4,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isTaken
                      ? const Color(0xFF66BB6A)
                      : const Color(0xFFFF6B6B),
                  shape: BoxShape.circle,
                ),
              ),
            );
          },
        ),
        calendarStyle: CalendarStyle(
          markerDecoration: const BoxDecoration(
            color: Color(0xFF66BB6A),
            shape: BoxShape.circle,
          ),
          markerSize: 6,
          markersMaxCount: 1,
          todayDecoration: BoxDecoration(
            color: accentColor.withOpacity(0.3),
            shape: BoxShape.circle,
          ),
          todayTextStyle: TextStyle(
            color: accentColor,
            fontWeight: FontWeight.bold,
          ),
          selectedDecoration: BoxDecoration(
            color: accentColor,
            shape: BoxShape.circle,
          ),
          selectedTextStyle: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
          defaultTextStyle: TextStyle(fontSize: 14, color: textColor),
          weekendTextStyle: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFFFF8A80) : Colors.red,
          ),
          outsideDaysVisible: false,
        ),
        headerStyle: HeaderStyle(
          formatButtonVisible: false,
          titleCentered: true,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
          leftChevronIcon: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: headerBtnColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.chevron_left, color: subtextColor),
          ),
          rightChevronIcon: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: headerBtnColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.chevron_right, color: subtextColor),
          ),
          headerPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: TextStyle(
            color: subtextColor,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          weekendStyle: TextStyle(
            color: isDark ? const Color(0xFFFF8A80) : Colors.red,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  // ✅ 새로운 복용 결과 카드 UI
  Widget _buildMedicationResultCard(
    List<Map<String, dynamic>> logs,
    bool isDark, {
    Key? key,
  }) {
    final selectedDate = _selectedDay ?? DateTime.now();
    final isToday = isSameDay(selectedDate, DateTime.now());
    final cardColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.grey.shade700;
    final subtextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.grey.shade500;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF5C6BC0);

    // 복용 통계 계산
    final takenCount = logs.where((l) => l['status'] == 'taken').length;
    final missedCount = logs
        .where((l) => l['status'] == 'missed' || l['status'] == 'skipped')
        .length;
    final totalCount = logs.length;

    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.3)
                : Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 날짜 헤더
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark
                  ? accentColor.withOpacity(0.1)
                  : accentColor.withOpacity(0.05),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 18,
                  color: accentColor,
                ),
                const SizedBox(width: 8),
                Text(
                  DateFormat('M월 d일 (E)', 'ko_KR').format(selectedDate),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                if (isToday) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      "오늘",
                      style: TextStyle(
                        fontSize: 12,
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 기록이 없는 경우
          if (logs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: subtextColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.medication_outlined,
                      size: 40,
                      color: subtextColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "복용 기록 없음",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: subtextColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isToday ? "아직 약 복용 기록이 없습니다" : "이 날은 약 복용 기록이 없습니다",
                    style: TextStyle(
                      fontSize: 14,
                      color: subtextColor.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            // 복용 요약 통계
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.check_circle_rounded,
                      label: "복용",
                      count: takenCount,
                      color: const Color(0xFF66BB6A),
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.cancel_rounded,
                      label: "미복용",
                      count: missedCount,
                      color: const Color(0xFFFF6B6B),
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ),

            // 약별 상세 리스트
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "상세 기록",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...logs.map((log) => _buildMedicationLogItem(log, isDark)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 통계 카드 위젯
  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required int count,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$count회",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: color.withOpacity(0.8)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 개별 약 복용 기록 아이템
  Widget _buildMedicationLogItem(Map<String, dynamic> log, bool isDark) {
    final status = log['status'] ?? 'unknown';
    final isTaken = status == 'taken';
    final medicationName = log['medication_name'] ?? '약';
    final timestamp = log['timestamp'] ?? '';

    final statusColor = isTaken
        ? const Color(0xFF66BB6A)
        : const Color(0xFFFF6B6B);
    final statusText = isTaken ? "복용 완료" : "미복용";
    final statusIcon = isTaken
        ? Icons.check_circle_rounded
        : Icons.cancel_rounded;

    final cardColor = isDark
        ? AppColors.darkSurfaceVariant
        : Colors.grey.shade50;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subtextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          // 상태 아이콘
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(isDark ? 0.2 : 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(statusIcon, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),

          // 약 정보
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medicationName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(isDark ? 0.2 : 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ),
                    if (timestamp.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.access_time, size: 12, color: subtextColor),
                      const SizedBox(width: 4),
                      Text(
                        timestamp,
                        style: TextStyle(fontSize: 12, color: subtextColor),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// 탭 2: 알림 시간 설정 (FCM 전송 기능 추가됨)
class _MedicationSettingTab extends StatefulWidget {
  final String careTargetId;
  final String careTargetName;
  final String? careTargetFcmToken; // ✅ 토큰 받기

  const _MedicationSettingTab({
    required this.careTargetId,
    this.careTargetName = "환자",
    this.careTargetFcmToken,
  });

  @override
  State<_MedicationSettingTab> createState() => _MedicationSettingTabState();
}

class _MedicationSettingTabState extends State<_MedicationSettingTab> {
  final TextEditingController _nameController = TextEditingController();
  TimeOfDay _selectedTime = const TimeOfDay(hour: 9, minute: 0);
  List<bool> _selectedDays = [true, true, true, true, true, true, true];
  final List<String> _dayLabels = ["월", "화", "수", "목", "금", "토", "일"];

  // ✅ 약 추가 + FCM 전송
  void _addMedication() async {
    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("약 이름을 입력해주세요.")));
      return;
    }
    List<int> daysList = [];
    for (int i = 0; i < 7; i++) {
      if (_selectedDays[i]) daysList.add(i + 1);
    }
    if (daysList.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("최소 하루 이상의 요일을 선택해주세요.")));
      return;
    }
    String timeStr =
        '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}';

    // 1. DB에 저장
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.careTargetId)
        .collection('medications')
        .add({
          'name': _nameController.text,
          'time': timeStr,
          'days': daysList,
          'createdAt': FieldValue.serverTimestamp(),
        });

    if (mounted) {
      Navigator.pop(context);
      _nameController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("약 알림이 설정되었습니다.")));
    }
  }

  // ✅ 알람 활성화/비활성화 토글
  void _toggleAlarmActive(
    String alarmId,
    String medName,
    bool currentActive,
  ) async {
    try {
      final newActive = !currentActive;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.careTargetId)
          .collection('medicine_event')
          .doc(alarmId)
          .update({
            'is_active': newActive,
            'last_updated': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newActive ? '$medName 알림이 활성화되었습니다.' : '$medName 알림이 비활성화되었습니다.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('❌ 알람 상태 변경 실패: $e');
    }
  }

  // ✅ 약 삭제 + FCM 전송 (medicine_event 컬렉션)
  void _deleteMedicationEvent(String alarmId, String medName) async {
    // 확인 다이얼로그
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('알림 삭제'),
        content: Text('$medName 알림을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.careTargetId)
        .collection('medicine_event')
        .doc(alarmId)
        .delete();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('알림이 삭제되었습니다.')));
    }
  }

  // ✅ 약 삭제 (기존 medications 컬렉션용 - 호환성)
  void _deleteMedication(String docId, String medName) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.careTargetId)
        .collection('medications')
        .doc(docId)
        .delete();
  }

  void _showAddDialog() {
    _nameController.clear();
    _selectedTime = const TimeOfDay(hour: 9, minute: 0);
    _selectedDays = [true, true, true, true, true, true, true];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("약 알림 추가"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: "약 이름 (예: 혈압약)",
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Text("시간: "),
                        TextButton(
                          onPressed: () async {
                            final t = await showTimePicker(
                              context: context,
                              initialTime: _selectedTime,
                            );
                            if (t != null)
                              setDialogState(() => _selectedTime = t);
                          },
                          child: Text(
                            _selectedTime.format(context),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 4,
                      children: List.generate(7, (index) {
                        return FilterChip(
                          label: Text(_dayLabels[index]),
                          selected: _selectedDays[index],
                          selectedColor: Colors.green.shade100,
                          onSelected: (val) =>
                              setDialogState(() => _selectedDays[index] = val),
                        );
                      }),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("취소"),
                ),
                ElevatedButton(
                  onPressed: _addMedication,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("저장"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _daysToString(List<dynamic> days) {
    if (days.length == 7) return "매일";
    List<int> d = days.map((e) => e as int).toList()..sort();
    return d.map((e) => _dayLabels[e - 1]).join(", ");
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [추가] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldColor = isDark
        ? AppColors.darkBackground
        : const Color(0xFFF5F5F5);
    final cardColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subtextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF2E7D32);

    return Scaffold(
      backgroundColor: scaffoldColor,
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              // ✅ medicine_event 컬렉션에서 데이터 가져오기 (새로운 방식)
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(widget.careTargetId)
                  .collection('medicine_event')
                  .orderBy('alarm_time')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData)
                  return Center(
                    child: CircularProgressIndicator(color: accentColor),
                  );
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.medication_outlined,
                          size: 64,
                          color: subtextColor,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          "설정된 알림이 없습니다.",
                          style: TextStyle(fontSize: 16, color: subtextColor),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "아래 '알림 추가' 버튼을 눌러주세요.",
                          style: TextStyle(fontSize: 14, color: subtextColor),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: docs.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    var data = docs[index].data() as Map<String, dynamic>;
                    String medicationName = data['medication_name'] ?? '약';
                    String alarmTime = data['alarm_time'] ?? '00:00';
                    List<dynamic> repeatDays = data['repeat_days'] ?? [];
                    bool isActive = data['is_active'] ?? true;

                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: isDark
                                ? Colors.black.withOpacity(0.2)
                                : Colors.black.withOpacity(0.05),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ListTile(
                        onTap: () async {
                          // 알림 카드 클릭 시 수정 페이지로 이동
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => MedicineEditPage(
                                seniorId: widget.careTargetId,
                                seniorName: widget.careTargetName,
                                alarmId: docs[index].id,
                                existingData: data,
                              ),
                            ),
                          );
                        },
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        leading: GestureDetector(
                          onTap: () => _toggleAlarmActive(
                            docs[index].id,
                            medicationName,
                            isActive,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? (isDark
                                        ? Colors.green.withOpacity(0.2)
                                        : Colors.green.withOpacity(0.1))
                                  : (isDark
                                        ? Colors.grey.withOpacity(0.2)
                                        : Colors.grey.withOpacity(0.1)),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.alarm,
                              color: isActive
                                  ? (isDark
                                        ? const Color(0xFF81C784)
                                        : Colors.green)
                                  : subtextColor,
                              size: 28,
                            ),
                          ),
                        ),
                        title: Text(
                          medicationName,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: textColor,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              alarmTime,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppColors.darkPrimary
                                    : Colors.blue,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _daysToString(repeatDays),
                              style: TextStyle(
                                fontSize: 13,
                                color: subtextColor,
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: isDark
                                ? const Color(0xFFFF8A80)
                                : Colors.red,
                          ),
                          onPressed: () => _deleteMedicationEvent(
                            docs[index].id,
                            medicationName,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          // ✅ 새로 만든 iOS 스타일 화면으로 이동
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MedicineSetupPage(
                seniorId: widget.careTargetId,
                seniorName: widget.careTargetName,
              ),
            ),
          );
        },
        backgroundColor: accentColor,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("알림 추가", style: TextStyle(color: Colors.white)),
      ),
    );
  }
}
