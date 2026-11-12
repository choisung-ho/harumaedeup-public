// lib/screens/medicine_setup_page.dart
// 보호자용 약 알림 설정 화면 (iOS 스타일 CupertinoPicker 사용)

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class MedicineSetupPage extends StatefulWidget {
  final String? seniorId; // 시니어 UID (보호자가 관리하는 대상)
  final String? seniorName; // 시니어 이름

  const MedicineSetupPage({super.key, this.seniorId, this.seniorName});

  @override
  State<MedicineSetupPage> createState() => _MedicineSetupPageState();
}

class _MedicineSetupPageState extends State<MedicineSetupPage> {
  final TextEditingController _medicineNameController = TextEditingController();

  // 선택된 시간 (기본값: 현재 시간)
  DateTime _selectedTime = DateTime.now();

  // 시간 표시를 위한 ValueNotifier (렉 방지)
  late final ValueNotifier<String> _displayTimeNotifier;

  // 선택된 요일 (1=월, 2=화, ..., 7=일)
  Set<int> _selectedDays = {};

  bool _isLoading = false;

  // 요일 한글 매핑
  final Map<int, String> _dayNames = {
    1: '월',
    2: '화',
    3: '수',
    4: '목',
    5: '금',
    6: '토',
    7: '일',
  };

  @override
  void initState() {
    super.initState();
    _displayTimeNotifier = ValueNotifier(
      DateFormat('HH:mm').format(_selectedTime),
    );
  }

  @override
  void dispose() {
    _medicineNameController.dispose();
    _displayTimeNotifier.dispose();
    super.dispose();
  }

  /// 고유한 alarm_id 생성 (alarm_20260127_001 형식)
  String _generateAlarmId() {
    final now = DateTime.now();
    final dateStr = DateFormat('yyyyMMdd').format(now);
    final timeStr = DateFormat('HHmmss').format(now);
    return 'alarm_${dateStr}_$timeStr';
  }

  /// Firestore에 약 알림 데이터 저장
  Future<void> _saveMedicineAlarm() async {
    // 유효성 검사
    if (_medicineNameController.text.trim().isEmpty) {
      _showErrorDialog('약 이름을 입력해주세요.');
      return;
    }

    if (_selectedDays.isEmpty) {
      _showErrorDialog('최소 1개 이상의 요일을 선택해주세요.');
      return;
    }

    if (widget.seniorId == null || widget.seniorId!.isEmpty) {
      _showErrorDialog('시니어 정보를 찾을 수 없습니다.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw '로그인 정보가 없습니다.';

      final guardianId = user.uid;
      final alarmId = _generateAlarmId();
      final alarmTime = DateFormat('HH:mm').format(_selectedTime);
      final repeatDays = _selectedDays.toList()..sort(); // 오름차순 정렬

      // Firestore에 저장할 데이터
      final medicineData = {
        'alarm_id': alarmId,
        'guardian_id': guardianId,
        'senior_id': widget.seniorId,
        'medication_name': _medicineNameController.text.trim(),
        'alarm_time': alarmTime,
        'repeat_days': repeatDays,
        'is_active': true,
        'snooze_count': 0,
        'last_updated': FieldValue.serverTimestamp(),
        'created_at': FieldValue.serverTimestamp(),
      };

      // Firestore에 저장 (시니어 문서의 하위 컬렉션)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.seniorId)
          .collection('medicine_event')
          .doc(alarmId)
          .set(medicineData);

      debugPrint('✅ 약 알림 저장 완료: $alarmId');

      setState(() => _isLoading = false);

      if (!mounted) return;

      // 성공 메시지 및 화면 닫기
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장 완료'),
          content: Text(
            '${_medicineNameController.text} 알림이 저장되었습니다.\n시간: $alarmTime',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context); // 다이얼로그 닫기
                Navigator.pop(context, true); // 설정 화면 닫고 결과 반환
              },
              child: const Text('확인'),
            ),
          ],
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('❌ 약 알림 저장 실패: $e');
      _showErrorDialog('저장 중 오류가 발생했습니다.\n$e');
    }
  }

  /// 에러 다이얼로그 표시
  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('알림'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
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
    final inputFillColor = isDark
        ? AppColors.darkSurfaceVariant
        : Colors.grey[50];
    final accentColor = isDark ? AppColors.darkPrimary : Colors.blue;

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        title: Text(
          '${widget.seniorName ?? "시니어"}님 약 알림 설정',
          style: TextStyle(color: textColor),
        ),
        backgroundColor: cardColor,
        foregroundColor: textColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: accentColor))
          : SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 20),

                  // 1. 약 이름 입력
                  _buildMedicineNameSection(
                    isDark,
                    cardColor,
                    textColor,
                    inputFillColor,
                  ),

                  const SizedBox(height: 20),

                  // 2. 시간 선택 (iOS 스타일)
                  _buildTimePickerSection(
                    isDark,
                    cardColor,
                    textColor,
                    accentColor,
                  ),

                  const SizedBox(height: 20),

                  // 3. 요일 선택
                  _buildDaySelectionSection(
                    isDark,
                    cardColor,
                    textColor,
                    accentColor,
                  ),

                  const SizedBox(height: 30),

                  // 4. 저장 버튼
                  _buildSaveButton(accentColor),

                  const SizedBox(height: 30),
                ],
              ),
            ),
    );
  }

  /// 약 이름 입력 섹션
  Widget _buildMedicineNameSection(
    bool isDark,
    Color cardColor,
    Color textColor,
    Color? inputFillColor,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.2)
                : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '약 이름',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _medicineNameController,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              hintText: '예: 아침 혈압약',
              hintStyle: TextStyle(
                color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
              ),
              filled: true,
              fillColor: inputFillColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 시간 선택 섹션 (iOS Cupertino Picker)
  Widget _buildTimePickerSection(
    bool isDark,
    Color cardColor,
    Color textColor,
    Color accentColor,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.2)
                : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '알림 시간',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),

          // 현재 선택된 시간 표시 (ValueListenableBuilder로 분리하여 렉 방지)
          ValueListenableBuilder<String>(
            valueListenable: _displayTimeNotifier,
            builder: (context, displayTime, _) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(isDark ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.access_time, color: accentColor),
                    const SizedBox(width: 8),
                    Text(
                      displayTime,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 16),

          // iOS 스타일 시간 선택기 (RepaintBoundary로 렌더링 최적화)
          RepaintBoundary(
            child: SizedBox(
              height: 200,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: isDark ? Brightness.dark : Brightness.light,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: TextStyle(
                      fontSize: 20,
                      color: textColor,
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  initialDateTime: _selectedTime,
                  onDateTimeChanged: (DateTime newTime) {
                    // setState 대신 ValueNotifier로 시간 표시만 업데이트
                    _selectedTime = newTime;
                    _displayTimeNotifier.value = DateFormat(
                      'HH:mm',
                    ).format(newTime);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 요일 선택 섹션
  Widget _buildDaySelectionSection(
    bool isDark,
    Color cardColor,
    Color textColor,
    Color accentColor,
  ) {
    final unselectedColor = isDark
        ? AppColors.darkSurfaceVariant
        : Colors.grey[200];
    final unselectedTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.black54;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.2)
                : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '반복 요일',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 16),

          // 요일 버튼 (월~일) - LayoutBuilder로 동적 크기 조절
          LayoutBuilder(
            builder: (context, constraints) {
              // 화면 너비에 맞게 버튼 크기 계산 (간격 포함)
              final buttonSize =
                  (constraints.maxWidth - 6 * 8) / 7; // 6개 간격, 7개 버튼
              final clampedSize = buttonSize.clamp(32.0, 44.0); // 최소 32, 최대 44

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(7, (index) {
                  final dayNumber = index + 1; // 1=월, 7=일
                  final isSelected = _selectedDays.contains(dayNumber);

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedDays.remove(dayNumber);
                        } else {
                          _selectedDays.add(dayNumber);
                        }
                      });
                    },
                    child: Container(
                      width: clampedSize,
                      height: clampedSize,
                      decoration: BoxDecoration(
                        color: isSelected ? accentColor : unselectedColor,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          _dayNames[dayNumber]!,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : unselectedTextColor,
                            fontWeight: FontWeight.bold,
                            fontSize: clampedSize * 0.33,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),

          const SizedBox(height: 12),

          // 빠른 선택 버튼
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _selectedDays = {1, 2, 3, 4, 5}; // 평일
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor.withOpacity(0.5)),
                  ),
                  child: Text('평일', style: TextStyle(color: textColor)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _selectedDays = {6, 7}; // 주말
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor.withOpacity(0.5)),
                  ),
                  child: Text('주말', style: TextStyle(color: textColor)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _selectedDays = {1, 2, 3, 4, 5, 6, 7}; // 매일
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor.withOpacity(0.5)),
                  ),
                  child: Text('매일', style: TextStyle(color: textColor)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 저장 버튼
  Widget _buildSaveButton(Color accentColor) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _saveMedicineAlarm,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
        ),
        child: const Text(
          '알림 저장',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
