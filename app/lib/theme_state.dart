import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

// ═══════════════════════════════════════════════════════════════════════════
// 🎨 시니어 케어 앱 테마 시스템
// ═══════════════════════════════════════════════════════════════════════════

// 앱 전체에서 공유하는 테마 상태 관리자
final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);

const String _prefsThemeModeKey = 'caremode_theme_mode';

// ═══════════════════════════════════════════════════════════════════════════
// 🌙 다크 테마 색상 (네이비 베이스 - 부드러운 느낌)
// ═══════════════════════════════════════════════════════════════════════════
class AppColors {
  // 다크 모드 - 네이비 베이스
  static const Color darkBackground = Color(0xFF1A1F3C); // 딥 네이비 배경
  static const Color darkSurface = Color(0xFF252B4A); // 약간 밝은 네이비 (카드)
  static const Color darkSurfaceVariant = Color(0xFF2D3458); // 더 밝은 네이비 (버튼)
  static const Color darkPrimary = Color(0xFF7B8CDE); // 부드러운 라벤더 블루
  static const Color darkOnSurface = Color(0xFFE8EAF6); // 밝은 텍스트
  static const Color darkOnSurfaceVariant = Color(0xFFB0B8D4); // 보조 텍스트
  static const Color darkDivider = Color(0xFF3D4470); // 구분선

  // 라이트 모드 - 따뜻한 화이트 베이스
  static const Color lightBackground = Color(0xFFFAFAFA); // 부드러운 화이트
  static const Color lightSurface = Color(0xFFFFFFFF); // 순수 화이트 (카드)
  static const Color lightSurfaceVariant = Color(0xFFF5F5F5); // 약간 어두운 화이트
  static const Color lightPrimary = Color(0xFF2E7D32); // 시그니처 그린
  static const Color lightOnSurface = Color(0xFF212121); // 어두운 텍스트
  static const Color lightOnSurfaceVariant = Color(0xFF757575); // 보조 텍스트
  static const Color lightDivider = Color(0xFFE0E0E0); // 구분선

  // ═══════════════════════════════════════════════════════════════════════════
  // 🎨 다크 모드 카드 색상 팔레트 (밝고 생동감 있는 버전)
  // 디자인 원칙: 딥 네이비(#1A1F3C) 배경에서 돋보이는 비비드 컬러
  // - 충분한 명도로 카드가 확실히 보이게
  // - 네이비와 조화로운 쿨톤 베이스
  // ═══════════════════════════════════════════════════════════════════════════

  // 라이트 모드 - 파스텔 톤 (기존 유지)
  static const Color accentYellow = Color(0xFFFFF8E1); // 부드러운 노랑
  static const Color accentTeal = Color(0xFFE0F2F1); // 부드러운 민트
  static const Color accentPurple = Color(0xFFF3E5F5); // 부드러운 보라
  static const Color accentGreen = Color(0xFFE8F5E9); // 부드러운 초록
  static const Color accentBlue = Color(0xFFE3F2FD); // 부드러운 파랑
  static const Color accentOrange = Color(0xFFFFF3E0); // 부드러운 주황
  static const Color accentRed = Color(0xFFFFEBEE); // 부드러운 핑크/레드

  // 다크 모드 - 비비드 & 모던 (밝고 선명하게!)
  // 🟡 앰버/골드: 따뜻한 황금색 (네이비와 보색 대비)
  static const Color accentYellowDark = Color(0xFF5C4A1F); // 리치 골드
  // 🩵 틸/시안: 시원한 청록색
  static const Color accentTealDark = Color(0xFF1A4D4A); // 오션 틸
  // 💜 퍼플: 우아한 바이올렛
  static const Color accentPurpleDark = Color(0xFF4A3566); // 로얄 바이올렛
  // 💚 그린: 생동감 있는 에메랄드
  static const Color accentGreenDark = Color(0xFF2D5A40); // 포레스트 에메랄드
  // 💙 블루: 선명한 코발트
  static const Color accentBlueDark = Color(0xFF2A4A6B); // 딥 코발트
  // 🧡 오렌지: 따뜻한 테라코타
  static const Color accentOrangeDark = Color(
    0xFF6B4A35,
  ); // 웜 테라코타  // ❤️ 레드/핑크: 부드러운 코랄
  static const Color accentRedDark = Color(0xFF5C3A3A); // 로즈 코랄
  // 상태 표시 색상
  static const Color success = Color(0xFF4CAF50);
  static const Color successDark = Color(0xFF81C784);
  static const Color warning = Color(0xFFFF9800);
  static const Color warningDark = Color(0xFFFFB74D);
  static const Color error = Color(0xFFE57373);
  static const Color errorDark = Color(0xFFEF9A9A);
}

// ═══════════════════════════════════════════════════════════════════════════
// 🎯 버튼 색상 헬퍼 (채도 낮춘 파스텔 톤)
// ═══════════════════════════════════════════════════════════════════════════
class AppButtonColors {
  /// 메뉴 카드 색상 (라이트/다크 모드 대응)
  static Color getMenuCardColor(BuildContext context, String colorType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    switch (colorType) {
      case 'yellow':
        return isDark ? AppColors.accentYellowDark : AppColors.accentYellow;
      case 'teal':
        return isDark ? AppColors.accentTealDark : AppColors.accentTeal;
      case 'purple':
        return isDark ? AppColors.accentPurpleDark : AppColors.accentPurple;
      case 'green':
        return isDark ? AppColors.accentGreenDark : AppColors.accentGreen;
      case 'blue':
        return isDark ? AppColors.accentBlueDark : AppColors.accentBlue;
      case 'orange':
        return isDark ? AppColors.accentOrangeDark : AppColors.accentOrange;
      case 'red':
        return isDark ? AppColors.accentRedDark : AppColors.accentRed;
      default:
        return isDark ? AppColors.darkSurface : AppColors.lightSurface;
    }
  }

  /// 아이콘 색상 (라이트/다크 모드 대응)
  /// 다크 모드: 밝고 선명한 색상으로 카드 배경과 대비
  /// 라이트 모드: 진한 색상으로 파스텔 배경과 대비
  static Color getIconColor(BuildContext context, String colorType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    switch (colorType) {
      case 'yellow':
        // 다크: 밝은 골드 / 라이트: 오렌지 브라운
        return isDark ? const Color(0xFFFFD966) : const Color(0xFFF57C00);
      case 'teal':
        // 다크: 밝은 시안 / 라이트: 딥 틸
        return isDark ? const Color(0xFF5CE1E6) : const Color(0xFF00897B);
      case 'purple':
        // 다크: 밝은 라벤더 / 라이트: 딥 퍼플
        return isDark ? const Color(0xFFCB6CE6) : const Color(0xFF8E24AA);
      case 'green':
        // 다크: 밝은 민트 / 라이트: 포레스트 그린
        return isDark ? const Color(0xFF7ED957) : const Color(0xFF43A047);
      case 'blue':
        // 다크: 밝은 스카이 블루 / 라이트: 딥 블루
        return isDark ? const Color(0xFF5DADE2) : const Color(0xFF1976D2);
      case 'orange':
        // 다크: 밝은 코랄 / 라이트: 딥 오렌지
        return isDark ? const Color(0xFFFF8A65) : const Color(0xFFEF6C00);
      case 'red':
        // 다크: 밝은 핑크 / 라이트: 딥 레드
        return isDark ? const Color(0xFFFF8A80) : const Color(0xFFD32F2F);
      default:
        return isDark ? Colors.white70 : Colors.black87;
    }
  }

  /// 카드 내 타이틀 텍스트 색상 (colorType별)
  /// 다크 모드에서 카드 배경과 잘 어울리는 밝은 색상 반환
  static Color getCardTitleColor(BuildContext context, String colorType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (!isDark) {
      // 라이트 모드: 각 색상 계열의 진한 색상
      switch (colorType) {
        case 'yellow':
          return const Color(0xFFE65100); // 딥 오렌지
        case 'teal':
          return const Color(0xFF00695C); // 딥 틸
        case 'purple':
          return const Color(0xFF7B1FA2); // 딥 퍼플
        case 'green':
          return const Color(0xFF2E7D32); // 딥 그린
        case 'blue':
          return const Color(0xFF1565C0); // 딥 블루
        case 'orange':
          return const Color(0xFFE65100); // 딥 오렌지
        case 'red':
          return const Color(0xFFC62828); // 딥 레드
        default:
          return AppColors.lightOnSurface;
      }
    } else {
      // 다크 모드: 밝고 선명한 네온 느낌 (확실히 보이게)
      switch (colorType) {
        case 'yellow':
          return const Color(0xFFFFE566); // 브라이트 골드
        case 'teal':
          return const Color(0xFF5CE1E6); // 브라이트 시안
        case 'purple':
          return const Color(0xFFE0A0FF); // 브라이트 라벤더
        case 'green':
          return const Color(0xFF7ED957); // 브라이트 라임
        case 'blue':
          return const Color(0xFF7EC8E3); // 브라이트 스카이
        case 'orange':
          return const Color(0xFFFFB366); // 브라이트 피치
        case 'red':
          return const Color(0xFFFF8A80); // 브라이트 코랄
        default:
          return AppColors.darkOnSurface;
      }
    }
  }

  /// 카드 내 서브타이틀 텍스트 색상
  static Color getCardSubtitleColor(BuildContext context, String colorType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (!isDark) {
      return AppColors.lightOnSurfaceVariant;
    } else {
      // 다크 모드: 약간 덜 밝은 색상
      return const Color(0xFFB0B8D4); // 밝은 그레이 블루
    }
  }

  /// 텍스트 색상 가져오기
  static Color getTextColor(BuildContext context, {bool isSecondary = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isSecondary) {
      return isDark
          ? AppColors.darkOnSurfaceVariant
          : AppColors.lightOnSurfaceVariant;
    }
    return isDark ? AppColors.darkOnSurface : AppColors.lightOnSurface;
  }

  /// 배경색 가져오기
  static Color getBackgroundColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? AppColors.darkBackground : AppColors.lightBackground;
  }

  /// 카드 배경색 가져오기
  static Color getSurfaceColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? AppColors.darkSurface : AppColors.lightSurface;
  }

  /// 구분선 색상 가져오기
  static Color getDividerColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? AppColors.darkDivider : AppColors.lightDivider;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 📱 테마 데이터 정의
// ═══════════════════════════════════════════════════════════════════════════

/// 라이트 테마
ThemeData getLightTheme() {
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.lightBackground,
    useMaterial3: true,
    fontFamily: 'PyeongtaekSemiconductor',

    // 색상 스킴
    colorScheme: const ColorScheme.light(
      primary: AppColors.lightPrimary,
      surface: AppColors.lightSurface,
      onSurface: AppColors.lightOnSurface,
      onSurfaceVariant: AppColors.lightOnSurfaceVariant,
    ),

    // AppBar 테마
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.lightBackground,
      foregroundColor: AppColors.lightOnSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      // ✅ 라이트 모드: 상태바 아이콘을 어둡게 (배경이 밝으므로)
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // 어두운 아이콘
        statusBarBrightness: Brightness.light, // iOS용
      ),
    ),

    // 카드 테마
    cardTheme: CardThemeData(
      color: AppColors.lightSurface,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),

    // 바텀시트 테마
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.lightSurface,
    ),

    // 다이얼로그 테마
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),

    // 구분선 테마
    dividerTheme: const DividerThemeData(
      color: AppColors.lightDivider,
      thickness: 1,
    ),

    // 스낵바 테마
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.lightOnSurface,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 다크 테마 (네이비 베이스)
ThemeData getDarkTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.darkBackground,
    useMaterial3: true,
    fontFamily: 'PyeongtaekSemiconductor',

    // 색상 스킴
    colorScheme: const ColorScheme.dark(
      primary: AppColors.darkPrimary,
      surface: AppColors.darkSurface,
      onSurface: AppColors.darkOnSurface,
      onSurfaceVariant: AppColors.darkOnSurfaceVariant,
    ),

    // AppBar 테마
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.darkBackground,
      foregroundColor: AppColors.darkOnSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      // ✅ 다크 모드: 상태바 아이콘을 밝게 (배경이 어두우므로)
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light, // 밝은 아이콘
        statusBarBrightness: Brightness.dark, // iOS용
      ),
    ),

    // 카드 테마
    cardTheme: CardThemeData(
      color: AppColors.darkSurface,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),

    // 바텀시트 테마
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.darkSurface,
    ),

    // 다이얼로그 테마
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),

    // 구분선 테마
    dividerTheme: const DividerThemeData(
      color: AppColors.darkDivider,
      thickness: 1,
    ),

    // 스낵바 테마
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.darkSurfaceVariant,
      contentTextStyle: const TextStyle(color: AppColors.darkOnSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 🔧 테마 유틸리티 함수
// ═══════════════════════════════════════════════════════════════════════════

Future<void> loadThemeModeFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_prefsThemeModeKey);
  switch (saved) {
    case 'dark':
      themeNotifier.value = ThemeMode.dark;
      break;
    case 'light':
      themeNotifier.value = ThemeMode.light;
      break;
    case 'system':
      themeNotifier.value = ThemeMode.system;
      break;
    default:
      // keep default
      break;
  }
}

/// 테마 저장
Future<void> saveThemeMode(ThemeMode mode) async {
  themeNotifier.value = mode;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsThemeModeKey, mode.name);
  } catch (e) {
    debugPrint('Failed to save theme: $e');
  }
}

/// 테마 토글 (라이트 <-> 다크) - 60fps 최적화 버전
/// UI 업데이트를 먼저 수행하고, 비동기로 저장하여 프레임 드롭 방지
void toggleTheme() {
  final newMode = themeNotifier.value == ThemeMode.dark
      ? ThemeMode.light
      : ThemeMode.dark;

  // 1. 즉시 UI 업데이트 (프레임 드롭 없이)
  themeNotifier.value = newMode;

  // 2. 비동기로 저장 (UI 블로킹 방지)
  _saveThemeModeAsync(newMode);
}

/// 비동기 테마 저장 (UI 스레드 블로킹 방지)
Future<void> _saveThemeModeAsync(ThemeMode mode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsThemeModeKey, mode.name);
  } catch (e) {
    debugPrint('Failed to save theme: $e');
  }
}

/// 현재 다크모드인지 확인
bool get isDarkMode => themeNotifier.value == ThemeMode.dark;

/// BuildContext 기반 다크모드 확인 (시스템 테마 지원)
bool isDarkModeFromContext(BuildContext context) {
  final mode = themeNotifier.value;
  if (mode == ThemeMode.system) {
    return MediaQuery.of(context).platformBrightness == Brightness.dark;
  }
  return mode == ThemeMode.dark;
}
