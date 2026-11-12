// medication_check_page.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class MedicationCheckPage extends StatelessWidget {
  final Function(bool) onResult; // 결과를 부모에게 전달하는 콜백

  const MedicationCheckPage({super.key, required this.onResult});

  @override
  Widget build(BuildContext context) {
    // ✅ [개선] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text("약 복용 확인", style: TextStyle(color: textColor)),
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        centerTitle: true,
        automaticallyImplyLeading: false, // 뒤로가기 없애서 선택 강제
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. 상단 안내 문구
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30.0),
              child: Column(
                children: [
                  Text(
                    DateFormat('a h:mm', 'ko_KR').format(DateTime.now()),
                    style: TextStyle(
                      fontSize: 20,
                      color: subTextColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "지금 약을 드셨나요?",
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),

            // 2. 선택 영역 (화면을 반으로 쪼개서 거대한 버튼으로 만듦)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // [옵션 1] 네, 먹었습니다 (가장 크게 강조)
                    Expanded(
                      flex: 3, // 화면의 60% 차지 (긍정 행동 유도)
                      child: _buildBigButton(
                        context,
                        title: "네, 먹었어요!",
                        icon: Icons.check_circle,
                        color: isDark
                            ? AppColors.successDark
                            : const Color(0xFF4CAF50),
                        isPositive: true,
                        isDark: isDark,
                        onTap: () => onResult(true),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // [옵션 2] 아니요, 아직 안 먹었어요 (작게 배치)
                    Expanded(
                      flex: 2, // 화면의 40% 차지
                      child: _buildBigButton(
                        context,
                        title: "아니요, 아직이요",
                        icon: Icons.cancel,
                        color: isDark
                            ? AppColors.errorDark
                            : const Color(0xFFEF5350),
                        isPositive: false,
                        isDark: isDark,
                        onTap: () => onResult(false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // 거대한 카드 버튼 위젯
  Widget _buildBigButton(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required bool isPositive,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: isPositive
              ? color.withOpacity(isDark ? 0.2 : 0.1)
              : (isDark ? AppColors.darkSurface : Colors.grey[100]),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isPositive
                ? color
                : (isDark ? AppColors.darkDivider : Colors.grey[400]!),
            width: 3, // 테두리를 두껍게 해서 명확하게 구분
          ),
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: color.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 아이콘을 아주 크게
            Icon(icon, size: 80, color: color),
            const SizedBox(height: 16),
            // 글자도 아주 크게
            Text(
              title,
              style: TextStyle(
                fontSize: 28, // 노안을 고려한 큰 폰트
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
