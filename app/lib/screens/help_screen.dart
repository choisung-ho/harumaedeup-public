// lib/screens/help_screen.dart
import 'package:flutter/material.dart';
import '../theme_state.dart';

class HelpScreen extends StatefulWidget {
  final int? userRole; // 1: 보호자, 2: 시니어

  const HelpScreen({super.key, this.userRole});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  int _selectedCategoryIndex = 0;

  // 보호자용 도움말 카테고리
  List<HelpCategory> get _guardianCategories => [
    HelpCategory(
      icon: Icons.play_circle_outline,
      title: '시작하기',
      items: [
        HelpItem(
          question: '앱을 처음 사용해요. 어떻게 시작하나요?',
          answer:
              '1. 회원가입 후 "보호자 모드"를 선택해주세요.\n2. 케어 대상자(부모님)에게 앱을 설치해드리고 "시니어 모드"로 가입하도록 안내해주세요.\n3. 대상자의 연결 코드를 입력하면 연결이 완료됩니다.',
        ),
        HelpItem(
          question: '부모님과 어떻게 연결하나요?',
          answer:
              '1. 부모님 휴대폰의 "설정" 화면에서 연결 코드를 확인해주세요.\n2. 보호자님의 홈 화면에서 "대상자 연결" 버튼을 눌러주세요.\n3. 부모님의 연결 코드를 입력하면 즉시 연결됩니다.\n\n💡 연결 후 부모님의 위치, 건강 상태, 일기 등을 확인할 수 있어요.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.location_on_outlined,
      title: '위치 확인',
      items: [
        HelpItem(
          question: '부모님 위치는 어떻게 확인하나요?',
          answer:
              '홈 화면 하단의 "지도" 탭을 누르면 실시간 위치를 확인할 수 있습니다.\n\n📍 위치는 일정 간격으로 자동 업데이트되며, 부모님이 앱을 사용 중일 때 더 정확합니다.',
        ),
        HelpItem(
          question: '위치 기록은 얼마나 보관되나요?',
          answer:
              '위치 기록은 최근 7일간의 이동 경로를 저장합니다.\n\n"기록" 탭에서 날짜별로 부모님의 이동 경로를 확인할 수 있어요.',
        ),
        HelpItem(
          question: '위치가 정확하지 않아요.',
          answer:
              '부모님 휴대폰의 위치 권한이 "항상 허용"으로 설정되어 있는지 확인해주세요.\n\n설정 방법:\n1. 휴대폰 설정 → 앱 → 하루매듭\n2. 권한 → 위치 → "항상 허용" 선택',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.medication_outlined,
      title: '약 복용 관리',
      items: [
        HelpItem(
          question: '부모님 약 복용 알림은 어떻게 설정하나요?',
          answer:
              '1. 홈 화면의 "약 관리" 메뉴를 선택해주세요.\n2. "약 추가" 버튼을 눌러 약 이름, 복용 시간, 요일을 입력해주세요.\n3. 설정한 시간에 부모님 휴대폰으로 알림이 전송됩니다.\n\n💊 부모님이 "복용 완료" 버튼을 누르면 보호자님께도 알림이 옵니다.',
        ),
        HelpItem(
          question: '부모님이 약을 드셨는지 어떻게 알 수 있나요?',
          answer:
              '부모님이 약 알림에서 "복용 완료"를 누르면 보호자님께 푸시 알림이 전송됩니다.\n\n또한 "약 관리" 화면에서 복용 기록을 날짜별로 확인할 수 있어요.',
        ),
        HelpItem(
          question: '부모님이 약 알림을 놓치면 어떻게 되나요?',
          answer:
              '약 복용 확인이 안 되면 일정 시간 후 재알림이 자동으로 발송됩니다.\n\n재알림 횟수와 간격은 서버에서 자동 관리되므로 걱정하지 않으셔도 됩니다.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.calendar_today_outlined,
      title: '일기 확인',
      items: [
        HelpItem(
          question: '부모님의 일기는 어떻게 확인하나요?',
          answer:
              '홈 화면의 "캘린더" 탭에서 날짜를 선택하면 해당 날짜의 일기를 확인할 수 있습니다.\n\n🗓️ 일기가 작성된 날짜는 초록색 점으로 표시됩니다.',
        ),
        HelpItem(
          question: '일기에 녹음 파일도 들을 수 있나요?',
          answer:
              '네! 부모님이 음성으로 녹음한 일기는 재생 버튼을 눌러 들을 수 있습니다.\n\nAI가 음성을 텍스트로 변환해주기 때문에 글로도 확인 가능해요.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.notifications_outlined,
      title: '알림 설정',
      items: [
        HelpItem(
          question: '어떤 알림을 받을 수 있나요?',
          answer:
              '보호자님은 다음과 같은 알림을 받습니다:\n\n• 💊 약 복용 완료/미복용 알림\n• 📍 부모님 위치 이상 감지 알림\n• 📝 새 일기 작성 알림\n• 🔋 부모님 배터리 부족 알림',
        ),
        HelpItem(
          question: '알림이 오지 않아요.',
          answer:
              '다음 사항을 확인해주세요:\n\n1. 휴대폰 설정에서 하루매듭 앱의 알림이 허용되어 있는지\n2. 방해금지 모드가 꺼져 있는지\n3. 배터리 최적화에서 하루매듭이 제외되어 있는지\n\n💡 설정 → 앱 → 하루매듭 → 알림 → 모든 알림 허용',
        ),
      ],
    ),
  ];

  // 시니어용 도움말 카테고리
  List<HelpCategory> get _seniorCategories => [
    HelpCategory(
      icon: Icons.play_circle_outline,
      title: '시작하기',
      items: [
        HelpItem(
          question: '이 앱은 무엇을 하는 앱인가요?',
          answer:
              '하루매듭은 자녀분이 부모님을 걱정하지 않도록 도와주는 앱입니다.\n\n✅ 하루 일과를 음성으로 기록할 수 있어요\n✅ 약 드실 시간을 알려드려요\n✅ 외출할 시간을 미리 알려드려요\n✅ AI 비서와 대화할 수 있어요',
        ),
        HelpItem(
          question: '자녀와 어떻게 연결하나요?',
          answer:
              '설정 화면에 있는 "연결 코드"를 자녀분께 알려주세요.\n\n자녀분이 코드를 입력하면 자동으로 연결됩니다.\n연결되면 자녀분이 안심할 수 있어요. 😊',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.mic_outlined,
      title: 'AI 음성 비서',
      items: [
        HelpItem(
          question: 'AI 비서는 어떻게 사용하나요?',
          answer:
              '1. 홈 화면의 마이크 버튼을 눌러주세요\n2. "안녕하세요"라고 말씀해보세요\n3. AI가 음성으로 대답해드립니다\n\n🎤 대화를 끝내려면 마이크 버튼을 다시 누르세요.',
        ),
        HelpItem(
          question: 'AI 비서에게 무엇을 물어볼 수 있나요?',
          answer:
              '무엇이든 편하게 물어보세요!\n\n예시:\n• "오늘 날씨 어때?"\n• "오늘 몇 시에 약 먹어야 해?"\n• "심심한데 이야기 해줘"\n• "오늘 뉴스 알려줘"',
        ),
        HelpItem(
          question: 'AI 비서 목소리가 안 들려요.',
          answer:
              '휴대폰 옆면의 음량 버튼을 눌러 소리를 키워주세요.\n\n📢 "미디어 음량"을 올려야 AI 목소리가 들립니다.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.medication_outlined,
      title: '약 복용 알림',
      items: [
        HelpItem(
          question: '약 먹을 시간에 알림이 와요. 어떻게 하나요?',
          answer:
              '화면에 약 알림이 뜨면:\n\n💊 "복용 완료" 버튼 → 약을 드신 후 눌러주세요\n⏰ "나중에" 버튼 → 잠시 후 다시 알려드려요\n\n자녀분께서 복용 여부를 확인할 수 있어요.',
        ),
        HelpItem(
          question: '약 알림 소리가 너무 작아요.',
          answer: '휴대폰 설정에서 알림 소리를 키워주세요.\n\n또는 자녀분께 부탁해서 알림 설정을 확인해달라고 하세요.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.directions_walk_outlined,
      title: '외출 알림',
      items: [
        HelpItem(
          question: '출발 알림은 뭔가요?',
          answer:
              '문자로 받은 약속이 있으면, 출발해야 할 시간에 알려드립니다.\n\n예: "오후 2시 병원 예약"\n→ 이동 시간을 계산해서\n→ "지금 출발하세요"라고 음성으로 안내해드려요.',
        ),
        HelpItem(
          question: '어떻게 하면 출발 알림을 받을 수 있나요?',
          answer:
              '특별히 설정하실 것은 없어요!\n\n문자로 약속 일정이 오면 자동으로 분석해서 출발 시간에 알려드립니다.\n\n📱 문자 읽기 권한만 허용되어 있으면 됩니다.',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.book_outlined,
      title: '일기 쓰기',
      items: [
        HelpItem(
          question: '일기는 어떻게 쓰나요?',
          answer:
              '1. 홈 화면의 "일기 쓰기" 버튼을 눌러주세요\n2. 마이크 버튼을 누르고 오늘 있었던 일을 말씀해주세요\n3. "저장" 버튼을 누르면 끝!\n\n✏️ 글로 쓰셔도 되고, 말로 하셔도 돼요.',
        ),
        HelpItem(
          question: '내가 쓴 일기를 자녀가 볼 수 있나요?',
          answer:
              '네, 연결된 자녀분이 일기를 확인할 수 있어요.\n\n자녀분이 부모님의 하루를 알 수 있어서 안심하실 수 있답니다. 💚',
        ),
      ],
    ),
    HelpCategory(
      icon: Icons.help_outline,
      title: '기타 문의',
      items: [
        HelpItem(
          question: '글씨가 너무 작아요.',
          answer:
              '휴대폰 설정에서 글씨 크기를 키울 수 있어요.\n\n설정 → 디스플레이 → 글꼴 크기 → "크게" 또는 "아주 크게"로 변경해주세요.',
        ),
        HelpItem(
          question: '배터리가 빨리 닳아요.',
          answer:
              '위치 확인 기능 때문에 배터리가 조금 더 사용될 수 있어요.\n\n하지만 자녀분이 부모님 안전을 확인할 수 있으니 충전기를 가까이 두시고 사용해주세요. 🔌',
        ),
        HelpItem(
          question: '앱 사용이 어려워요. 도움을 받고 싶어요.',
          answer: '자녀분께 전화해서 도움을 요청해주세요.\n\n또는 AI 음성 비서에게 "도와줘"라고 말씀해보세요!',
        ),
      ],
    ),
  ];

  List<HelpCategory> get _currentCategories =>
      widget.userRole == 1 ? _guardianCategories : _seniorCategories;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final scaffoldColor = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        backgroundColor: scaffoldColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '도움말',
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
        ),
      ),
      body: Row(
        children: [
          // 왼쪽 카테고리 네비게이션
          Container(
            width: 80,
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : Colors.grey[100],
              border: Border(
                right: BorderSide(
                  color: isDark ? Colors.white12 : Colors.grey[300]!,
                ),
              ),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _currentCategories.length,
              itemBuilder: (context, index) {
                final category = _currentCategories[index];
                final isSelected = _selectedCategoryIndex == index;

                return GestureDetector(
                  onTap: () => setState(() => _selectedCategoryIndex = index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (isDark
                                ? Colors.green.withOpacity(0.2)
                                : Colors.green.withOpacity(0.1))
                          : Colors.transparent,
                      border: isSelected
                          ? Border(
                              left: BorderSide(color: Colors.green, width: 3),
                            )
                          : null,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          category.icon,
                          color: isSelected
                              ? Colors.green
                              : (isDark ? Colors.grey[400] : Colors.grey[600]),
                          size: 26,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          category.title,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? Colors.green
                                : (isDark
                                      ? Colors.grey[400]
                                      : Colors.grey[600]),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // 오른쪽 FAQ 목록
          Expanded(child: _buildFAQList(isDark, textColor)),
        ],
      ),
    );
  }

  Widget _buildFAQList(bool isDark, Color textColor) {
    final category = _currentCategories[_selectedCategoryIndex];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 카테고리 헤더
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.green.shade400, Colors.green.shade600],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(category.icon, color: Colors.white, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category.title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${category.items.length}개의 도움말',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // FAQ 아이템들
        ...category.items.map((item) => _buildFAQItem(item, isDark, textColor)),
      ],
    );
  }

  Widget _buildFAQItem(HelpItem item, bool isDark, Color textColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.help_outline,
              color: Colors.green,
              size: 20,
            ),
          ),
          title: Text(
            item.question,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: textColor,
              height: 1.4,
            ),
          ),
          iconColor: Colors.green,
          collapsedIconColor: Colors.grey,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.green.withOpacity(0.1)
                    : Colors.green.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                item.answer,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey[300] : Colors.grey[700],
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 도움말 카테고리 모델
class HelpCategory {
  final IconData icon;
  final String title;
  final List<HelpItem> items;

  HelpCategory({required this.icon, required this.title, required this.items});
}

// 도움말 아이템 모델
class HelpItem {
  final String question;
  final String answer;

  HelpItem({required this.question, required this.answer});
}
