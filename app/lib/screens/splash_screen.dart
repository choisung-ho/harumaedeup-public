// lib/screens/splash_screen.dart
// 앱 시작 시 표시되는 스플래시 화면
// 부드러운 애니메이션과 함께 로그인/홈 화면으로 전환

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SplashScreen extends StatefulWidget {
  final Widget nextPage;

  const SplashScreen({super.key, required this.nextPage});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // 아이콘 애니메이션
  late AnimationController _iconController;
  late Animation<double> _iconScaleAnimation;
  late Animation<double> _iconFadeAnimation;

  // 텍스트 애니메이션
  late AnimationController _textController;
  late Animation<double> _textFadeAnimation;
  late Animation<Offset> _textSlideAnimation;

  // 로딩 인디케이터 애니메이션
  late AnimationController _loadingController;
  late Animation<double> _loadingFadeAnimation;

  // 전체 페이드아웃 애니메이션
  late AnimationController _fadeOutController;
  late Animation<double> _fadeOutAnimation;

  @override
  void initState() {
    super.initState();

    // 상태바 스타일 설정
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
    );

    _initAnimations();
    _startAnimationSequence();
  }

  void _initAnimations() {
    // 1. 아이콘 애니메이션 (0 ~ 800ms)
    _iconController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _iconScaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.elasticOut),
    );

    _iconFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _iconController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    // 2. 텍스트 애니메이션 (300ms 딜레이 후 500ms)
    _textController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _textFadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _textController, curve: Curves.easeOut));

    _textSlideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
          CurvedAnimation(parent: _textController, curve: Curves.easeOutCubic),
        );

    // 3. 로딩 인디케이터 애니메이션 (600ms 딜레이 후)
    _loadingController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _loadingFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _loadingController, curve: Curves.easeOut),
    );

    // 4. 페이드아웃 애니메이션 (화면 전환용)
    _fadeOutController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeOutAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeOutController, curve: Curves.easeInOut),
    );
  }

  void _startAnimationSequence() async {
    // 1. 아이콘 애니메이션 시작
    await Future.delayed(const Duration(milliseconds: 100));
    _iconController.forward();

    // 2. 텍스트 애니메이션 시작 (300ms 후)
    await Future.delayed(const Duration(milliseconds: 300));
    _textController.forward();

    // 3. 로딩 인디케이터 표시 (600ms 후)
    await Future.delayed(const Duration(milliseconds: 300));
    _loadingController.forward();

    // 4. 잠시 대기 후 페이드아웃 & 화면 전환 (총 2초 후)
    await Future.delayed(const Duration(milliseconds: 1300));

    if (mounted) {
      _fadeOutController.forward().then((_) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  widget.nextPage,
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _iconController.dispose();
    _textController.dispose();
    _loadingController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A2E) : Colors.white,
      body: AnimatedBuilder(
        animation: _fadeOutAnimation,
        builder: (context, child) {
          return Opacity(opacity: _fadeOutAnimation.value, child: child);
        },
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 3),

              // 앱 아이콘 (애니메이션)
              AnimatedBuilder(
                animation: _iconController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _iconFadeAnimation.value,
                    child: Transform.scale(
                      scale: _iconScaleAnimation.value,
                      child: child,
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF81C784).withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Image.asset(
                    'assets/icon/icon.png',
                    width: 100,
                    height: 100,
                    errorBuilder: (c, e, s) => const Icon(
                      Icons.favorite,
                      size: 100,
                      color: Color(0xFF81C784),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 30),

              // 앱 이름 (애니메이션)
              AnimatedBuilder(
                animation: _textController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _textFadeAnimation.value,
                    child: SlideTransition(
                      position: _textSlideAnimation,
                      child: child,
                    ),
                  );
                },
                child: Column(
                  children: [
                    Text(
                      '하루 매듭',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF81C784),
                        letterSpacing: 2,
                        shadows: [
                          Shadow(
                            color: const Color(0xFF81C784).withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '소중한 하루를 기록해요',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(flex: 2),

              // 로딩 인디케이터 (애니메이션)
              AnimatedBuilder(
                animation: _loadingController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _loadingFadeAnimation.value,
                    child: child,
                  );
                },
                child: Column(
                  children: [
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF81C784).withOpacity(0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '로딩 중...',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[500] : Colors.grey[400],
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}
