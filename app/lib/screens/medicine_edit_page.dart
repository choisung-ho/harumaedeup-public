// lib/screens/medicine_edit_page.dart
// 보호자용 약 알림 수정 화면

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class MedicineEditPage extends StatefulWidget {
  final String? seniorId;
  final String? seniorName;
  final String alarmId;
  final Map<String, dynamic> existingData;

  const MedicineEditPage({
    super.key,
    this.seniorId,
    this.seniorName,
    required this.alarmId,
    required this.existingData,
  });

  @override
  State<MedicineEditPage> createState() => _MedicineEditPageState();
}

class _MedicineEditPageState extends State<MedicineEditPage> {
  late TextEditingController _medicineNameController;
  late DateTime _selectedTime;
  late Set<int> _selectedDays;
  bool _isLoading = false;

  // 시간 표시를 위한 ValueNotifier (렉 방지)
  late final ValueNotifier<String> _displayTimeNotifier;

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
    _initializeFromExisting();
    _displayTimeNotifier = ValueNotifier(
      DateFormat('HH:mm').format(_selectedTime),
    );
  }

  void _initializeFromExisting() {
    // 기존 데이터로 초기화
    _medicineNameController = TextEditingController(
      text: widget.existingData['medication_name'] ?? '',
    );

    // 시간 파싱 (HH:mm)
    final timeStr = widget.existingData['alarm_time'] ?? '09:00';
    final timeParts = timeStr.split(':');
    _selectedTime = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      int.parse(timeParts[0]),
      int.parse(timeParts[1]),
    );

    // 요일 데이터
    final repeatDaysList =
        widget.existingData['repeat_days'] as List<dynamic>? ?? [];
    _selectedDays = repeatDaysList.map((e) => e as int).toSet();
  }

  @override
  void dispose() {
    _medicineNameController.dispose();
    _displayTimeNotifier.dispose();
    super.dispose();
  }

  Future<void> _updateMedicineAlarm() async {
    if (_medicineNameController.text.trim().isEmpty) {
      _showErrorDialog('약 이름을 입력해주세요.');
      return;
    }

    if (_selectedDays.isEmpty) {
      _showErrorDialog('최소 1개 이상의 요일을 선택해주세요.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final alarmTime = DateFormat('HH:mm').format(_selectedTime);
      final repeatDays = _selectedDays.toList()..sort();

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.seniorId)
          .collection('medicine_event')
          .doc(widget.alarmId)
          .update({
            'medication_name': _medicineNameController.text.trim(),
            'alarm_time': alarmTime,
            'repeat_days': repeatDays,
            'last_updated': FieldValue.serverTimestamp(),
          });

      setState(() => _isLoading = false);

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('수정 완료'),
          content: Text('${_medicineNameController.text} 알림이 수정되었습니다.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context, true);
              },
              child: const Text('확인'),
            ),
          ],
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('❌ 약 알림 수정 실패: $e');
      _showErrorDialog('수정 중 오류가 발생했습니다.\n$e');
    }
  }

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
    final inputFillColor = isDark
        ? AppColors.darkSurfaceVariant
        : Colors.grey[50];
    final accentColor = isDark ? AppColors.darkPrimary : Colors.blue;

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        title: Text(
          '${widget.seniorName ?? "시니어"}님 약 알림 수정',
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
                  _buildMedicineNameSection(
                    isDark,
                    cardColor,
                    textColor,
                    inputFillColor,
                  ),
                  const SizedBox(height: 20),
                  _buildTimePickerSection(
                    isDark,
                    cardColor,
                    textColor,
                    accentColor,
                  ),
                  const SizedBox(height: 20),
                  _buildDaySelectionSection(
                    isDark,
                    cardColor,
                    textColor,
                    accentColor,
                  ),
                  const SizedBox(height: 30),
                  _buildUpdateButton(isDark),
                  const SizedBox(height: 30),
                ],
              ),
            ),
    );
  }

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
          // LayoutBuilder로 동적 크기 조절
          LayoutBuilder(
            builder: (context, constraints) {
              final buttonSize = (constraints.maxWidth - 6 * 8) / 7;
              final clampedSize = buttonSize.clamp(32.0, 44.0);

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(7, (index) {
                  final dayNumber = index + 1;
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _selectedDays = {1, 2, 3, 4, 5};
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
                      _selectedDays = {6, 7};
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
                      _selectedDays = {1, 2, 3, 4, 5, 6, 7};
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

  Widget _buildUpdateButton(bool isDark) {
    final accentColor = isDark ? Colors.orange.shade300 : Colors.orange;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _updateMedicineAlarm,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
        ),
        child: const Text(
          '알림 수정',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
