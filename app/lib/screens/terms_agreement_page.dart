// lib/screens/terms_agreement_page.dart

import 'package:flutter/material.dart';
import 'signup_page.dart';
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class TermsAgreementPage extends StatefulWidget {
  // ❌ final String selectedRole;  <-- 삭제함
  final String? googleEmail;
  final String? googleName;

  const TermsAgreementPage({
    super.key,
    // ❌ required this.selectedRole, <-- 삭제함
    this.googleEmail,
    this.googleName,
  });

  @override
  State<TermsAgreementPage> createState() => _TermsAgreementPageState();
}

class _TermsAgreementPageState extends State<TermsAgreementPage> {
  bool _allAgreed = false;
  bool _servicePolicyAgreed = false;
  bool _privacyPolicyAgreed = false;
  bool _locationPolicyAgreed = false;
  bool _healthInfoAgreed = false;
  bool _biometricAgreed = false; // 생체정보 동의 추가
  bool _marketingAgreed = false;

  void _toggleAll(bool? value) {
    if (value == null) return;
    setState(() {
      _allAgreed = value;
      _servicePolicyAgreed = value;
      _privacyPolicyAgreed = value;
      _locationPolicyAgreed = value;
      _healthInfoAgreed = value;
      _biometricAgreed = value;
      _marketingAgreed = value;
    });
  }

  void _toggleItem() {
    setState(() {
      _allAgreed =
          _servicePolicyAgreed &&
          _privacyPolicyAgreed &&
          _locationPolicyAgreed &&
          _healthInfoAgreed &&
          _biometricAgreed &&
          _marketingAgreed;
    });
  }

  bool get _isMandatoryChecked =>
      _servicePolicyAgreed &&
      _privacyPolicyAgreed &&
      _locationPolicyAgreed &&
      _healthInfoAgreed &&
      _biometricAgreed;

  @override
  Widget build(BuildContext context) {
    // ✅ [추가] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final cardColor = isDark ? AppColors.darkSurface : Colors.white;
    final borderColor = isDark
        ? AppColors.darkDivider
        : const Color(0xFF81C784);

    return Scaffold(
      appBar: AppBar(
        title: Text("약관 동의", style: TextStyle(color: textColor)),
        backgroundColor: scaffoldColor,
        foregroundColor: textColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      backgroundColor: scaffoldColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    "하루매듭 서비스 이용을 위해\n약관에 동의해 주세요.",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 30),

                  // 전체 동의
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(12),
                      color: isDark
                          ? const Color(0xFF81C784).withOpacity(0.1)
                          : const Color(0xFF81C784).withOpacity(0.05),
                    ),
                    child: CheckboxListTile(
                      title: Text(
                        "모두 동의합니다",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: textColor,
                        ),
                      ),
                      subtitle: Text(
                        "선택 정보를 포함합니다.",
                        style: TextStyle(fontSize: 12, color: subTextColor),
                      ),
                      value: _allAgreed,
                      onChanged: _toggleAll,
                      activeColor: const Color(0xFF81C784),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Divider(color: isDark ? AppColors.darkDivider : null),

                  _buildTermItem(
                    "서비스 이용약관 동의 (필수)",
                    _servicePolicyAgreed,
                    (v) {
                      setState(() => _servicePolicyAgreed = v!);
                      _toggleItem();
                    },
                    _serviceTermsContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                  _buildTermItem(
                    "개인정보 수집 및 이용 동의 (필수)",
                    _privacyPolicyAgreed,
                    (v) {
                      setState(() => _privacyPolicyAgreed = v!);
                      _toggleItem();
                    },
                    _privacyContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                  _buildTermItem(
                    "위치기반 서비스 이용약관 동의 (필수)",
                    _locationPolicyAgreed,
                    (v) {
                      setState(() => _locationPolicyAgreed = v!);
                      _toggleItem();
                    },
                    _locationContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                  _buildTermItem(
                    "민감정보(건강) 처리 동의 (필수)",
                    _healthInfoAgreed,
                    (v) {
                      setState(() => _healthInfoAgreed = v!);
                      _toggleItem();
                    },
                    _healthInfoContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                  _buildTermItem(
                    "생체정보(얼굴) 수집 및 이용 동의 (필수)",
                    _biometricAgreed,
                    (v) {
                      setState(() => _biometricAgreed = v!);
                      _toggleItem();
                    },
                    _biometricContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                  _buildTermItem(
                    "마케팅 정보 수신 동의 (선택)",
                    _marketingAgreed,
                    (v) {
                      setState(() => _marketingAgreed = v!);
                      _toggleItem();
                    },
                    _marketingContent,
                    isDark,
                    textColor,
                    subTextColor,
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isMandatoryChecked
                      ? () {
                          // ✅ [수정] role 전달 삭제, 구글 정보만 넘김
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) => SignUpPage(
                                // role: widget.selectedRole,  <-- 이거 때문에 에러났던 거임! 삭제!
                                googleEmail: widget.googleEmail,
                                googleName: widget.googleName,
                              ),
                            ),
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF81C784),
                    disabledBackgroundColor: isDark
                        ? AppColors.darkSurfaceVariant
                        : Colors.grey[300],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    "확인",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTermItem(
    String title,
    bool value,
    ValueChanged<bool?> onChanged,
    String content,
    bool isDark,
    Color textColor,
    Color subTextColor,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFF81C784),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(
          color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
        ),
      ),
      title: Transform.translate(
        offset: const Offset(-10, 0),
        child: Text(title, style: TextStyle(fontSize: 14, color: textColor)),
      ),
      trailing: IconButton(
        icon: Icon(
          Icons.chevron_right,
          color: isDark ? AppColors.darkOnSurfaceVariant : Colors.grey,
        ),
        onPressed: () => _showTermDialog(title, content, isDark),
      ),
      onTap: () => onChanged(!value),
    );
  }

  void _showTermDialog(String title, String content, bool isDark) {
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: bgColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.replaceAll(" (필수)", "").replaceAll(" (선택)", ""),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: Text(
                    content,
                    style: TextStyle(
                      height: 1.6,
                      color: textColor,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF81C784),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text("확인"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const String _serviceTermsContent = """제 1 조 (목적)
본 약관은 '하루매듭' 서비스(이하 "서비스")를 이용함에 있어 회사와 회원의 권리, 의무 및 책임사항을 규정함을 목적으로 합니다.

제 2 조 (계정)
귀하는 서비스 이용을 위해 계정을 생성해야 하며, 정확하고 완전한 정보를 제공해야 합니다. 계정의 보안 책임은 전적으로 회원 본인에게 있습니다.

제 3 조 (서비스 사용권)
회사는 귀하에게 개인적이고 비상업적인 용도로만 서비스를 사용할 수 있는 제한적인 라이선스를 부여합니다.

제 4 조 (금지 행위)
서비스 콘텐츠를 무단으로 복제, 배포하거나 서버를 해킹하는 등의 행위는 엄격히 금지됩니다.

제 5 조 (백그라운드 실행 및 자동화 기능)
본 서비스는 다음 기능을 제공하기 위해 백그라운드에서 지속 실행됩니다:
1. 실시간 위치 추적 및 안전 확인
2. 사진, 동영상, 통화 녹음 파일의 자동 업로드
3. SMS 문자 메시지 기록
4. 약 복용 알림 및 긴급 알림 수신

* 상기 기능을 위해 '배터리 최적화 예외' 권한이 필요하며, 이로 인해 배터리 사용량이 증가할 수 있습니다.
* 사용자는 언제든지 설정에서 해당 권한을 해제할 수 있으나, 해제 시 핵심 기능이 제한될 수 있습니다.""";

const String _privacyContent = """제 1 조 (수집하는 개인정보 항목)
회사는 서비스 제공을 위해 필요한 최소한의 개인정보를 수집합니다.
1. 회원가입 시: 이름, 전화번호, 이메일, 생년월일, 성별
2. 서비스 이용 시: 프로필 사진, 위치 정보, 단말기 정보(배터리 상태 등)

제 2 조 (수집 및 이용 목적)
1. 본인 확인 및 회원 관리
2. 보호자-피보호자 연결 서비스 제공
3. 서비스 관련 공지사항 전달""";

const String _locationContent = """제 1 조 (목적)
본 약관은 회사가 제공하는 위치기반 서비스의 이용 조건 및 절차를 규정합니다.

제 2 조 (서비스 내용)
회사는 다음과 같은 위치기반 서비스를 제공합니다.
1. 실시간 위치 확인 서비스
2. 안심존(활동반경) 이탈 알림 서비스
3. 이동 경로 확인 서비스

제 3 조 (위치정보의 보유)
회사는 위치정보의 보호 및 이용 등에 관한 법률에 따라 위치정보 수집/이용/제공 사실 확인 자료를 자동으로 기록하며, 해당 자료를 1년간 보관합니다.""";

const String _healthInfoContent = """제 1 조 (수집하는 민감정보 항목)
본 서비스는 회원의 건강 관리를 위해 다음과 같은 민감정보를 수집합니다.
1. 복용 중인 약 정보 (약 이름, 사진, 복용 시간 등)
2. 일자별 복용 기록 및 증상 기록

제 2 조 (수집 및 이용 목적)
1. 정해진 시간에 약 복용 알림 제공
2. 보호자에게 복용 여부 및 건강 상태 리포트 제공
3. 개인 맞춤형 건강 관리 서비스 제공

* 귀하는 위 민감정보 수집 이용에 대한 동의를 거부할 권리가 있으나, 동의 거부 시 핵심 서비스(복용 알림 등) 이용이 제한될 수 있습니다.""";

const String _biometricContent = """제 1 조 (수집하는 생체정보 항목)
본 서비스는 얼굴 클러스터링 기능을 위해 다음과 같은 생체정보를 수집합니다.
1. 얼굴 이미지 데이터
2. 얼굴 특징점 임베딩 벡터 (512차원 수치 데이터)

제 2 조 (수집 및 이용 목적)
1. 사진 속 인물 자동 분류 및 그룹화
2. 보호자가 지정한 이름으로 인물 식별
3. 자동 일기 생성 시 인물명 반영

제 3 조 (보유 및 파기)
1. 보유기간: 서비스 탈퇴 시까지
2. 파기방법: 탈퇴 요청 시 즉시 파기
3. 저장위치: Firebase Storage (암호화 저장)

제 4 조 (제3자 제공)
수집된 생체정보는 제3자에게 제공되지 않습니다.

* 귀하는 생체정보 수집에 대한 동의를 거부할 권리가 있으나, 동의 거부 시 얼굴 클러스터링 기능 이용이 제한됩니다.""";

const String _marketingContent = """1. 신규 서비스(제품) 개발 및 맞춤 서비스 제공
2. 이벤트 및 광고성 정보 제공 및 참여 기회 제공
3. 서비스 이용 통계 분석

* 귀하는 마케팅 정보 수신 동의를 거부할 수 있으며, 거부하더라도 기본 서비스 이용에는 제한이 없습니다.""";
